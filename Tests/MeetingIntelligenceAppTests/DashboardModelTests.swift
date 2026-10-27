import Foundation
import GRDB
import Testing
@testable import MeetingCore
@testable import MeetingIntelligenceApp

@Suite("App: compromisos del inicio")
struct DashboardModelTests {
    @Test func observesAllOpenItemsAndTheirMeetingTitles() async throws {
        let db = try AppDatabase.inMemory()
        let first = try AppFixture.meeting(db)
        var secondDraft = try AppFixture.meeting(db)
        secondDraft.title = "FIXTURE · Seguimiento"
        let second = secondDraft
        let firstAnalysis = analysis(meetingId: first.id)
        let secondAnalysis = analysis(meetingId: second.id)
        let pending = (0..<12).map { index in
            AnalysisItem(analysisId: index < 6 ? firstAnalysis.id : secondAnalysis.id,
                         meetingId: index < 6 ? first.id : second.id,
                         category: index.isMultiple(of: 2) ? .commitment : .actionItem,
                         nature: .fact, text: "FIXTURE · Compromiso \(index)",
                         evidenceStatus: .unconfirmed, orderIndex: index)
        }
        try await db.writer.write { database in
            try second.update(database)
            try firstAnalysis.insert(database)
            try secondAnalysis.insert(database)
            for item in pending { try item.insert(database) }
            try AnalysisItem(analysisId: firstAnalysis.id, meetingId: first.id, category: .commitment,
                             nature: .fact, text: "Ya completado", evidenceStatus: .unconfirmed,
                             orderIndex: 20, completedAt: Date()).insert(database)
            try AnalysisItem(analysisId: firstAnalysis.id, meetingId: first.id, category: .decision,
                             nature: .fact, text: "Decisión", evidenceStatus: .unconfirmed, orderIndex: 21).insert(database)
        }

        let model = DashboardModel()
        let observation = Task { await model.observe(db) }
        defer { observation.cancel() }
        try await waitUntil { model.openItems.count == 12 }
        #expect(Set(model.openItems.map(\.id)) == Set(pending.map(\.id)))
        #expect(model.meetingTitles[first.id] == first.title)
        #expect(model.meetingTitles[second.id] == second.title)

        try await model.setCompleted(pending[0].id, completed: true, in: db)
        try await waitUntil { model.openItems.count == 11 }
        #expect(!model.openItems.contains { $0.id == pending[0].id })

        try await model.setCompleted(pending[0].id, completed: false, in: db)
        try await waitUntil { model.openItems.count == 12 }
        #expect(model.openItems.contains { $0.id == pending[0].id })

        try await db.writer.write { database in
            var renamed = second
            renamed.title = "FIXTURE · Nuevo título"
            try renamed.update(database)
        }
        try await waitUntil { model.meetingTitles[second.id] == "FIXTURE · Nuevo título" }
    }

    @Test func completionPersistsAndKeepsTextAndEvidence() async throws {
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase.open(paths: paths)
        let meeting = try AppFixture.meeting(db)
        let analysis = analysis(meetingId: meeting.id)
        let item = AnalysisItem(analysisId: analysis.id, meetingId: meeting.id, category: .commitment,
                                nature: .fact, text: "Compartir el informe", ownerName: "Equipo",
                                evidenceQuote: "Compartiremos el informe", evidenceStatus: .unconfirmed,
                                orderIndex: 0)
        try await db.writer.write { database in
            try analysis.insert(database)
            try item.insert(database)
        }
        let model = DashboardModel()
        try await model.setCompleted(item.id, completed: true, in: db)
        let saved = try await db.reader.read { try AnalysisItem.fetchOne($0, key: item.id) }
        let firstCompletion = try #require(saved?.completedAt)
        #expect(saved?.text == item.text && saved?.evidenceQuote == item.evidenceQuote)

        // Repeated clicks keep a completed item closed, rather than toggling it.
        try await model.setCompleted(item.id, completed: true, in: db)
        let reopenedDatabase = try AppDatabase.open(paths: paths)
        let persisted = try await reopenedDatabase.reader.read { try AnalysisItem.fetchOne($0, key: item.id) }
        #expect(persisted?.completedAt == firstCompletion)
        #expect(persisted?.ownerName == "Equipo")

        try await model.setCompleted(item.id, completed: false, in: reopenedDatabase)
        let undone = try await db.reader.read { try AnalysisItem.fetchOne($0, key: item.id) }
        #expect(undone?.completedAt == nil)
        #expect(undone?.text == item.text && undone?.evidenceQuote == item.evidenceQuote)
    }

    private func analysis(meetingId: String) -> AIAnalysis {
        AIAnalysis(meetingId: meetingId, provider: .ollama, model: "fixture", promptVersion: "fixture",
                   sharedContentSummary: "FIXTURE", status: .succeeded)
    }
}
