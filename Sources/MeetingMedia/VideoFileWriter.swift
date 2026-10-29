import AVFoundation
public import CoreVideo
public import Foundation

public enum MediaError: LocalizedError, Sendable {
    case unavailable(String)
    public var errorDescription: String? { if case .unavailable(let message) = self { message } else { nil } }
}

/// Calls are confined to the recorder's video queue (or one test producer).
/// The last retained surface bounds memory independently of recording duration.
public final class VideoFileWriter: @unchecked Sendable {
    public let url: URL
    public let width: Int
    public let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var lastBuffer: CVPixelBuffer?
    private var lastTime = -1.0
    public private(set) var droppedFrames = 0

    public init(url: URL, width: Int, height: Int) throws {
        self.url = url; self.width = width; self.height = height
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000,
                                             AVVideoMaxKeyFrameIntervalKey: 60]
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw MediaError.unavailable("No se pudo configurar el codificador de video.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaError.unavailable("No se pudo crear el video.") }
        writer.startSession(atSourceTime: .zero)
    }

    @discardableResult
    public func append(_ buffer: CVPixelBuffer, at seconds: Double) throws -> Bool {
        guard writer.status == .writing else { throw writer.error ?? MediaError.unavailable("Se detuvo el escritor de video.") }
        guard seconds.isFinite, seconds >= 0, seconds > lastTime else { return false }
        guard input.isReadyForMoreMediaData else { droppedFrames += 1; return false }
        guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 60_000)) else {
            throw writer.error ?? MediaError.unavailable("No se pudo guardar una imagen del video.")
        }
        lastBuffer = buffer; lastTime = seconds
        return true
    }

    public func appendBlack(at seconds: Double) throws {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard result == kCVReturnSuccess, let buffer else { throw MediaError.unavailable("No se pudo preparar la imagen del video.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        try append(buffer, at: seconds)
    }

    /// Capture must be stopped before calling. Repeats the final static frame to
    /// cover the recording tail, including a pause followed immediately by Stop.
    public func finish(at seconds: Double) async throws {
        let end = max(seconds, lastTime + 1.0 / 30)
        for _ in 0..<200 where !input.isReadyForMoreMediaData && writer.status == .writing {
            try await Task.sleep(for: .milliseconds(10))
        }
        if let lastBuffer, end - 1.0 / 30 > lastTime {
            try append(lastBuffer, at: end - 1.0 / 30)
        }
        guard lastTime >= 0 else {
            writer.cancelWriting()
            throw MediaError.unavailable("No se recibieron imágenes para guardar el video.")
        }
        writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 60_000))
        input.markAsFinished()
        await writer.finishWriting()
        lastBuffer = nil
        guard writer.status == .completed else { throw writer.error ?? MediaError.unavailable("No se pudo finalizar el video.") }
    }
}
