import AVFoundation
import CoreImage
public import CoreGraphics
public import Foundation
public import MeetingAudio
@preconcurrency public import ScreenCaptureKit

public enum VideoCaptureStatus: Sendable, Equatable {
    case recording
    case unavailable(String)
    case failed(String)
}

/// One picker-authorized stream lives from preview through recording. Preview
/// never opens audio or files; beginRecording attaches the writer to this stream.
/// All frames, callbacks and writer transitions are confined to the video queue.
public final class WindowVideoRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public static let fileName = "video.mov"
    private let queue = DispatchQueue(label: "mi.video.writer", qos: .userInitiated)
    private let imageContext = CIContext()
    private var clock: CaptureClock?
    private var file: VideoFileWriter?
    private var onStatus: @Sendable (VideoCaptureStatus) -> Void
    private var onPreview: (@Sendable (CGImage) -> Void)?
    private var stream: SCStream?
    private var startTask: Task<Void, any Error>?
    private var accepting = true
    private var stopped = false
    private var status: VideoCaptureStatus = .recording
    private var hasRecordedFrame = false
    private var writingFailed = false
    private var lastImage: CVPixelBuffer?
    private var lastImageHost: Double?
    private var lastPreviewHost = -Double.infinity
    public let width: Int
    public let height: Int

    public init(filter: SCContentFilter,
                onStatus: @escaping @Sendable (VideoCaptureStatus) -> Void = { _ in },
                onPreview: (@Sendable (CGImage) -> Void)? = nil) throws {
        self.onStatus = onStatus; self.onPreview = onPreview
        let size = filter.contentRect.size
        let scale = min(Double(filter.pointPixelScale), 1920 / max(1, size.width), 1080 / max(1, size.height))
        width = max(2, Int(size.width * scale) / 2 * 2)
        height = max(2, Int(size.height * scale) / 2 * 2)
        super.init()
        let configuration = SCStreamConfiguration()
        configuration.width = width; configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.capturesAudio = false; configuration.captureMicrophone = false
        configuration.captureDynamicRange = .SDR
        configuration.showsCursor = true
        configuration.scalesToFit = true
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    /// Compatibility for callers that do not need an earlier preview.
    public convenience init(url: URL, filter: SCContentFilter, clock: CaptureClock,
                            onStatus: @escaping @Sendable (VideoCaptureStatus) -> Void) throws {
        try self.init(filter: filter, onStatus: onStatus)
        try beginRecording(to: url, clock: clock, onStatus: onStatus)
    }

    /// Repeated callers await the same start, not a second authorization/stream.
    public func start() async throws {
        let task = queue.sync { () -> Task<Void, any Error> in
            if let startTask { return startTask }
            let task = Task { [self] in
                guard let stream else { throw MediaError.unavailable("La captura de ventana ya está cerrada.") }
                try await stream.startCapture()
            }
            startTask = task
            return task
        }
        try await task.value
    }

    public func beginRecording(to url: URL, clock: CaptureClock,
                               onStatus: @escaping @Sendable (VideoCaptureStatus) -> Void) throws {
        try queue.sync {
            guard !stopped, file == nil else { throw MediaError.unavailable("La ventana no está lista para grabar.") }
            let writer = try VideoFileWriter(url: url, width: width, height: height)
            self.clock = clock
            self.file = writer
            self.onStatus = onStatus
            onStatus(status)
            self.onPreview = nil
            hasRecordedFrame = false
            if let lastImage, let lastImageHost,
               let time = clock.timelineSeconds(forHostSeconds: lastImageHost) {
                // An unchanged image from before Start is the initial image. A
                // later image keeps its actual offset; it is never shifted early.
                if time > 0 { try writer.appendBlack(at: 0) }
                hasRecordedFrame = try writer.append(lastImage, at: max(0, time))
            } else {
                try writer.appendBlack(at: 0)
            }
        }
    }

    /// Stops a selection that was previewed but never recorded.
    public func stopPreview() async {
        guard queue.sync(execute: { file == nil }) else { return }
        queue.sync { accepting = false }
        let task = queue.sync { startTask }
        _ = try? await task?.value
        try? await stream?.stopCapture()
        closeStream()
    }

    public func stop(at duration: Double) async throws -> Int {
        queue.sync { accepting = false }
        let task = queue.sync { startTask }
        _ = try? await task?.value
        try? await stream?.stopCapture()
        let result = queue.sync { () -> (VideoFileWriter?, Bool, Bool) in
            let result = (file, hasRecordedFrame, writingFailed)
            file = nil; clock = nil
            return result
        }
        closeStream()
        guard let file = result.0 else { return 0 }
        try await file.finish(at: duration)
        guard !result.2 else { throw MediaError.unavailable("El video se interrumpió durante la escritura. El audio se conservó.") }
        guard result.1 else { throw MediaError.unavailable("La ventana no entregó imágenes. El audio se conservó.") }
        return file.droppedFrames
    }

    private func closeStream() {
        try? stream?.removeStreamOutput(self, type: .screen)
        queue.sync {
            stopped = true; stream = nil; startTask = nil
            lastImage = nil; lastImageHost = nil; onPreview = nil
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, type == .screen, sample.isValid,
              let sourceClock = stream.synchronizationClock else { return }
        let host = CMSyncConvertTime(sample.presentationTimeStamp, from: sourceClock, to: CMClockGetHostTimeClock()).seconds
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let frame = (attachments?.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        do {
            if frame == .complete, let image = sample.imageBuffer {
                lastImage = image; lastImageHost = host
                if !writingFailed { update(.recording) }
                emitPreview(image, host: host)
                if !writingFailed, let file, let time = clock?.timelineSeconds(forHostSeconds: host), time >= 0 {
                    if try file.append(image, at: time) { hasRecordedFrame = true }
                }
            } else if frame == .suspended || frame == .blank {
                lastImage = nil; lastImageHost = nil
                if let time = clock?.timelineSeconds(forHostSeconds: host), time >= 0 { try file?.appendBlack(at: time) }
                update(.unavailable("La ventana no entrega imagen. Restáurala si está minimizada."))
            }
        } catch {
            writingFailed = true
            update(.failed("No se pudo guardar el video: \(error.localizedDescription). El audio continúa."))
        }
    }

    private func emitPreview(_ buffer: CVPixelBuffer, host: Double) {
        guard let onPreview, host - lastPreviewHost >= 0.4 else { return }
        lastPreviewHost = host
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 640 / image.extent.width, 360 / image.extent.height)
        let thumbnail = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let cgImage = imageContext.createCGImage(thumbnail, from: thumbnail.extent) { onPreview(cgImage) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { [self] in
            guard accepting else { return }
            if let clock, !clock.isPaused { try? file?.appendBlack(at: clock.elapsed) }
            update(.failed("Se interrumpió la captura de la ventana: \(error.localizedDescription)"))
        }
    }

    @available(macOS 15.2, *)
    public func streamDidBecomeInactive(_ stream: SCStream) {
        queue.async { [self] in
            guard accepting else { return }
            lastImage = nil; lastImageHost = nil
            if let clock, !clock.isPaused { try? file?.appendBlack(at: clock.elapsed) }
            update(.unavailable("La ventana está inactiva o minimizada. Restáurala para recuperar la imagen."))
        }
    }

    private func update(_ value: VideoCaptureStatus) {
        guard status != value else { return }
        status = value
        onStatus(value)
    }
}
