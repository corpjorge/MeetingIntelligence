@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Captures one explicit device, without AVAudioEngine's default input/output
/// aggregate or a playback route. All lifecycle calls run on the mic control queue.
final class DeviceMicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let delivery = DispatchQueue(label: "mi.mic.samples", qos: .userInitiated)
    private let recorder: TrackRecorder
    private let onFailure: @Sendable (String) -> Void
    private var observer: (any NSObjectProtocol)?

    init(recorder: TrackRecorder, onFailure: @escaping @Sendable (String) -> Void) {
        self.recorder = recorder; self.onFailure = onFailure
    }

    func start(deviceUID: String?) throws {
        guard let uid = deviceUID ?? AudioDevices.defaultInput()?.uid,
              let device = AVCaptureDevice(uniqueID: uid), device.hasMediaType(.audio) else {
            throw CaptureError.inputDeviceUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.unsupportedFormat("no se pudo configurar el micrófono elegido")
        }
        session.addInput(input)
        // Convert sample representation only. Never impose a sample rate or channel
        // count from another device; the capture output negotiates those itself.
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false]
        output.setSampleBufferDelegate(self, queue: delivery)
        session.addOutput(output)
        session.commitConfiguration()
        observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                           object: session, queue: nil) { [weak self] note in
            let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "Se interrumpió la entrada."
            self?.onFailure("El micrófono seleccionado se interrumpió: \(detail)")
        }
        session.startRunning()
        guard session.isRunning else {
            stop()
            throw CaptureError.noInputDevice
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        output.setSampleBufferDelegate(nil, queue: nil)
        session.stopRunning()
        delivery.sync {} // Drain in-flight copies before TrackRecorder is finalized.
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        do {
            let decoded = try MicrophoneSampleDecoder.decode(sampleBuffer, clock: session.synchronizationClock)
            recorder.ingest(decoded.samples, sampleRate: decoded.sampleRate, hostTime: decoded.hostTime)
        } catch {
            onFailure("No se pudo leer el audio del micrófono: \(error.localizedDescription)")
        }
    }
}

/// Shared with synthetic CMSampleBuffer tests; never opens an audio device.
enum MicrophoneSampleDecoder {
    static func decode(_ sample: CMSampleBuffer, clock: CMClock?) throws -> (samples: [Float], sampleRate: Double, hostTime: UInt64?) {
        guard sample.isValid, CMSampleBufferDataIsReady(sample),
              let description = sample.formatDescription,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              stream.pointee.mFormatID == kAudioFormatLinearPCM,
              stream.pointee.mSampleRate.isFinite, stream.pointee.mSampleRate > 0,
              stream.pointee.mChannelsPerFrame > 0,
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatInt16 else {
            throw CaptureError.unsupportedFormat("el micrófono no entregó muestras PCM válidas")
        }
        let frames = sample.numSamples
        guard frames > 0, frames <= Int(Int32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw CaptureError.unsupportedFormat("el micrófono entregó un bloque vacío")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                into: buffer.mutableAudioBufferList)
        guard result == noErr else { throw CaptureError.coreAudio("lectura de muestras del micrófono", result) }
        var hostTime: UInt64?
        if let clock {
            let host = CMSyncConvertTime(sample.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock()).seconds
            if host.isFinite, host >= 0, host < Double(UInt64.max) / 1_000_000_000 {
                hostTime = AudioConvertNanosToHostTime(UInt64(host * 1_000_000_000))
            }
        }
        return (Downmix.mono(buffer), format.sampleRate, hostTime)
    }
}
