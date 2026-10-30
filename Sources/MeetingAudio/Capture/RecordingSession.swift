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

    /// May attach live ASR after capture has already started. Never holds the
    /// handler lock while calling the consumer or performing model work.
    private let sampleHandlerLock = NSLock()
    private var sampleHandler: (@Sendable (AudioSource, [Float]) -> Void)?
    public var onSamples: (@Sendable (AudioSource, [Float]) -> Void)? {
        get { sampleHandlerLock.withLock { sampleHandler } }
        set { sampleHandlerLock.withLock { sampleHandler = newValue } }
    }
    private let cancellationLock = NSLock()
    private var startCancelled = false

    private var micRecorder: TrackRecorder?
    private var remoteRecorder: TrackRecorder?
    private var microphone: MicrophoneSource?
    private var tap: ProcessTapSource?
    private var remote: RemoteTapSupervisor?
    private var remoteRetry: DispatchWorkItem?
    private var listeners: [HALPropertyListener] = []
    private var scope: CaptureScope = .microphoneOnly
    private var warnings: [RecordingWarning] = []
    private let warningLock = NSLock()
    private var acceptsRecoveries = true
    private var started = false
    private var stopped = false
    private let pauseLock = NSLock()
    private var pausableMicrophone: TrackRecorder?
    private var microphonePaused = false
    private var captureStartedHost: Double?
    private var deliveryWatchdog = AudioDeliveryWatchdog()
    private var inputDeviceName: String?

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

    /// Hardware APIs may block while negotiating a route. Keep that work off
    /// the main actor and observe cancellation between native operations.
    public func startAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do { try start(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func requestStartCancellation() { cancellationLock.withLock { startCancelled = true } }

    private func checkStartCancellation() throws {
        if cancellationLock.withLock({ startCancelled }) { throw CancellationError() }
    }

    public func stopAsync() async -> RecordingResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in continuation.resume(returning: stop()) }
        }
    }

    public func start() throws {
        try control.sync {
            guard !started else { throw CaptureError.alreadyRecording }
            started = true
            var succeeded = false
            defer {
                if !succeeded {
                    microphone?.stop(); tap?.stop()
                    listeners.forEach { $0.invalidate() }; listeners.removeAll()
                    _ = remoteRecorder?.finish(atTimelineSeconds: 0)
                    _ = micRecorder?.finish(atTimelineSeconds: 0)
                    stopped = true
                    continuation.finish()
                }
            }
            try checkStartCancellation()
            try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let onLevel: @Sendable (AudioSource, AudioLevel) -> Void = { [continuation] source, level in
                continuation.yield(.level(source, level))
            }
            let onWarning: @Sendable (RecordingWarning) -> Void = { [weak self] warning in
                self?.report(warning)
            }
            let onRecovered: @Sendable (RecordingWarning) -> Void = { [weak self] warning in
                self?.retract(warning, recovered: .remoteSystemAudio)
            }
            // Both converted streams and AEC state are confined to this queue.
            let trackQueue = DispatchQueue(label: "mi.recording.tracks", qos: .userInitiated)
            let echoCanceller = configuration.usesRecordingEchoCancellation
                ? try RecordingEchoCanceller(sampleRate: Int(configuration.outputSampleRate)) : nil

            if configuration.captureMicrophone {
                guard Self.microphonePermissionGranted() else { throw CaptureError.microphonePermissionDenied }
                let recorder = try TrackRecorder(
                    source: .localMicrophone,
                    url: configuration.directory.appendingPathComponent(Self.microphoneFileName),
                    outputSampleRate: configuration.outputSampleRate, clock: clock,
                    queue: trackQueue, echoCanceller: echoCanceller,
                    onLevel: onLevel, onWarning: onWarning, onRecovered: onRecovered)
                recorder.onSamples = { [weak self] source, samples in self?.onSamples?(source, samples) }
                micRecorder = recorder
                let mic = MicrophoneSource(
                    recorder: recorder, voiceProcessing: configuration.usesAppleVoiceProcessing, deviceUID: configuration.microphoneDeviceUID,
                    onDeviceChange: { [weak self] name in
                        self?.control.async { [weak self] in
                            self?.inputDeviceName = name
                            self?.report(.inputDeviceChanged(name))
                        }
                    },
                    onFailure: { [weak self] message in self?.report(.sourceFailed(.localMicrophone, message)) })
                microphone = mic
                try mic.start()
                try checkStartCancellation()
                let input = configuration.microphoneDeviceUID.flatMap { uid in AudioDevices.inputDevices().first { $0.uid == uid } }
                    ?? AudioDevices.defaultInput()
                inputDeviceName = input?.name
                if let input, input.transport.isBluetooth {
                    report(.bluetoothMicrophone(input.name))
                }
            }

            if configuration.remoteTarget != .none {
                let recorder = try TrackRecorder(
                    source: .remoteSystemAudio,
                    url: configuration.directory.appendingPathComponent(Self.remoteFileName),
                    outputSampleRate: configuration.outputSampleRate, clock: clock,
                    queue: trackQueue, echoCanceller: echoCanceller,
                    onLevel: onLevel, onWarning: onWarning)
                recorder.onSamples = { [weak self] source, samples in self?.onSamples?(source, samples) }
                remoteRecorder = recorder
                let tap = ProcessTapSource(recorder: recorder) { [weak self] sampleRate in
                    self?.control.async { [weak self] in self?.remoteFormatChanged(sampleRate: sampleRate) }
                }
                self.tap = tap
                let supervisor = RemoteTapSupervisor(tap: tap)
                supervisor.onEvent = { [weak self] event in self?.handle(event) }
                remote = supervisor
                try startRemoteLocked()
                try checkStartCancellation()
                installListenersLocked()
            }

            if configuration.captureMicrophone, configuration.remoteTarget != .none,
               let output = AudioDevices.defaultOutput(), output.isLikelySpeakers,
               !configuration.usesRecordingEchoCancellation, !configuration.usesAppleVoiceProcessing {
                report(.speakerEchoRisk(output.dataSourceName ?? output.name))
            }
            captureStartedHost = HostClock.nowSeconds()
            succeeded = true
            pauseLock.withLock { pausableMicrophone = micRecorder }
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
            // Freeze the shared endpoint before shutting down either audio or video.
            clock.pause()
            let end = clock.elapsed
            warningLock.withLock { acceptsRecoveries = false }
            pauseLock.withLock { pausableMicrophone = nil }
            remoteRetry?.cancel()
            remoteRetry = nil
            listeners.forEach { $0.invalidate() }
            listeners.removeAll()
            microphone?.stop()
            remote?.stop()
            tap?.stop()
            var stats: [TrackStatistics] = []
            var micPauses: [PauseInterval] = []
            // Finish reference input first so the microphone can drain the AEC
            // lookahead and its final partial frame before closing its WAV.
            let remoteStats = remoteRecorder?.finish(atTimelineSeconds: end)
            if let micRecorder {
                let micStats = micRecorder.finish(atTimelineSeconds: end)
                micPauses = micStats.pauses
                stats.append(micStats)
            }
            if let remoteStats { stats.append(remoteStats) }
            stopped = true
            continuation.finish()
            return RecordingResult(
                durationSeconds: end, tracks: stats, captureScope: scope,
                remoteProcessDescription: describe(remote?.tappedProcesses ?? []),
                inputDeviceName: inputDeviceName,
                warnings: warningLock.withLock { warnings },
                sourceApp: { if case .application(let selector) = configuration.remoteTarget { selector } else { nil } }(),
                microphonePauses: micPauses)
        }
    }

    /// Forces WAV headers to disk (call on app termination).
    public func flushToDisk() {
        micRecorder?.flush()
        remoteRecorder?.flush()
    }

    /// No-buffer failures never reach TrackRecorder's digital-silence detector.
    /// Check them independently of the UI meters, without opening any devices.
    public func checkAudioDelivery() {
        control.async { [self] in
            guard started, !stopped else { return }
            remote?.retryIfDue()
            guard !clock.isPaused, let start = captureStartedHost else { return }
            let now = HostClock.nowSeconds()
            guard now - start >= 5 else { return }
            for (source, recorder) in [(AudioSource.localMicrophone, micRecorder), (.remoteSystemAudio, remoteRecorder)] {
                guard let recorder else { continue }
                if source == .localMicrophone && isMicrophonePaused { continue }
                var startedAt = start
                if source == .remoteSystemAudio {
                    guard tap?.isRunning == true else { continue }
                    startedAt = max(start, remote?.lastStartedAt ?? start)
                }
                let change = deliveryWatchdog.check(source: source, lastReceivedAt: recorder.lastReceivedHostTime, startedAt: startedAt, now: now)
                if change == .missing {
                    continuation.yield(.level(source, .silence))
                    report(.noAudioBuffers(source))
                } else if change == .recovered {
                    retract(nil, recovered: source)
                }
            }
        }
    }

    // MARK: Microphone pause

    /// Pauses/resumes only the local microphone. Silence is written meanwhile so
    /// both tracks keep the same timeline; the span is reported as a pause.
    public func setMicrophonePaused(_ paused: Bool) {
        let time = clock.elapsed
        pauseLock.withLock {
            guard let recorder = pausableMicrophone, paused != microphonePaused else { return }
            microphonePaused = paused
            recorder.setMuted(paused, atTimelineSeconds: time)
            continuation.yield(.microphonePaused(paused))
        }
    }

    public var isMicrophonePaused: Bool { pauseLock.withLock { microphonePaused } }

    // MARK: Remote capture

    private func appProcesses(for selector: AudioAppSelector) -> (app: AudioApplication?, processes: [AudioProcessInfo]) {
        let app = AudioApplicationResolver.currentApplications().first(where: selector.matches)
        return (app, app?.processes ?? [])
    }

    private func startRemoteLocked() throws {
        guard let remote else { return }
        switch configuration.remoteTarget {
        case .application(let selector):
            let (app, processes) = appProcesses(for: selector)
            scope = .applicationProcesses
            if processes.isEmpty {
                report(.waitingForAppAudio(selector.name))
            } else {
                try remote.start(.processes(processes.map(\.objectID)), processes: processes)
            }
            if app?.isolation == .shared { report(.sharedProcessCapture(app?.name ?? selector.name)) }
            continuation.yield(.remoteProcesses(processes))
        case .systemWide:
            let own = AudioProcessCatalog.currentProcessObjectID().map { [$0] } ?? []
            try remote.start(.systemWideExcluding(own))
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
        guard !stopped, case .application(let selector) = configuration.remoteTarget, let remote else { return }
        remote.processesChanged(appProcesses(for: selector).processes, appName: selector.name)
    }

    private func outputDeviceChanged() {
        guard !stopped, let remote else { return }
        remote.outputDeviceChanged(AudioDevices.defaultOutput()?.name ?? "desconocido")
        if configuration.captureMicrophone, let output = AudioDevices.defaultOutput(), output.isLikelySpeakers,
           !configuration.usesRecordingEchoCancellation, !configuration.usesAppleVoiceProcessing {
            report(.speakerEchoRisk(output.dataSourceName ?? output.name))
        }
    }

    private func remoteFormatChanged(sampleRate: Double) {
        guard !stopped else { return }
        remote?.formatChanged(sampleRate: sampleRate)
    }

    private func handle(_ event: RemoteTapEvent) {
        switch event {
        case .warning(let warning):
            report(warning)
        case .processes(let processes):
            continuation.yield(.remoteProcesses(processes))
        case .recovered(let failure):
            deliveryWatchdog.reset(.remoteSystemAudio)
            retract(failure, recovered: .remoteSystemAudio)
        case .retryScheduled(let delay):
            remoteRetry?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
                self.remote?.retryIfDue()
            }
            remoteRetry = work
            control.asyncAfter(deadline: .now() + delay + 0.01, execute: work)
        }
    }

    private func retract(_ warning: RecordingWarning?, recovered source: AudioSource) {
        let accepted = warningLock.withLock { () -> Bool in
            guard acceptsRecoveries else { return false }
            warnings.removeAll { $0 == warning || $0 == .noAudioBuffers(source) }
            return true
        }
        if accepted { continuation.yield(.sourceRecovered(source)) }
    }

    private func report(_ warning: RecordingWarning) {
        logger.notice("\(warning.message, privacy: .public)")
        warningLock.withLock {
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
