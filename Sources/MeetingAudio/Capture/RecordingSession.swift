import Foundation
import CoreAudio
public import MeetingCore
import OSLog

/// Records `local_microphone` and `remote_system_audio` as two separate,
/// timeline-aligned 16 kHz mono WAV files.
///
/// Never starts by itself: the app calls `start()` only after an explicit user
/// action. The recording indicator in the UI is driven by this object's state.
public final class RecordingSession: @unchecked Sendable {
    public let configuration: RecordingConfiguration
    public let events: AsyncStream<RecordingEvent>
    public let clock: CaptureClock

    private let continuation: AsyncStream<RecordingEvent>.Continuation
    private let control = DispatchQueue(label: "mi.recording.control")
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "recording")

    /// Optional tap of converted 16 kHz mono audio per source; set before `start()`.
    public var onSamples: (@Sendable (AudioSource, [Float]) -> Void)?

    private var micRecorder: TrackRecorder?
    private var remoteRecorder: TrackRecorder?
    private var microphone: MicrophoneSource?
    private var tap: ProcessTapSource?
    private var listeners: [HALPropertyListener] = []
    private var scope: CaptureScope = .microphoneOnly
    private var tappedProcesses: [AudioProcessInfo] = []
    private var warnings: [RecordingWarning] = []
    private var started = false
    private var stopped = false
    private var microphonePaused = false

    public init(configuration: RecordingConfiguration) {
        self.configuration = configuration
        self.clock = CaptureClock()
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    public static var microphoneFileName: String { "\(AudioSource.localMicrophone.fileStem).wav" }
    public static var remoteFileName: String { "\(AudioSource.remoteSystemAudio.fileStem).wav" }

    public static func microphonePermissionGranted() -> Bool {
        MicrophoneSource.permissionStatus() == .granted
    }

    public static func requestMicrophonePermission() async -> Bool {
        await MicrophoneSource.requestPermission()
    }

    // MARK: Lifecycle

    public func start() throws {
        try control.sync {
            guard !started else { throw CaptureError.alreadyRecording }
            started = true
            try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let onLevel: @Sendable (AudioSource, AudioLevel) -> Void = { [continuation] source, level in
                continuation.yield(.level(source, level))
            }
            let onWarning: @Sendable (RecordingWarning) -> Void = { [weak self] warning in
                self?.report(warning)
            }

            if configuration.captureMicrophone {
                guard Self.microphonePermissionGranted() else { throw CaptureError.microphonePermissionDenied }
                let recorder = try TrackRecorder(
                    source: .localMicrophone,
                    url: configuration.directory.appendingPathComponent(Self.microphoneFileName),
                    outputSampleRate: configuration.outputSampleRate, clock: clock,
                    onLevel: onLevel, onWarning: onWarning)
                recorder.onSamples = onSamples
                micRecorder = recorder
                let mic = MicrophoneSource(
                    recorder: recorder, voiceProcessing: configuration.microphoneVoiceProcessing,
                    onDeviceChange: { [weak self] name in self?.report(.inputDeviceChanged(name)) },
                    onFailure: { [weak self] message in self?.report(.sourceFailed(.localMicrophone, message)) })
                try mic.start()
                microphone = mic
                if let input = AudioDevices.defaultInput(), input.transport.isBluetooth {
                    report(.bluetoothMicrophone(input.name))
                }
            }

            if configuration.remoteTarget != .none {
                let recorder = try TrackRecorder(
                    source: .remoteSystemAudio,
                    url: configuration.directory.appendingPathComponent(Self.remoteFileName),
                    outputSampleRate: configuration.outputSampleRate, clock: clock,
                    onLevel: onLevel, onWarning: onWarning)
                recorder.onSamples = onSamples
                remoteRecorder = recorder
                tap = ProcessTapSource(recorder: recorder)
                try startRemoteLocked()
                installListenersLocked()
            }

            if configuration.captureMicrophone, configuration.remoteTarget != .none,
               let output = AudioDevices.defaultOutput(), output.isLikelySpeakers,
               !configuration.microphoneVoiceProcessing {
                report(.speakerEchoRisk(output.dataSourceName ?? output.name))
            }
            continuation.yield(.remoteScope(scope))
        }
    }

    public func pause() { clock.pause() }
    public func resume() { clock.resume() }
    public var isPaused: Bool { clock.isPaused }
    public var elapsed: Double { clock.elapsed }

    /// Stops all sources, pads tracks to a common length and closes the files.
    public func stop() -> RecordingResult {
        control.sync {
            let end = clock.elapsed
            listeners.forEach { $0.invalidate() }
            listeners.removeAll()
            microphone?.stop()
            tap?.stop()
            var stats: [TrackStatistics] = []
            var micPauses: [PauseInterval] = []
            if let micRecorder {
                let micStats = micRecorder.finish(atTimelineSeconds: end)
                micPauses = micStats.pauses
                stats.append(micStats)
            }
            if let remoteRecorder { stats.append(remoteRecorder.finish(atTimelineSeconds: end)) }
            stopped = true
            continuation.finish()
            return RecordingResult(
                durationSeconds: end, tracks: stats, captureScope: scope,
                remoteProcessDescription: describe(tappedProcesses),
                inputDeviceName: AudioDevices.defaultInput()?.name,
                warnings: warnings,
                sourceApp: { if case .application(let selector) = configuration.remoteTarget { selector } else { nil } }(),
                microphonePauses: micPauses)
        }
    }

    /// Forces WAV headers to disk (call on app termination).
    public func flushToDisk() {
        micRecorder?.flush()
        remoteRecorder?.flush()
    }

    // MARK: Microphone pause

    /// Pauses/resumes only the local microphone. Silence is written meanwhile so
    /// both tracks keep the same timeline; the span is reported as a pause.
    public func setMicrophonePaused(_ paused: Bool) {
        control.async { [self] in
            guard let micRecorder, !stopped, paused != microphonePaused else { return }
            microphonePaused = paused
            micRecorder.setMuted(paused, atTimelineSeconds: clock.elapsed)
            continuation.yield(.microphonePaused(paused))
        }
    }

    public var isMicrophonePaused: Bool { control.sync { microphonePaused } }

    // MARK: Remote capture

    private func appProcesses(for selector: AudioAppSelector) -> (app: AudioApplication?, processes: [AudioProcessInfo]) {
        let app = AudioApplicationResolver.currentApplications().first(where: selector.matches)
        return (app, app?.processes ?? [])
    }

    private func startRemoteLocked() throws {
        guard let tap else { return }
        switch configuration.remoteTarget {
        case .application(let selector):
            let (app, processes) = appProcesses(for: selector)
            tappedProcesses = processes
            scope = .applicationProcesses
            if processes.isEmpty {
                report(.waitingForAppAudio(selector.name))
            } else {
                try tap.start(target: .processes(processes.map(\.objectID)))
            }
            if app?.isolation == .shared { report(.sharedProcessCapture(app?.name ?? selector.name)) }
            continuation.yield(.remoteProcesses(processes))
        case .systemWide:
            let own = AudioProcessCatalog.currentProcessObjectID().map { [$0] } ?? []
            try tap.start(target: .systemWideExcluding(own))
            scope = .systemWide
            report(.systemWideCapture)
        case .none:
            scope = .microphoneOnly
        }
    }

    private func installListenersLocked() {
        let processList = HALPropertyListener(object: HAL.systemObject, selector: kAudioHardwarePropertyProcessObjectList,
                                              queue: control) { [weak self] in
            guard let self else { return }
            self.control.async { self.processListChanged() }
        }
        let output = HALPropertyListener(object: HAL.systemObject, selector: kAudioHardwarePropertyDefaultOutputDevice,
                                         queue: control) { [weak self] in
            guard let self else { return }
            self.control.async { self.outputDeviceChanged() }
        }
        listeners = [processList, output]
    }

    /// The chosen app started/stopped helper processes (e.g. Teams ModuleHost on
    /// joining a call): rebuild the tap; the recorder pads the short gap.
    private func processListChanged() {
        guard !stopped, case .application(let selector) = configuration.remoteTarget, let tap else { return }
        let (_, processes) = appProcesses(for: selector)
        guard Set(processes.map(\.objectID)) != Set(tappedProcesses.map(\.objectID)) else { return }
        tappedProcesses = processes
        continuation.yield(.remoteProcesses(processes))
        do {
            if processes.isEmpty {
                tap.stop()
                report(.waitingForAppAudio(selector.name))
            } else {
                try tap.rebuild(target: .processes(processes.map(\.objectID)))
                report(.remoteTapRebuilt("procesos de \(selector.name) actualizados (\(processes.count))"))
            }
        } catch {
            report(.sourceFailed(.remoteSystemAudio, error.localizedDescription))
        }
    }

    private func outputDeviceChanged() {
        guard !stopped, let tap, let target = tap.target else { return }
        let name = AudioDevices.defaultOutput()?.name ?? "desconocido"
        do {
            try tap.rebuild(target: target)
            report(.outputDeviceChanged(name))
        } catch {
            report(.sourceFailed(.remoteSystemAudio, error.localizedDescription))
        }
        if configuration.captureMicrophone, let output = AudioDevices.defaultOutput(), output.isLikelySpeakers,
           !configuration.microphoneVoiceProcessing {
            report(.speakerEchoRisk(output.dataSourceName ?? output.name))
        }
    }

    private func report(_ warning: RecordingWarning) {
        logger.notice("\(warning.message, privacy: .public)")
        control.async { [self] in
            if !warnings.contains(warning) { warnings.append(warning) }
        }
        continuation.yield(.warning(warning))
    }

    private func describe(_ processes: [AudioProcessInfo]) -> String? {
        switch configuration.remoteTarget {
        case .none: return nil
        case .systemWide: return "Todo el audio del sistema excepto Meeting Intelligence"
        case .application(let selector):
            guard !processes.isEmpty else { return "\(selector.name) (sin procesos de audio detectados)" }
            let names = Set(processes.map { $0.bundleID ?? $0.displayName }).sorted()
            return "\(selector.name): " + names.joined(separator: ", ")
        }
    }
}
