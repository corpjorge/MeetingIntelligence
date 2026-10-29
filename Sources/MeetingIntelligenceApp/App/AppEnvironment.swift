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

    static let logger = Logger(subsystem: "dev.meetingintelligence", category: "app")

    init() {
        let paths = AppPaths.resolveDefault()
        self.paths = paths
        // Snapshot runs must not alter the user's real preferences.
        let settings = AppSettings(defaults: SnapshotDriver.directory != nil
                                   ? UserDefaults(suiteName: "dev.meetingintelligence.snapshot") ?? .standard : .standard)
        self.settings = settings
        let database: AppDatabase
        do {
            database = try AppDatabase.open(paths: paths)
        } catch {
            Self.logger.fault("Database open failed: \(error.localizedDescription, privacy: .public)")
            // Keep the app usable to show the error; nothing is persisted in this state.
            database = try! AppDatabase.inMemory()
            startupError = "No se pudo abrir la biblioteca en \(paths.root.path): \(error.localizedDescription)"
        }
        self.database = database
        asr = ParakeetUltraProvider()
        diarizer = DiarizationService(segmentationStepRatio: settings.diarizationStepRatio)
        vault = BiometricVault(keyProvider: KeychainBiometricKeyProvider())
        recognizer = SpeakerRecognitionService(database: database, vault: vault, diarizer: diarizer)
        processor = MeetingProcessor(database: database, paths: paths, asr: asr, diarizer: diarizer, recognizer: recognizer,
                                     booster: booster)
        importer = MeetingImportService(database: database, paths: paths)
        processing = ProcessingCoordinator(processor: processor, settings: settings)
        recording = RecordingController(importer: importer, paths: paths, settings: settings, asr: asr)
        models = ModelStatusModel(asr: asr, diarizer: diarizer)
        ai = AIController(database: database)
        semantic = SemanticIndexController(paths: paths, database: database, settings: settings)
        calls = CallSuggestionController(settings: settings, recording: recording)
        modelUpdates = ModelUpdateController(asr: asr, diarizer: diarizer, booster: booster, semantic: semantic,
                                             settings: settings, processing: processing, recording: recording)
        modelUpdates.recoverInterruptedUpdates()
        updates = AppUpdateController(configuration: AppUpdateConfiguration.fromMainBundle(), settings: settings,
                                      busyReason: { [recording, processing, modelUpdates] in
            if recording.isActive { return "se graba una reunión" }
            if processing.active != nil || !processing.queue.isEmpty { return "se procesa una reunión" }
            if modelUpdates.rows.contains(where: { if case .updating = $0.state { true } else { false } }) {
                return "se actualiza un modelo"
            }
            return nil
        })
        updates.handleLaunch()
        if SnapshotDriver.directory == nil { updates.startAutomaticChecks() }
        // The call monitor needs no permission; snapshot runs skip notifications.
        calls.start(requestNotifications: SnapshotDriver.directory == nil)
        recording.onFinished = { [processing, settings] meetingId in
            if settings.autoProcessAfterRecording { processing.enqueue(meetingId) }
        }
        processing.onCompleted = { [semantic] _ in semantic.schedule() }
        semantic.refresh()
        recoverAfterCrash()
        Task { await VideoRecovery.recover(database: database, paths: paths) }
    }

    /// Meetings left mid-recording by a crash get their WAV headers repaired and become `interrupted`.
    private func recoverAfterCrash() {
        do {
            let ids = try database.recoverInterruptedMeetings()
            for id in ids {
                let recovered = try importer.recoverInterruptedRecording(meetingId: id)
                Self.logger.notice("Recovered \(recovered) track(s) for interrupted meeting")
            }
            recoveredMeetings = ids
            try database.enforceProfileRetention()
            try AudioRetention(database: database, paths: paths).apply(days: settings.audioRetentionDays)
            try VideoRetention(database: database, paths: paths).apply(days: settings.videoRetentionDays)
            // Files left behind by an interrupted delete or a crash mid-transcription.
            let orphans = try StorageMaintenance.removeOrphanedRecordings(database: database, paths: paths)
            let temporary = StorageMaintenance.sweepTemporaryFiles()
            if orphans.removedItems + temporary.removedItems > 0 {
                Self.logger.notice("Removed \(orphans.removedItems + temporary.removedItems) leftover item(s), \(orphans.freedBytes + temporary.freedBytes) bytes")
            }
        } catch {
            Self.logger.error("Recovery failed: \(error.localizedDescription, privacy: .public)")
        }
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
