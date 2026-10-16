public import Foundation

/// 16-bit PCM mono WAV writer designed for long live recordings.
///
/// * The RIFF/data sizes are rewritten and the file is `fsync`ed every
///   `flushInterval` frames, so an app crash loses at most that much audio.
/// * `WAVRepair.repairHeader(at:)` restores a valid header from the file size
///   for files left behind by a crash or power loss.
///
/// Not thread-safe: confine each instance to one serial queue.
public final class CrashSafeWAVWriter {
    public let url: URL
    public let sampleRate: Int
    public private(set) var framesWritten: Int64 = 0

    private let handle: FileHandle
    private let flushInterval: Int64
    private var framesSinceFlush: Int64 = 0
    private var scratch: [Int16] = []
    private var closed = false

    public static let headerSize = 44

    public init(url: URL, sampleRate: Int, flushIntervalSeconds: Double = 2.0) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.flushInterval = Int64(Double(sampleRate) * flushIntervalSeconds)
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CaptureError.fileCreationFailed(url.path)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: 0))
    }

    deinit {
        try? close()
    }

    /// Appends mono Float32 samples in [-1, 1] (clipped).
    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard !closed, !samples.isEmpty else { return }
        if scratch.count < samples.count { scratch = [Int16](repeating: 0, count: samples.count) }
        for i in 0..<samples.count {
            let clipped = max(-1, min(1, samples[i]))
            scratch[i] = Int16((clipped * Float(Int16.max)).rounded())
        }
        try scratch.withUnsafeBufferPointer { buffer in
            try handle.write(contentsOf: Data(bytes: buffer.baseAddress!, count: samples.count * 2))
        }
        try advance(by: Int64(samples.count))
    }

    public func append(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try append($0) }
    }

    /// Appends digital silence (used to keep tracks aligned across gaps).
    public func appendSilence(frames: Int) throws {
        guard !closed, frames > 0 else { return }
        let chunk = Data(count: min(frames, sampleRate) * 2)
        var remaining = frames
        while remaining > 0 {
            let n = min(remaining, sampleRate)
            try handle.write(contentsOf: n == min(frames, sampleRate) ? chunk : Data(count: n * 2))
            remaining -= n
        }
        try advance(by: Int64(frames))
    }

    public var durationSeconds: Double { Double(framesWritten) / Double(sampleRate) }

    private func advance(by frames: Int64) throws {
        framesWritten += frames
        framesSinceFlush += frames
        if framesSinceFlush >= flushInterval {
            try flushHeader()
        }
    }

    /// Rewrites the header with the current sizes and forces data to disk.
    public func flushHeader() throws {
        guard !closed else { return }
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: framesWritten * 2))
        try handle.seek(toOffset: end)
        try handle.synchronize()
        framesSinceFlush = 0
    }

    public func close() throws {
        guard !closed else { return }
        try flushHeader()
        try handle.close()
        closed = true
    }

    static func header(sampleRate: Int, dataBytes: Int64) -> Data {
        let dataSize = UInt32(clamping: dataBytes)
        var data = Data(capacity: headerSize)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 &+ dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                       // PCM
        u16(1)                       // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))  // byte rate
        u16(2)                       // block align
        u16(16)                      // bits per sample
        data.append(contentsOf: Array("data".utf8)); u32(dataSize)
        return data
    }
}

public enum WAVRepair {
    /// Fixes the RIFF and data chunk sizes of a 44-byte-header PCM WAV written by
    /// `CrashSafeWAVWriter` using the real file length. Returns the recovered duration.
    @discardableResult
    public static func repairHeader(at url: URL) throws -> Double {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= UInt64(CrashSafeWAVWriter.headerSize) else { throw CaptureError.unreadableRecording(url.path) }
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: CrashSafeWAVWriter.headerSize) ?? Data()
        guard header.count == CrashSafeWAVWriter.headerSize,
              header.prefix(4) == Data("RIFF".utf8),
              header[8..<12] == Data("WAVE".utf8) else {
            throw CaptureError.unreadableRecording(url.path)
        }
        let sampleRate = header[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        var dataBytes = Int64(fileSize) - Int64(CrashSafeWAVWriter.headerSize)
        dataBytes -= dataBytes % 2 // drop a torn trailing byte
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: CrashSafeWAVWriter.header(sampleRate: Int(sampleRate), dataBytes: dataBytes))
        try handle.synchronize()
        return Double(dataBytes / 2) / Double(sampleRate)
    }
}
