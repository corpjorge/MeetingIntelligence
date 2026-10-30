import Darwin
public import Foundation

struct WAVWriteError: LocalizedError, Equatable {
    let code: Int32

    var errorDescription: String? {
        switch code {
        case ENOSPC: "No queda espacio en el disco."
        case EDQUOT: "Se superó la cuota de disco."
        default: "No se pudo escribir en el disco (código \(code))."
        }
    }
}

struct WAVFileIO {
    var write: (Int32, UnsafeRawBufferPointer, Int64) throws -> Int
    var synchronize: (Int32) throws -> Void

    static var system: WAVFileIO {
        WAVFileIO(write: { descriptor, bytes, offset in
            while true {
                let count = pwrite(descriptor, bytes.baseAddress, bytes.count, off_t(offset))
                if count >= 0 { return count }
                if errno != EINTR { throw WAVWriteError(code: errno) }
            }
        }, synchronize: { descriptor in
            guard fsync(descriptor) == 0 else { throw WAVWriteError(code: errno) }
        })
    }
}

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

    var io = WAVFileIO.system
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
        try writeHeader()
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
        try scratch.withUnsafeBytes { bytes in
            try writeFrames(UnsafeRawBufferPointer(rebasing: bytes.prefix(samples.count * 2)))
        }
    }

    public func append(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try append($0) }
    }

    /// Appends digital silence (used to keep tracks aligned across gaps).
    public func appendSilence(frames: Int) throws {
        guard !closed, frames > 0 else { return }
        let zeros = [UInt8](repeating: 0, count: min(frames, sampleRate) * 2)
        var remaining = frames
        while remaining > 0 {
            let n = min(remaining, sampleRate)
            try zeros.withUnsafeBytes { try writeFrames(UnsafeRawBufferPointer(rebasing: $0.prefix(n * 2))) }
            remaining -= n
        }
    }

    public var durationSeconds: Double { Double(framesWritten) / Double(sampleRate) }

    private var dataEnd: Int64 { Int64(Self.headerSize) + framesWritten * 2 }

    private func writeFrames(_ bytes: UnsafeRawBufferPointer) throws {
        var written = 0
        do {
            try write(bytes, at: dataEnd, written: &written)
        } catch {
            advance(by: Int64(written / 2))
            throw error
        }
        advance(by: Int64(written / 2))
        if framesSinceFlush >= flushInterval {
            try flushHeader()
        }
    }

    private func advance(by frames: Int64) {
        framesWritten += frames
        framesSinceFlush += frames
    }

    private func write(_ bytes: UnsafeRawBufferPointer, at offset: Int64, written: inout Int) throws {
        while written < bytes.count {
            let count = try io.write(handle.fileDescriptor, UnsafeRawBufferPointer(rebasing: bytes[written...]),
                                     offset + Int64(written))
            guard count > 0 else { throw WAVWriteError(code: EIO) }
            written += count
        }
    }

    private func writeHeader() throws {
        var written = 0
        try Self.header(sampleRate: sampleRate, dataBytes: framesWritten * 2).withUnsafeBytes {
            try write($0, at: 0, written: &written)
        }
    }

    /// Rewrites the header with the current sizes and forces data to disk.
    public func flushHeader() throws {
        guard !closed else { return }
        try writeHeader()
        try io.synchronize(handle.fileDescriptor)
        framesSinceFlush = 0
    }

    public func close() throws {
        guard !closed else { return }
        defer {
            closed = true
            try? handle.close()
        }
        _ = ftruncate(handle.fileDescriptor, off_t(dataEnd))
        try flushHeader()
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
