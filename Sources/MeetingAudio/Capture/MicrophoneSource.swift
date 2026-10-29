@preconcurrency import AVFoundation
import Foundation
import OSLog

/// Input-only capture. The tap accepts the negotiated hardware format and
/// resamples each buffer using its actual rate, including Bluetooth transitions.
final class MicrophoneSource: @unchecked Sendable {
    private let recorder: TrackRecorder
    private let voiceProcessing: Bool
    private let deviceUID: String?
    private let queue = DispatchQueue(label: "mi.mic.control")
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "microphone")
    private let onDeviceChange: @Sendable (String) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var engine: AVAudioEngine?
    private var deviceCapture: DeviceMicrophoneCapture?
    private var observer: (any NSObjectProtocol)?
    private var running = false
    private var tapInstalled = false
    private var pendingRecovery: DispatchWorkItem?
    private var recovery = MicrophoneRecovery()

    init(recorder: TrackRecorder, voiceProcessing: Bool = false, deviceUID: String? = nil,
         onDeviceChange: @escaping @Sendable (String) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.recorder = recorder; self.voiceProcessing = voiceProcessing; self.deviceUID = deviceUID
        self.onDeviceChange = onDeviceChange; self.onFailure = onFailure
    }

    static func permissionStatus() -> AVAudioApplication.recordPermission { AVAudioApplication.shared.recordPermission }
    static func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }

    func start() throws {
        try queue.sync {
            running = true
            recovery = MicrophoneRecovery()
            do { try startEngineLocked() }
            catch { running = false; stopEngineLocked(); throw error }
        }
    }

    func stop() {
        queue.sync { running = false; stopEngineLocked() }
    }

    private func startEngineLocked() throws {
        if !voiceProcessing {
            let capture = DeviceMicrophoneCapture(recorder: recorder, onFailure: onFailure)
            deviceCapture = capture
            try capture.start(deviceUID: deviceUID)
            logger.info("Microphone device capture started without playback")
            return
        }
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        } else {
            // This engine records input; it must not also open the default headphones for playback.
            input.auAudioUnit.isOutputEnabled = false
        }
        if let deviceUID {
            guard let device = AudioDevices.inputDevices().first(where: { $0.uid == deviceUID }) else {
                throw CaptureError.inputDeviceUnavailable
            }
            try input.auAudioUnit.setDeviceID(device.deviceID)
        }
        try installTapLocked(on: engine)
        // Register before starting: route changes can happen inside prepare/start.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            guard let engine else { return }
            self?.scheduleRecovery(for: engine)
        }
        engine.prepare()
        try startPreparedEngineLocked(engine)
        logger.info("Microphone input started; VP=\(self.voiceProcessing)")
    }

    private func installTapLocked(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        if tapInstalled { input.removeTap(onBus: 0); tapInstalled = false }
        try MicrophoneTap.install(on: input, recorder: recorder)
        tapInstalled = true
    }

    private func startPreparedEngineLocked(_ engine: AVAudioEngine) throws {
        do { try engine.start() }
        catch {
            let failure = error as NSError
            let hardware = engine.inputNode.inputFormat(forBus: 0)
            logger.error("Microphone start failed; hardware=\(hardware.sampleRate) Hz/\(hardware.channelCount) channels; domain=\(failure.domain, privacy: .public); code=\(failure.code)")
            if failure.domain == "com.apple.coreaudio.avfaudio", failure.code == -10868 {
                throw CaptureError.unsupportedFormat("el motor rechazó el formato del micrófono seleccionado (\(Int(hardware.sampleRate)) Hz, \(hardware.channelCount) canal(es)). Vuelve a seleccionar el micrófono antes de iniciar")
            }
            throw error
        }
    }

    private func stopEngineLocked() {
        deviceCapture?.stop(); deviceCapture = nil
        pendingRecovery?.cancel(); pendingRecovery = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        tapInstalled = false
        engine = nil
    }

    private func scheduleRecovery(for changedEngine: AVAudioEngine) {
        queue.async { [self] in
            guard running, engine === changedEngine else { return }
            pendingRecovery?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.running, self.engine === changedEngine else { return }
                self.recoverLocked(changedEngine)
            }
            pendingRecovery = work
            // Let the device finish negotiating instead of restarting during every notification.
            queue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    private func recoverLocked(_ engine: AVAudioEngine) {
        pendingRecovery = nil
        let now = HostClock.nowSeconds()
        let last = recorder.lastReceivedHostTime
        if engine.isRunning, let last, now - last < 1 { return }
        guard recovery.permit(at: now, lastBufferAt: nil) else {
            running = false
            stopEngineLocked()
            onFailure("El micrófono no se estabilizó tras varios cambios de conexión. Detén y guarda; elige el micrófono del Mac u otro dispositivo antes de grabar de nuevo.")
            return
        }
        do {
            // Reuse the negotiated engine/device. Creating a new engine here
            // restarted Bluetooth negotiation indefinitely on Galaxy Buds Pro.
            engine.stop()
            try installTapLocked(on: engine)
            engine.prepare()
            try startPreparedEngineLocked(engine)
            let device = deviceUID.flatMap { uid in AudioDevices.inputDevices().first { $0.uid == uid } } ?? AudioDevices.defaultInput()
            onDeviceChange(device?.name ?? "micrófono seleccionado")
        } catch {
            logger.error("Microphone recovery failed: \(error.localizedDescription, privacy: .public)")
            scheduleRecovery(for: engine)
        }
    }
}

/// A device change updates the hardware input format before the engine's client
/// output format. Passing nil would keep that stale format (e.g. 16 kHz for a
/// 48 kHz built-in mic). AVAudioInputNode cannot convert rates in hardware mode.
enum MicrophoneTap {
    static func install(on input: AVAudioInputNode, recorder: TrackRecorder) throws {
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate.isFinite, hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: hardware) { buffer, time in
            recorder.ingest(Downmix.mono(buffer), sampleRate: buffer.format.sampleRate,
                            hostTime: time.isHostTimeValid ? time.hostTime : nil)
        }
    }
}
