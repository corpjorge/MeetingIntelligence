import Foundation
import GRDB
import MeetingCore
import Testing
@testable import MeetingIntelligenceApp

/// Nothing is sent to a cloud provider without the user's explicit confirmation.
@Suite("App: consentimiento de IA")
struct AIControllerTests {
    private func analysisCount(_ db: AppDatabase, _ meetingId: String) throws -> Int {
        try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM aiAnalysis WHERE meetingId = ?",
                                              arguments: [meetingId]) ?? 0 }
    }

    @Test func remoteAnalysisWaitsForConsentAndDeclineSendsNothing() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        let meeting = try AppFixture.meeting(db)
        let provider = CountingProvider(kind: .codex)
        let ai = AIController(database: db, defaults: suite.defaults, providerFor: { _ in provider })
        ai.selectedProvider = .codex

        ai.analyze(meetingId: meeting.id)
        let consent = try #require(ai.pendingConsent)
        #expect(consent.provider == .codex)
        #expect(consent.characterCount > 0 && !consent.summary.isEmpty)
        #expect(!ai.isAnalyzing(meeting.id))

        ai.declineConsent()
        #expect(ai.pendingConsent == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(provider.calls == 0)
        #expect(try analysisCount(db, meeting.id) == 0)

        ai.analyze(meetingId: meeting.id)
        ai.confirmConsent()
        #expect(ai.isAnalyzing(meeting.id))
        try await waitUntil { !ai.isAnalyzing(meeting.id) }
        #expect(provider.calls == 1)
        #expect(ai.lastError == nil)
        #expect(try analysisCount(db, meeting.id) == 1)
    }

    @Test func localProviderRunsWithoutAsking() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        let meeting = try AppFixture.meeting(db)
        let provider = CountingProvider(kind: .ollama)
        let ai = AIController(database: db, defaults: suite.defaults, providerFor: { _ in provider })
        ai.selectedProvider = .ollama

        ai.analyze(meetingId: meeting.id)
        #expect(ai.pendingConsent == nil)
        try await waitUntil { !ai.isAnalyzing(meeting.id) }
        #expect(provider.calls == 1)
        #expect(try analysisCount(db, meeting.id) == 1)
    }

    @Test func chatFallsBackToLocalSearchWhenConsentIsDeclined() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        _ = try AppFixture.meeting(db)
        let provider = CountingProvider(kind: .claudeCode)
        let ai = AIController(database: db, defaults: suite.defaults, providerFor: { _ in provider })
        ai.selectedProvider = .claudeCode

        let declined = Task { await ai.ask(question: "indicador de ingresos", scope: .allMeetings, useAI: true) }
        try await waitUntil { ai.pendingConsent != nil }
        ai.declineConsent()
        let local = try #require(await declined.value)
        #expect(local.provider == nil && local.text == nil)
        #expect(!local.excerpts.isEmpty)
        #expect(provider.calls == 0)

        let confirmed = Task { await ai.ask(question: "indicador de ingresos", scope: .allMeetings, useAI: true) }
        try await waitUntil { ai.pendingConsent != nil }
        ai.confirmConsent()
        let answer = try #require(await confirmed.value)
        #expect(answer.provider == .claudeCode)
        #expect(answer.citations.map(\.reference) == ["C1"])
        #expect(provider.calls == 1)
    }

    @Test func selectedProviderIsRemembered() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        #expect(AIController(database: db, defaults: suite.defaults).selectedProvider == .claudeCode)
        AIController(database: db, defaults: suite.defaults).selectedProvider = .ollama
        #expect(AIController(database: db, defaults: suite.defaults).selectedProvider == .ollama)
    }
}
