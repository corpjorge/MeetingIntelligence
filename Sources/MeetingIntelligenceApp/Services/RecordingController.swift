import AppKit
import Foundation
import MeetingAudio
import MeetingCore
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
    private(set) var meeting: Meeting?
    private(set) var elapsed: TimeInterval = 0
    private(set) var micLevel = AudioLevel.silence
    private(set) var remoteLevel = AudioLevel.silence
    private(set) var warnings: [RecordingWarning] = []
    private(set) var remoteProcesses: [AudioProcessInfo] = []
    private(set) var scope: CaptureScope?
    private(set) var lastFinishedMeetingId: String?
    private(set) var capturesMicrophone = false
    private(set) var capturesRemoteAudio = false
    private(set) var microphonePaused = false
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
    private var live: LiveTranscriber?
    private var liveTask: Task<Void, Never>?
    private let paths: AppPaths
    private let settings: AppSettings
    private var session: RecordingSession?
    private var eventsTask: Task<Void, Never>?
    private var timer: Timer?
    private var terminationObserver: (any NSObjectProtocol)?
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "recording-ui")

    init(importer: MeetingImportService, paths: AppPaths, settings: AppSettings, asr: ParakeetUltraProvider) {
        self.importer = importer
        self.asr = asr
        self.paths = paths
        self.settings = settings
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTermination() }
        }
    }

    func start(title: String, target: RemoteCaptureTarget, captureMicrophone: Bool) async {
        guard !isActive else { return }
        state = .starting
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
                microphoneVoiceProcessing: settings.microphoneVoiceProcessing)
            let session = RecordingSession(configuration: config)
            self.session = session
            self.meeting = meeting
            liveText = [:]
            let liveSources: [AudioSource] = (captureMicrophone ? [.localMicrophone] : []) + (target == .none ? [] : [.remoteSystemAudio])
            if settings.liveTranscription, await asr.isModelCached(), !liveSources.isEmpty {
                await startLive(sources: liveSources, session: session)
            }
            listen(to: session)
            try session.start()
            state = .recording
            startTimer()
        } catch {
            logger.error("Start failed: \(error.localizedDescription, privacy: .public)")
            if let meeting {
                _ = session?.stop()
                try? importer.database.deleteMeeting(id: meeting.id, paths: paths)
            }
            session = nil
            meeting = nil
            state = .failed(error.localizedDescription)
        }
    }

    /// Pauses only my microphone (silence is written; the remote track keeps recording).
    func toggleMicrophonePause() {
        guard isActive, capturesMicrophone, let session else { return }
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
        isActive && CallMuteReminder.isRelevant(capturesMicrophone: capturesMicrophone, capturesRemoteAudio: capturesRemoteAudio,
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
        guard let session, let meeting, state == .recording || state == .paused else { return }
        state = .stopping
        timer?.invalidate()
        let result = session.stop()
        eventsTask?.cancel()
        stopLive()
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
        recordingApp = nil
        microphonePaused = false
        micLevel = .silence
        remoteLevel = .silence
    }

    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    private func startLive(sources: [AudioSource], session: RecordingSession) async {
        liveStatus = "Cargando transcripción provisional…"
        do {
            let live = try await asr.makeLiveTranscriber(sources: sources, languageHint: settings.language)
            self.live = live
            session.onSamples = { source, samples in live.feed(samples, source: source) }
            liveStatus = nil
            liveTask = Task { [weak self] in
                for await update in live.updates {
                    self?.liveText[update.source] = update
                }
            }
        } catch {
            liveStatus = "Transcripción provisional no disponible: \(error.localizedDescription)"
        }
    }

    private func stopLive() {
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
                    if !self.warnings.contains(warning) { self.warnings.append(warning) }
                case .remoteProcesses(let processes):
                    self.remoteProcesses = processes
                case .remoteScope(let scope):
                    self.scope = scope
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
            }
        }
    }

    /// Flush WAV headers so a quit during recording keeps all audio; the
    /// meeting is recovered as `interrupted` on next launch.
    private func handleTermination() {
        guard let session, isActive else { return }
        session.flushToDisk()
        if let meeting {
            let result = session.stop()
            try? importer.finishRecording(meetingId: meeting.id, result: result)
        }
    }
}
