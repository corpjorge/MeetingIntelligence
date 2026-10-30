import Foundation
import MeetingAudio
import MeetingCore
import MeetingMedia
import MeetingSpeech
import OSLog

/// Composition root: builds every long-lived service exactly once.
/// Models are loaded lazily by their engines and reused for the app lifetime.
@Observable
final class AppEnvironment {
    let paths: AppPaths
    let database: AppDatabase
    let settings: AppSettings
    let asr: ParakeetUltraProvider
    let diarizer: DiarizationService
    let vault: BiometricVault
    let recognizer: SpeakerRecognitionService
    let processor: MeetingProcessor
    let booster = AcousticVocabularyBooster()
    let importer: MeetingImportService
    let processing: ProcessingCoordinator
    let recording: RecordingController
    let models: ModelStatusModel
    let mediaExport = MediaExportController()
    let ai: AIController
    let semantic: SemanticIndexController
    let modelUpdates: ModelUpdateController
    let calls: CallSuggestionController
    let updates: AppUpdateController

    private(set) var startupError: String?
    private(set) var recoveredMeetings: [String] = []
    let startupPolicy: LibraryStartupPolicy
    var libraryBlockedReason: String? { startupPolicy.blockedReason }
    private let libraryLock: LibraryLock?

    static let logger = Logger(subsystem: "dev.meetingintelligence", category: "app")

    init() {
        let paths = AppPaths.resolveDefault()
        self.paths = paths
        // Snapshot runs must not alter the user's real preferences.
        let snapshotDefaults = SnapshotDriver.directory != nil
            ? UserDefaults(suiteName: "dev.meetingintelligence.snapshot") : nil
        let settings = AppSettings(defaults: snapshotDefaults ?? .standard)
        self.settings = settings
        let lockState: LibraryStartupPolicy.LockState
        switch LibraryLock.acquire(in: paths.root) {
        case .acquired(let lock):
            libraryLock = lock
            lockState = .exclusive
        case .heldByAnotherInstance:
            libraryLock = nil
            lockState = .heldByAnotherInstance
            Self.logger.notice("Library in use by another instance; maintenance and capture are disabled")
        case .unavailable(let reason):
            libraryLock = nil
            lockState = .unavailable
            Self.logger.error("Library lock unavailable: \(reason, privacy: .public)")
        }
        let database: AppDatabase
        var openError: String?
        do {
            database = try AppDatabase.open(paths: paths)
        } catch {
            Self.logger.fault("Database open failed: \(error.localizedDescription, privacy: .public)")
            // Keep the app usable to show the error; nothing is persisted in this state.
            database = try! AppDatabase.inMemory()
            openError = "No se pudo abrir la biblioteca en \(paths.root.path): \(error.localizedDescription)"
        }
        startupError = openError
        let policy = LibraryStartupPolicy.decide(databaseOpened: openError == nil, lock: lockState)
        startupPolicy = policy
        self.database = database
        asr = ParakeetUltraProvider()
        diarizer = DiarizationService(segmentationStepRatio: settings.diarizationStepRatio)
        vault = BiometricVault(keyProvider: KeychainBiometricKeyProvider())
        recognizer = SpeakerRecognitionService(database: database, vault: vault, diarizer: diarizer)
        processor = MeetingProcessor(database: database, paths: paths, asr: asr, diarizer: diarizer, recognizer: recognizer,
                                     booster: booster)
        importer = MeetingImportService(database: database, paths: paths)
        processing = ProcessingCoordinator(processor: processor, settings: settings, database: database)
        processing.blockedReason = policy.blockedReason
        recording = RecordingController(importer: importer, paths: paths, settings: settings, asr: asr)
        recording.blockedReason = policy.blockedReason
        models = ModelStatusModel(asr: asr, diarizer: diarizer)
        ai = AIController(database: database, defaults: snapshotDefaults ?? .standard)
        semantic = SemanticIndexController(paths: paths, database: database, settings: settings)
        semantic.blockedReason = policy.blockedReason
        calls = CallSuggestionController(settings: settings, recording: recording)
        modelUpdates = ModelUpdateController(asr: asr, diarizer: diarizer, booster: booster, semantic: semantic,
                                             settings: settings, processing: processing, recording: recording)
        modelUpdates.blockedReason = policy.sharedWithAnotherInstance ? "otra copia de la app usa la biblioteca" : nil
        if policy.runsMaintenance { modelUpdates.recoverInterruptedUpdates() }
        updates = AppUpdateController(configuration: AppUpdateConfiguration.fromMainBundle(), settings: settings,
                                      busyReason: { [recording, processing, modelUpdates] in
            if policy.sharedWithAnotherInstance { return "otra copia de la app usa la biblioteca" }
            if recording.isActive { return "se graba una reunión" }
            if processing.active != nil || !processing.queue.isEmpty { return "se procesa una reunión" }
            if modelUpdates.isUpdating { return "se actualiza un modelo" }
            return nil
        })
        if !policy.sharedWithAnotherInstance {
            updates.handleLaunch()
            if SnapshotDriver.directory == nil { updates.startAutomaticChecks() }
        }
        // The call monitor needs no permission; snapshot runs skip notifications.
        if policy.blockedReason == nil { calls.start(requestNotifications: SnapshotDriver.directory == nil) }
        recording.onFinished = { [processing, settings] meetingId in
            if settings.autoProcessAfterRecording { processing.enqueue(meetingId) }
        }
        processing.onCompleted = { [semantic] _ in semantic.schedule() }
        semantic.refresh()
        recoveredMeetings = StartupMaintenance(database: database, importer: importer, paths: paths,
                                               audioRetentionDays: settings.audioRetentionDays,
                                               videoRetentionDays: settings.videoRetentionDays).run(policy: policy)
        if policy.runsMaintenance { Task { await VideoRecovery.recover(database: database, paths: paths) } }
    }
}

/// Deletes audio files older than the configured retention (transcripts are kept).
struct AudioRetention {
    let database: AppDatabase
    let paths: AppPaths

    func apply(days: Int?) throws {
        guard let days, days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for row in try database.meetingRows() where row.meeting.displayDate < cutoff && row.meeting.status == .ready {
            for track in try database.tracks(meetingId: row.meeting.id) {
                let url = paths.resolve(relativePath: track.relativePath)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}

/// Independent policy: an existing audio preference never deletes a new video silently.
struct VideoRetention {
    let database: AppDatabase
    let paths: AppPaths

    func apply(days: Int?, now: Date = Date()) throws {
        guard let days, days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        for row in try database.meetingRows() where row.meeting.displayDate < cutoff && row.meeting.status == .ready {
            if let video = try database.video(meetingId: row.id) {
                let url = paths.resolve(relativePath: video.relativePath)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
    }
}
