import AVFoundation
import Foundation
import OSLog

/// Captures the default input device with AVAudioEngine.
///
/// Follows the system default input (AirPods, USB headsets, built-in mic). On
/// `AVAudioEngineConfigurationChange` (device switch, Bluetooth profile change)
/// the tap is reinstalled with the new hardware format; the `TrackRecorder`
/// pads the gap so the timeline stays aligned with the remote track.
final class MicrophoneSource: @unchecked Sendable {
    private let recorder: TrackRecorder
    private let voiceProcessing: Bool
    private let queue = DispatchQueue(label: "mi.mic.control")
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "microphone")
    private let onDeviceChange: @Sendable (String) -> Void
    private let onFailure: @Sendable (String) -> Void

    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?
    private var running = false

    init(recorder: TrackRecorder, voiceProcessing: Bool = false,
         onDeviceChange: @escaping @Sendable (String) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.recorder = recorder
        self.voiceProcessing = voiceProcessing
        self.onDeviceChange = onDeviceChange
        self.onFailure = onFailure
    }

    static func permissionStatus() -> AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        try queue.sync {
            running = true
            try startEngineLocked()
        }
    }

    func stop() {
        queue.sync {
            running = false
            stopEngineLocked()
        }
    }

    private func startEngineLocked() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // VPIO is an explicit alternative, never combined with recording AEC.
        // Default capture stays unprocessed to avoid the Teams conflict (TD-33).
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        let recorder = self.recorder
        let sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            let mono = Downmix.mono(buffer)
            recorder.ingest(mono, sampleRate: sampleRate, hostTime: time.isHostTimeValid ? time.hostTime : nil)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        logger.info("Microphone started: \(sampleRate) Hz, \(format.channelCount) ch, VP=\(self.voiceProcessing)")
    }

    private func stopEngineLocked() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func handleConfigurationChange() {
        queue.async { [self] in
            guard running else { return }
            stopEngineLocked()
            // Give the HAL a moment to settle (Bluetooth profile switches take ~100–500 ms).
            for attempt in 0..<5 {
                do {
                    try startEngineLocked()
                    onDeviceChange(AudioDevices.defaultInput()?.name ?? "dispositivo desconocido")
                    return
                } catch {
                    logger.error("Mic restart attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                    Thread.sleep(forTimeInterval: 0.3 * Double(attempt + 1))
                }
            }
            onFailure("No se pudo reanudar el micrófono tras un cambio de dispositivo.")
        }
    }
}
