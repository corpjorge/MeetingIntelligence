import Foundation
import MeetingCore
import MeetingSpeech
import Testing
@testable import MeetingIntelligenceApp

/// Queue semantics with the real pipeline: unknown meetings fail before any model is loaded.
@Suite("App: cola de procesamiento")
struct ProcessingCoordinatorTests {
    @Test func processesOneMeetingAtATimeWithoutDuplicatesAndReportsErrors() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase.inMemory()
        let processor = MeetingProcessor(database: db, paths: paths, asr: ParakeetUltraProvider(),
                                         diarizer: DiarizationService(), recognizer: nil)
        let coordinator = ProcessingCoordinator(processor: processor, settings: AppSettings(defaults: suite.defaults))
        var completed: [String] = []
        coordinator.onCompleted = { completed.append($0) }

        coordinator.enqueue("missing-1")
        #expect(coordinator.active?.meetingId == "missing-1")
        #expect(coordinator.isBusy("missing-1"))
        coordinator.enqueue("missing-1") // already active → ignored
        coordinator.enqueue("missing-2")
        coordinator.enqueue("missing-3")
        coordinator.enqueue("missing-2") // already queued → ignored
        #expect(coordinator.queue == ["missing-2", "missing-3"])
        #expect(coordinator.progress(for: "missing-2") == nil)

        coordinator.cancel("missing-2") // queued → removed, never processed
        #expect(coordinator.queue == ["missing-3"])
        #expect(!coordinator.isBusy("missing-2"))

        try await waitUntil { coordinator.active == nil && coordinator.queue.isEmpty }
        let error = try #require(coordinator.lastError)
        #expect(error.meetingId == "missing-3")
        #expect(!error.message.isEmpty)
        #expect(completed.isEmpty)
        coordinator.dismissError()
        #expect(coordinator.lastError == nil)
    }
}
