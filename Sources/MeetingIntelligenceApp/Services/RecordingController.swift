import AppKit
import Foundation
import MeetingAudio
import MeetingCore
import MeetingMedia
import MeetingSpeech
import OSLog

/// UI-facing state machine around `RecordingSession`. A recording only starts
/// from an explicit user action; there is no automatic start.
@Observable
final class RecordingController {
    enum State: Equatable {
        case idle
        case starting
        case recording
        case paused
        case stopping
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var startingMessage = "Preparando captura…"
    private(set) var cancellingStart = false
    var activityLabel: String {
        switch state {
        case .starting: cancellingStart ? "Cancelando inicio…" : "Preparando grabación…"
        case .stopping: "Guardando grabación…"
        case .paused: "En pausa"
        default: "Grabando"
        }
    }
    private(set) var meeting: Meeting?
    private(set) var elapsed: TimeInterval = 0
    private(set) var micLevel = AudioLevel.silence
    private(set) var remoteLevel = AudioLevel.silence
    private(set) var warnings: [RecordingWarning] = []
    private(set) var remoteProcesses: [AudioProcessInfo] = []
    private(set) var scope: CaptureScope?
    private(set) var lastFinishedMeetingId: String?
    private(set) var capturesMicrophone = false
    private(set) var microphoneName: String?
    private(set) var capturesRemoteAudio = false
    private(set) var microphonePaused = false
    let videoSelection = VideoSelectionController()
    private(set) var capturesVideo = false
    private(set) var videoStatus: VideoCaptureStatus = .recording
    private(set) var lastVideoError: String?
    private var videoRecorder: WindowVideoRecorder?
    private var videoAsset: VideoAsset?
    /// The user hid the "muted in the call ≠ paused here" reminder for this recording.
    private(set) var muteReminderDismissed = false
    /// App being recorded on the remote track (nil = system-wide / microphone only).
    private(set) var recordingApp: AudioAppSelector?
    /// Provisional live text per source (never persisted as the transcript).
    private(set) var liveText: [AudioSource: LiveTranscriptUpdate] = [:]
    private(set) var liveStatus: String?

    var onFinished: ((String) -> Void)?

    var isActive: Bool { state == .recording || state == .paused || state == .starting || state == .stopping }

    private let importer: MeetingImportService
    private let asr: ParakeetUltraProvider
    private let startCapture: @Sendable (RecordingSession) async throws -> Void
    private let startupLimit: Duration
    private var live: LiveTranscriber?
    private var liveTask: Task<Void, Never>?
    private var livePreparationTask: Task<Void, Never>?
    private var startupTimeoutTask: Task<Void, Never>?
    private var startupTimedOut = false
    private let paths: AppPaths
    private let settings: AppSettings
    private var session: RecordingSession?
    private var eventsTask: Task<Void, Never>?
    private var timer: Timer?
    private var terminationObserver: (any NSObjectProtocol)?
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "recording-ui")

    init(importer: MeetingImportService, paths: AppPaths, settings: AppSettings, asr: ParakeetUltraProvider,
         startCapture: @escaping @Sendable (RecordingSession) async throws -> Void = { try await $0.startAsync() },
         startupLimit: Duration = .seconds(15)) {
        self.importer = importer
        self.asr = asr
        self.paths = paths
        self.settings = settings
        self.startCapture = startCapture
        self.startupLimit = startupLimit
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTermination() }
        }
    }

    func start(title: String, target: RemoteCaptureTarget, captureMicrophone: Bool, includeVideo: Bool = false, microphoneDeviceUID: String? = nil) async {
        guard !isActive else { return }
        guard !includeVideo || videoSelection.canRecord else {
            state = .failed("Elige la ventana en el selector de macOS antes de grabar video.")
            return
        }
        let inputs = AudioDevices.inputDevices()
        let chosenInput = microphoneDeviceUID.flatMap { uid in inputs.first { $0.uid == uid } }
            ?? (microphoneDeviceUID == nil ? AudioDevices.preferredRecordingInput(defaultInput: AudioDevices.defaultInput(), devices: inputs) : nil)
        guard !captureMicrophone || chosenInput?.uid != nil else {
            state = .failed("Selecciona un micrófono disponible. En modo automático no se activa el micrófono Bluetooth de los audífonos.")
            return
        }
        microphoneName = chosenInput?.name
        let videoFilter = includeVideo ? videoSelection.filter : nil
        state = .starting
        cancellingStart = false; startupTimedOut = false
        startingMessage = "Preparando captura…"
        elapsed = 0
        capturesVideo = includeVideo
        videoStatus = .recording
        lastVideoError = nil
        videoAsset = nil
        capturesMicrophone = captureMicrophone
        capturesRemoteAudio = target != .none
        microphonePaused = false
        muteReminderDismissed = false
        if case .application(let selector) = target { recordingApp = selector } else { recordingApp = nil }
        warnings = []
        remoteProcesses = []
        if captureMicrophone, !RecordingSession.microphonePermissionGranted() {
            guard await RecordingSession.requestMicrophonePermission() else {
                state = .failed(CaptureError.microphonePermissionDenied.localizedDescription)
                return
            }
        }
        if cancellingStart { state = .idle; return }
        let scope: CaptureScope = switch target {
        case .application: .applicationProcesses
        case .systemWide: .systemWide
        case .none: .microphoneOnly
        }
        do {
            let meeting = try importer.beginRecording(title: title, scope: scope, sourceApp: recordingApp,
                                                      language: settings.language)
            let config = RecordingConfiguration(
                directory: paths.meetingDirectory(meeting.id), remoteTarget: target,
                captureMicrophone: captureMicrophone, microphoneEchoCancellation: settings.microphoneEchoCancellation,
                microphoneVoiceProcessing: settings.microphoneVoiceProcessing, microphoneDeviceUID: chosenInput?.uid)
            let session = RecordingSession(configuration: config)
            self.session = session
            self.meeting = meeting
            liveText = [:]
            let liveSources: [AudioSource] = (captureMicrophone ? [.localMicrophone] : []) + (target == .none ? [] : [.remoteSystemAudio])
            liveStatus = settings.liveTranscription ? "La transcripción provisional se preparará al comenzar la captura." : nil
            listen(to: session)
            if videoFilter != nil {
                guard let recorder = videoSelection.takeRecorder() else {
                    throw MediaError.unavailable("La captura de la ventana no está lista. Vuelve a seleccionarla.")
                }
                videoRecorder = recorder
                try recorder.beginRecording(to: config.directory.appendingPathComponent(WindowVideoRecorder.fileName),
                                            clock: session.clock) { [weak self] status in
                    Task { @MainActor in self?.videoStatus = status }
                }
                let asset = VideoAsset(meetingId: meeting.id,
                                       relativePath: "Recordings/\(meeting.id)/\(WindowVideoRecorder.fileName)",
                                       windowTitle: videoSelection.title, applicationName: videoSelection.applicationName,
                                       width: recorder.width, height: recorder.height)
                try importer.database.save(video: asset)
                videoAsset = asset
            }
            // Confirm video capture before opening microphone/audio devices.
            try await videoRecorder?.start()
            if cancellingStart { throw CancellationError() }
            startingMessage = "Abriendo el micrófono y el audio remoto…"
            let limit = startupLimit
            startupTimeoutTask = Task { [weak self, weak session] in
                do { try await Task.sleep(for: limit) } catch { return }
                guard let self, self.state == .starting, self.session === session else { return }
                self.startupTimedOut = true
                self.cancelStart()
                self.startingMessage = "El dispositivo tardó demasiado. Cancelando y liberando la captura…"
            }
            defer { startupTimeoutTask?.cancel(); startupTimeoutTask = nil }
            try await startCapture(session)
            if cancellingStart { throw CancellationError() }
            state = .recording
            startTimer()
            if settings.liveTranscription, !liveSources.isEmpty {
                livePreparationTask = Task { [weak self] in await self?.startLive(sources: liveSources, session: session) }
            }
        } catch {
            logger.error("Start failed: \(error.localizedDescription, privacy: .public)")
            stopLive()
            eventsTask?.cancel()
            if let session { _ = await session.stopAsync() }
            if let videoRecorder { _ = try? await videoRecorder.stop(at: session?.elapsed ?? 0) }
            videoRecorder = nil
            if let meeting {
                try? importer.database.deleteMeeting(id: meeting.id, paths: paths)
            }
            session = nil
            meeting = nil
            if startupTimedOut { state = .failed("El dispositivo de audio no terminó de iniciar en 15 segundos. Se canceló la captura; vuelve a seleccionar el micrófono.") }
            else if error is CancellationError { state = .idle }
            else { state = .failed((includeVideo ? VideoSelectionController.startFailureMessage(error) : nil) ?? error.localizedDescription) }
        }
    }

    func cancelStart() {
        guard state == .starting else { return }
        cancellingStart = true
        startingMessage = "Cancelando y liberando la captura…"
        session?.requestStartCancellation()
    }

    /// Pauses only my microphone (silence is written; the remote track keeps recording).
    func toggleMicrophonePause() {
        guard state == .recording || state == .paused, capturesMicrophone, let session else { return }
        microphonePaused.toggle()
        session.setMicrophonePaused(microphonePaused)
    }

    /// Pause-only entry point (the mute reminder): a stale click can never resume the microphone.
    func pauseMicrophone() {
        guard !microphonePaused else { return }
        toggleMicrophonePause()
    }

    /// The call app's mute state is not readable (TD-23), so this reminder is static.
    var showsMuteReminder: Bool {
        (state == .recording || state == .paused) && CallMuteReminder.isRelevant(capturesMicrophone: capturesMicrophone, capturesRemoteAudio: capturesRemoteAudio,
                                                microphonePaused: microphonePaused, dismissed: muteReminderDismissed)
    }

    func dismissMuteReminder() { muteReminderDismissed = true }

    func pause() {
        guard state == .recording else { return }
        session?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        session?.resume()
        state = .recording
    }

    func stop() {
        if state == .starting { cancelStart(); return }
        guard let session, let meeting, state == .recording || state == .paused else { return }
        state = .stopping
        timer?.invalidate()
        eventsTask?.cancel()
        stopLive()
        let videoRecorder = self.videoRecorder
        let videoAsset = self.videoAsset
        Task {
            let result = await session.stopAsync()
            if let videoRecorder, var asset = videoAsset {
                do {
                    _ = try await videoRecorder.stop(at: result.durationSeconds)
                    asset.state = .ready
                    asset.durationSeconds = result.durationSeconds
                } catch {
                    asset.state = .failed
                    lastVideoError = "El audio se conservó, pero el video no se pudo finalizar: \(error.localizedDescription)"
                }
                asset.fileSizeBytes = StorageMaintenance.size(of: paths.resolve(relativePath: asset.relativePath))
                do { try importer.database.save(video: asset) }
                catch { lastVideoError = "No se pudo registrar el video; se intentará recuperar al abrir la app." }
            }
            do {
                try importer.finishRecording(meetingId: meeting.id, result: result)
                lastFinishedMeetingId = meeting.id
                onFinished?(meeting.id)
                state = .idle
            } catch {
                state = .failed("La grabación se detuvo pero no se pudo registrar: \(error.localizedDescription)")
            }
            self.session = nil
            self.meeting = nil
            self.videoRecorder = nil
            self.videoAsset = nil
            videoSelection.clear()
            recordingApp = nil
            microphonePaused = false
            micLevel = .silence
            remoteLevel = .silence
        }
    }

    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    private func startLive(sources: [AudioSource], session: RecordingSession) async {
        liveStatus = "Cargando transcripción provisional…"
        do {
            let cached = await asr.isModelCached()
            guard !Task.isCancelled, self.session === session, state == .recording || state == .paused else { return }
            guard cached else {
                liveStatus = "La grabación continúa. Descarga el modelo para ver transcripción provisional."
                return
            }
            let live = try await asr.makeLiveTranscriber(sources: sources, languageHint: settings.language)
            guard !Task.isCancelled, self.session === session, state == .recording || state == .paused else {
                await live.stop()
                return
            }
            self.live = live
            session.onSamples = { source, samples in live.feed(samples, source: source) }
            liveStatus = nil
            liveTask = Task { [weak self] in
                for await update in live.updates {
                    self?.liveText[update.source] = update
                }
            }
        } catch {
            guard !Task.isCancelled, self.session === session, state == .recording || state == .paused else { return }
            liveStatus = "Transcripción provisional no disponible: \(error.localizedDescription)"
        }
    }

    private func stopLive() {
        livePreparationTask?.cancel(); livePreparationTask = nil
        session?.onSamples = nil
        liveTask?.cancel()
        liveTask = nil
        if let live { Task { await live.stop() } }
        live = nil
    }

    private func listen(to session: RecordingSession) {
        eventsTask = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                switch event {
                case .level(let source, let level):
                    if source == .localMicrophone { self.micLevel = level } else { self.remoteLevel = level }
                case .warning(let warning):
                    if case .inputDeviceChanged(let name) = warning { self.microphoneName = name }
                    if !self.warnings.contains(warning) { self.warnings.append(warning) }
                case .remoteProcesses(let processes):
                    self.remoteProcesses = processes
                case .remoteScope(let scope):
                    self.scope = scope
                case .sourceRecovered(let source):
                    self.warnings.removeAll { $0 == .noAudioBuffers(source) }
                case .microphonePaused(let paused):
                    self.microphonePaused = paused
                }
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                self.elapsed = session.elapsed
                session.checkAudioDelivery()
            }
        }
    }

    /// Flush WAV headers so a quit during recording keeps all audio; the
    /// meeting is recovered as `interrupted` on next launch.
    private func handleTermination() {
        guard let session, isActive else { return }
        if state == .starting { session.requestStartCancellation(); return }
        session.flushToDisk()
        guard state != .stopping else { return }
        if let meeting {
            let result = session.stop()
            try? importer.finishRecording(meetingId: meeting.id, result: result)
        }
    }
}
