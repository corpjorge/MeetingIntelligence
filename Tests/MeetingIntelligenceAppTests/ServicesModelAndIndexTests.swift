import Foundation
import MeetingCore
import MeetingSpeech
import Testing
@testable import MeetingIntelligenceApp

@Suite("App: modelos e índice semántico")
struct ServicesModelAndIndexTests {
    @Test func modelInstalledAfterLaunchCanBeCheckedAndBlockedLibraryCannotUpdate() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase.inMemory()
        let settings = AppSettings(defaults: suite.defaults)
        let asr = ParakeetUltraProvider()
        let diarizer = DiarizationService()
        let semantic = SemanticIndexController(paths: paths, database: db, settings: settings)
        let processing = ProcessingCoordinator(
            processor: MeetingProcessor(database: db, paths: paths, asr: asr, diarizer: diarizer, recognizer: nil),
            settings: settings, database: db)
        let recording = RecordingController(importer: MeetingImportService(database: db, paths: paths), paths: paths,
                                            settings: settings, asr: asr)
        let updates = ModelUpdateController(asr: asr, diarizer: diarizer, booster: AcousticVocabularyBooster(),
                                            semantic: semantic, settings: settings, processing: processing,
                                            recording: recording)
        let id = semantic.managedModel.id

        updates.refreshInventory()
        #expect(updates.rows.first { $0.id == id }?.state == .notInstalled)
        try FileManager.default.createDirectory(at: semantic.modelDirectory, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: semantic.modelDirectory.appendingPathComponent("model.safetensors"))
        updates.refreshInventory()
        #expect(updates.rows.first { $0.id == id }?.state == .unchecked)

        #expect(!updates.isUpdating && updates.busyReason == nil)
        processing.suspendStarts()
        processing.enqueue("queued")
        #expect(updates.busyReason == "se procesa una reunión")
        updates.blockedReason = "otra copia de la app usa la biblioteca"
        #expect(updates.busyReason == "otra copia de la app usa la biblioteca")
        processing.cancel("queued")
        processing.resumeStarts()
    }

    @Test func semanticIndexStaysOffWhenDisabledOrBlocked() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let settings = AppSettings(defaults: suite.defaults)
        let semantic = SemanticIndexController(paths: paths, database: try AppDatabase.inMemory(), settings: settings)

        semantic.refresh()
        #expect(semantic.status == .disabled)

        settings.semanticSearch = true
        semantic.blockedReason = LibraryStartupPolicy.sharedLibraryReason
        semantic.refresh()
        #expect(semantic.status == .failed(LibraryStartupPolicy.sharedLibraryReason))
        semantic.schedule()
        #expect(semantic.status == .failed(LibraryStartupPolicy.sharedLibraryReason))

        settings.semanticSearch = false
        semantic.refresh()
        #expect(semantic.status == .disabled)
    }

    @Test func modelChangesWaitWhileAnotherProcessHoldsTheModel() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase.inMemory()
        let settings = AppSettings(defaults: suite.defaults)
        let asr = ParakeetUltraProvider()
        let diarizer = DiarizationService()
        let semantic = SemanticIndexController(paths: paths, database: db, settings: settings)
        let updates = ModelUpdateController(
            asr: asr, diarizer: diarizer, booster: AcousticVocabularyBooster(), semantic: semantic, settings: settings,
            processing: ProcessingCoordinator(
                processor: MeetingProcessor(database: db, paths: paths, asr: asr, diarizer: diarizer, recognizer: nil),
                settings: settings, database: db),
            recording: RecordingController(importer: MeetingImportService(database: db, paths: paths), paths: paths,
                                           settings: settings, asr: asr))
        try FileManager.default.createDirectory(at: semantic.modelDirectory, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: semantic.modelDirectory.appendingPathComponent("model.safetensors"))
        let model = semantic.managedModel
        #expect(model.unusedReason != nil)
        updates.refreshInventory()

        let other = try ModelInstaller().beginUpdate(model)
        await updates.deleteUnusedModel(model.id)
        #expect(FileManager.default.fileExists(atPath: model.directory.path))
        #expect(updates.rows.first { $0.id == model.id }?.state
                == .failed(ModelInstallError.busy("otro proceso está actualizando este modelo").localizedDescription))

        other.release()
        await updates.deleteUnusedModel(model.id)
        #expect(!FileManager.default.fileExists(atPath: model.directory.path))
    }
}
