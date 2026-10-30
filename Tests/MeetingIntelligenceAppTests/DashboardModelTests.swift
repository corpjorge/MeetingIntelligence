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

    @Test func listsOnlyLatestSuccessfulAnalysisOrderedByMeetingDate() async throws {
        let db = try AppDatabase.inMemory()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var olderDraft = try AppFixture.meeting(db)
        olderDraft.startedAt = base
        let older = olderDraft
        var newerDraft = try AppFixture.meeting(db)
        newerDraft.title = "FIXTURE · Reciente"
        newerDraft.startedAt = base.addingTimeInterval(86_400)
        let newer = newerDraft
        let superseded = analysis(meetingId: older.id, startedAt: base.addingTimeInterval(60))
        let current = analysis(meetingId: older.id, startedAt: base.addingTimeInterval(120))
        let failed = AIAnalysis(meetingId: older.id, provider: .ollama, model: "fixture", promptVersion: "fixture",
                                sharedContentSummary: "FIXTURE", status: .failed, startedAt: base.addingTimeInterval(180))
        let newerRun = analysis(meetingId: newer.id, startedAt: base.addingTimeInterval(240))
        func item(_ run: AIAnalysis, _ text: String, _ index: Int) -> AnalysisItem {
            AnalysisItem(analysisId: run.id, meetingId: run.meetingId, category: index == 0 ? .commitment : .actionItem,
                         nature: .fact, text: text, evidenceStatus: .unconfirmed, orderIndex: index)
        }
        let stale = [item(superseded, "Copia anterior 0", 0), item(superseded, "Copia anterior 1", 1)]
        let currentItems = [item(current, "Actual 1", 1), item(current, "Actual 0", 0)]
        let failedItem = item(failed, "Análisis fallido", 0)
        let newerItems = [item(newerRun, "Reciente 1", 1), item(newerRun, "Reciente 0", 0)]
        try await db.writer.write { database in
            try older.update(database)
            try newer.update(database)
            for run in [superseded, current, failed, newerRun] { try run.insert(database) }
            for entry in stale + currentItems + [failedItem] + newerItems { try entry.insert(database) }
        }

        let model = DashboardModel()
        let observation = Task { await model.observe(db) }
        defer { observation.cancel() }
        try await waitUntil { model.openItems.count == 4 }
        #expect(model.openItems.map(\.text) == ["Reciente 0", "Reciente 1", "Actual 0", "Actual 1"])

        try await model.setCompleted(currentItems[1].id, completed: true, in: db)
        try await waitUntil { model.openItems.count == 3 }
        #expect(model.openItems.map(\.text) == ["Reciente 0", "Reciente 1", "Actual 1"])
        #expect(!model.openItems.contains { stale.map(\.id).contains($0.id) })
    }

    @Test func ordersOpenItemsByMeetingDateThenOrderIndex() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        func item(_ meetingId: String, _ index: Int) -> AnalysisItem {
            AnalysisItem(analysisId: "fixture", meetingId: meetingId, category: .commitment, nature: .fact,
                         text: "\(meetingId)\(index)", evidenceStatus: .unconfirmed, orderIndex: index)
        }
        let items = [item("a", 1), item("b", 2), item("a", 0), item("b", 0), item("c", 0)]
        let ordered = DashboardModel.orderedOpenItems(items, meetingDates: ["a": early, "b": late])
        #expect(ordered.map(\.text) == ["b0", "b2", "a0", "a1", "c0"])
    }

    private func analysis(meetingId: String, startedAt: Date = Date()) -> AIAnalysis {
        AIAnalysis(meetingId: meetingId, provider: .ollama, model: "fixture", promptVersion: "fixture",
                   sharedContentSummary: "FIXTURE", status: .succeeded, startedAt: startedAt)
    }
}
