import Foundation
import MeetingCore
import MeetingSpeech
import Testing
@testable import MeetingIntelligenceApp

/// Queue semantics with the real pipeline: unknown meetings fail before any model is loaded.
@Suite("App: cola de procesamiento")
struct ProcessingCoordinatorTests {
    private func makeCoordinator(_ suite: IsolatedDefaults, _ paths: AppPaths, _ db: AppDatabase) -> ProcessingCoordinator {
        let processor = MeetingProcessor(database: db, paths: paths, asr: ParakeetUltraProvider(),
                                         diarizer: DiarizationService(), recognizer: nil)
        return ProcessingCoordinator(processor: processor, settings: AppSettings(defaults: suite.defaults), database: db)
    }

    @Test func processesOneMeetingAtATimeWithoutDuplicatesAndReportsErrors() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase.inMemory()
        let silent = Meeting(title: "FIXTURE · sin audio", origin: .imported, captureScope: .importedFile, status: .recorded)
        try db.insert(meeting: silent, tracks: [])
        let coordinator = makeCoordinator(suite, paths, db)
        var completed: [String] = []
        coordinator.onCompleted = { completed.append($0) }

        coordinator.enqueue("missing-1")
        #expect(coordinator.active?.meetingId == "missing-1")
        #expect(coordinator.isBusy("missing-1"))
        coordinator.enqueue("missing-1") // already active → ignored
        coordinator.enqueue("missing-2")
        coordinator.enqueue(silent.id)
        coordinator.enqueue("missing-2") // already queued → ignored
        #expect(coordinator.queue == ["missing-2", silent.id])
        #expect(coordinator.progress(for: "missing-2") == nil)

        coordinator.cancel("missing-2") // queued → removed, never processed
        #expect(coordinator.queue == [silent.id])
        #expect(!coordinator.isBusy("missing-2"))

        try await waitUntil { coordinator.active == nil && coordinator.queue.isEmpty }
        let error = try #require(coordinator.lastError)
        #expect(error.meetingId == silent.id)
        #expect(!error.message.isEmpty)
        #expect(completed.isEmpty)
        coordinator.dismissError()
        #expect(coordinator.lastError == nil)
    }

    @Test func deletedMeetingsAreTreatedAsCancelledNotFailed() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase.inMemory()
        let coordinator = makeCoordinator(suite, paths, db)

        coordinator.enqueue("deleted-meeting")
        try await waitUntil { coordinator.active == nil }
        #expect(coordinator.lastError == nil)
        #expect(coordinator.notice == nil)
    }

    @Test func suspendedStartsKeepJobsQueuedUntilResumed() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase.inMemory()
        let coordinator = makeCoordinator(suite, paths, db)

        coordinator.suspendStarts()
        coordinator.enqueue("missing")
        #expect(coordinator.active == nil)
        #expect(coordinator.queue == ["missing"])
        coordinator.resumeStarts()
        #expect(coordinator.active?.meetingId == "missing")
        try await waitUntil { coordinator.active == nil }
    }

    @Test func reprocessingReportsTextCorrectionsThatCouldNotBeCarriedOver() {
        #expect(ProcessingCoordinator.editsNotice(carried: 4, dropped: 0) == nil)
        #expect(ProcessingCoordinator.editsNotice(carried: 0, dropped: 2)
                == "2 correcciones de texto no se pudieron trasladar al reprocesar; siguen en el historial.")
        #expect(ProcessingCoordinator.editsNotice(carried: 1, dropped: 1)
                == "1 corrección de texto no se pudo trasladar al reprocesar; sigue en el historial. 1 corrección sí se trasladó.")
        #expect(ProcessingCoordinator.editsNotice(carried: 3, dropped: 1)?.hasSuffix("3 correcciones sí se trasladaron.") == true)
    }
}
