import Foundation
import GRDB
import MeetingCore
import Testing
@testable import MeetingIntelligenceApp

nonisolated private final class ScriptedProvider: AIProvider, @unchecked Sendable {
    enum Behavior { case hangUntilCancelled, fail }
    let kind: AIProviderKind
    let behavior: Behavior

    init(kind: AIProviderKind, behavior: Behavior) {
        self.kind = kind
        self.behavior = behavior
    }

    func detect(configuration: AIProviderConfiguration) async -> ProviderStatus {
        ProviderStatus(kind: kind, installed: true, version: "fake-1", authenticated: true, models: [])
    }

    func complete(_ request: AIRequest, configuration: AIProviderConfiguration) async throws -> AIResponse {
        switch behavior {
        case .hangUntilCancelled:
            do { try await Task.sleep(for: .seconds(60)) } catch { throw URLError(.cancelled) }
            throw URLError(.timedOut)
        case .fail:
            throw URLError(.cannotConnectToHost)
        }
    }
}

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
        #expect(ai.analysisError(for: meeting.id) == nil)
        #expect(try analysisCount(db, meeting.id) == 1)
    }

    @Test func dontAskAgainIsPerProviderPersistsAndCanBeRevoked() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        let meeting = try AppFixture.meeting(db)
        let provider = CountingProvider(kind: .codex)
        let ai = AIController(database: db, defaults: suite.defaults, providerFor: { _ in provider })
        ai.selectedProvider = .codex

        ai.analyze(meetingId: meeting.id)
        #expect(ai.pendingConsent != nil)
        ai.confirmConsent(remember: true)
        try await waitUntil { !ai.isAnalyzing(meeting.id) }
        #expect(provider.calls == 1)

        // Survives a relaunch and only applies to that provider.
        let reopened = AIController(database: db, defaults: suite.defaults, providerFor: { _ in provider })
        #expect(!reopened.asksConsent(for: .codex))
        #expect(reopened.asksConsent(for: .claudeCode))
        reopened.selectedProvider = .codex
        reopened.analyze(meetingId: meeting.id)
        #expect(reopened.pendingConsent == nil)
        try await waitUntil { !reopened.isAnalyzing(meeting.id) }
        #expect(provider.calls == 2)

        reopened.setAsksConsent(true, for: .codex)
        reopened.analyze(meetingId: meeting.id)
        #expect(reopened.pendingConsent != nil)
        reopened.declineConsent()
        #expect(provider.calls == 2)
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

    @Test func chatUsesConfigurationChosenAtSendEvenIfSelectionChanges() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        _ = try AppFixture.meeting(db)
        let codex = CountingProvider(kind: .codex)
        let claude = CountingProvider(kind: .claudeCode)
        let ai = AIController(database: db, defaults: suite.defaults,
                              providerFor: { $0 == .codex ? codex : claude })
        ai.selectedProvider = .codex
        ai.save(AIProviderConfiguration(provider: .codex, model: "chosen-model", effort: "high"))
        let sentConfiguration = ai.configuration(for: ai.selectedProvider)

        // Selection can change while the chat awaits semantic retrieval or consent.
        ai.selectedProvider = .claudeCode
        ai.selectModel("next-model", for: .codex)
        let sent = Task {
            await ai.ask(question: "indicador de ingresos", scope: .allMeetings, useAI: true,
                         configuration: sentConfiguration)
        }
        try await waitUntil { ai.pendingConsent != nil }
        #expect(ai.pendingConsent?.provider == .codex)
        #expect(codex.calls == 0 && claude.calls == 0)
        ai.confirmConsent()
        let answer = try #require(await sent.value)
        #expect(answer.provider == .codex)
        #expect(codex.lastRequest?.model == "chosen-model")
        #expect(codex.lastRequest?.effort == "high")
        #expect(codex.calls == 1 && claude.calls == 0)
        #expect(ai.selectedProvider == .claudeCode)
        #expect(ai.selectedModel(for: .codex) == "next-model")
    }

    @Test func selectedProviderIsRemembered() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        #expect(AIController(database: db, defaults: suite.defaults).selectedProvider == .claudeCode)
        AIController(database: db, defaults: suite.defaults).selectedProvider = .ollama
        #expect(AIController(database: db, defaults: suite.defaults).selectedProvider == .ollama)
    }

    @Test func legacyCopilotAutoWithMediumEffortCanAnalyzeAfterConsent() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        let meeting = try AppFixture.meeting(db)
        // Reproduce the persisted combination that stopped real runs before sending.
        try db.save(providerConfiguration: AIProviderConfiguration(provider: .copilotCLI, effort: "medium"))
        let provider = CountingProvider(kind: .copilotCLI)
        let ai = AIController(database: db, defaults: suite.defaults, providerFor: { _ in provider })
        ai.selectedProvider = .copilotCLI
        #expect(ai.configuration(for: .copilotCLI).effort == nil)
        #expect(!ai.configuration(for: .copilotCLI).supportsEffortSelection)

        ai.analyze(meetingId: meeting.id)
        #expect(ai.pendingConsent?.provider == .copilotCLI)
        #expect(provider.calls == 0)
        ai.confirmConsent()
        try await waitUntil { !ai.isAnalyzing(meeting.id) }
        #expect(provider.calls == 1 && ai.analysisError(for: meeting.id) == nil)
        let result = try await db.reader.read {
            try AIAnalysis.filter(Column("meetingId") == meeting.id).fetchOne($0)
        }
        #expect(result?.status == .succeeded && result?.effort == nil)
    }

    @Test func copilotClearsEffortOnlyForAutomaticModels() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        let ai = AIController(database: db, defaults: suite.defaults)
        for model in [nil, "", " auto ", "Auto", "\n"] as [String?] {
            let configuration = AIProviderConfiguration(provider: .copilotCLI, model: model, effort: "medium")
            ai.save(configuration)
            #expect(!configuration.supportsEffortSelection)
            #expect(try db.providerConfiguration(.copilotCLI).effort == nil)
        }
        let explicit = AIProviderConfiguration(provider: .copilotCLI, model: "gpt-5.6-luna", effort: "medium")
        ai.save(explicit)
        #expect(explicit.supportsEffortSelection)
        #expect(try db.providerConfiguration(.copilotCLI).effort == "medium")

        ai.save(AIProviderConfiguration(provider: .codex, effort: "medium"))
        #expect(ai.configuration(for: .codex).supportsEffortSelection)
        #expect(try db.providerConfiguration(.codex).effort == "medium")
    }

    @Test func selectedCatalogModelIsPersistedAndSentToProvider() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        let meeting = try AppFixture.meeting(db)
        let provider = CountingProvider(kind: .copilotCLI, models: ["model-b", "model-a", "model-a"])
        let ai = AIController(database: db, defaults: suite.defaults, providerFor: { _ in provider })
        await ai.refreshStatuses()
        #expect(ai.modelChoices(for: .copilotCLI) == ["model-a", "model-b"])
        ai.selectModel("model-b", for: .copilotCLI)
        #expect(try db.providerConfiguration(.copilotCLI).model == "model-b")
        ai.selectedProvider = .copilotCLI
        ai.analyze(meetingId: meeting.id)
        ai.confirmConsent()
        try await waitUntil { !ai.isAnalyzing(meeting.id) }
        #expect(provider.lastRequest?.model == "model-b")

        var config = ai.configuration(for: .copilotCLI)
        config.effort = "medium"
        ai.save(config)
        ai.selectModel("", for: .copilotCLI)
        #expect(ai.selectedModel(for: .copilotCLI).isEmpty)
        #expect(ai.configuration(for: .copilotCLI).effort == nil)
    }

    @Test func unavailableCopilotCatalogKeepsOnlySavedModelChoice() async throws {
        let db = try AppDatabase.inMemory()
        let meeting = try AppFixture.meeting(db)
        try await db.writer.write { database in
            try AIAnalysis(meetingId: meeting.id, provider: .copilotCLI, model: "used-model", promptVersion: "fixture",
                           sharedContentSummary: "fixture", status: .succeeded).insert(database)
            try AIAnalysis(meetingId: meeting.id, provider: .copilotCLI, model: "failed-model", promptVersion: "fixture",
                           sharedContentSummary: "fixture", status: .failed).insert(database)
        }
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let ai = AIController(database: db, defaults: suite.defaults)
        ai.selectModel("saved-model", for: .copilotCLI)
        #expect(ai.modelChoices(for: .copilotCLI) == ["saved-model"])
    }

    @Test func copilotAutoOnlyCatalogDoesNotOfferPreviouslyRoutedModels() async throws {
        let db = try AppDatabase.inMemory()
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let provider = CountingProvider(kind: .copilotCLI, catalogLoaded: true)
        let ai = AIController(database: db, defaults: suite.defaults, providerFor: { _ in provider })
        ai.save(AIProviderConfiguration(provider: .copilotCLI, model: "previously-routed-model", effort: "medium"))
        await ai.refreshStatuses()
        #expect(ai.modelChoices(for: .copilotCLI).isEmpty)
        #expect(ai.selectedModel(for: .copilotCLI).isEmpty)
        #expect(try db.providerConfiguration(.copilotCLI).model == nil)
        #expect(try db.providerConfiguration(.copilotCLI).effort == nil)
    }

    @Test func concurrentQuestionsEachGetTheirOwnConsent() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        _ = try AppFixture.meeting(db)
        let provider = CountingProvider(kind: .claudeCode)
        let ai = AIController(database: db, defaults: suite.defaults, providerFor: { _ in provider })
        ai.selectedProvider = .claudeCode

        let first = Task { await ai.ask(question: "indicador de ingresos", scope: .allMeetings, useAI: true) }
        try await waitUntil { ai.consentQueue.count == 1 }
        let second = Task { await ai.ask(question: "equipo de ingresos", scope: .allMeetings, useAI: true) }
        try await waitUntil { ai.consentQueue.count == 2 }
        let firstRequest = try #require(ai.pendingConsent)

        ai.declineConsent()
        let local = try #require(await first.value)
        #expect(local.provider == nil && local.text == nil)
        #expect(ai.pendingConsent != nil && ai.pendingConsent?.id != firstRequest.id)
        #expect(provider.calls == 0)

        ai.confirmConsent()
        let answer = try #require(await second.value)
        #expect(answer.provider == .claudeCode)
        #expect(provider.calls == 1)
        #expect(ai.pendingConsent == nil)
    }

    @Test func questionAndAnalysisConsentAreAskedOneAfterTheOther() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        let meeting = try AppFixture.meeting(db)
        let provider = CountingProvider(kind: .codex)
        let ai = AIController(database: db, defaults: suite.defaults, providerFor: { _ in provider })
        ai.selectedProvider = .codex

        let question = Task { await ai.ask(question: "indicador de ingresos", scope: .allMeetings, useAI: true) }
        try await waitUntil { ai.pendingConsent != nil }
        ai.analyze(meetingId: meeting.id)
        ai.analyze(meetingId: meeting.id)
        #expect(ai.consentQueue.count == 2)
        #expect(ai.pendingConsent?.analysisMeetingId == nil)

        ai.confirmConsent()
        let answer = try #require(await question.value)
        #expect(answer.provider == .codex)
        #expect(ai.pendingConsent?.analysisMeetingId == meeting.id)
        #expect(!ai.isAnalyzing(meeting.id))

        ai.confirmConsent()
        #expect(ai.isAnalyzing(meeting.id))
        try await waitUntil { !ai.isAnalyzing(meeting.id) }
        #expect(provider.calls == 2)
        #expect(try analysisCount(db, meeting.id) == 1)
        #expect(ai.pendingConsent == nil)
    }

    @Test func rememberingConsentAlsoSendsQueuedRequestsForThatProviderOnly() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        _ = try AppFixture.meeting(db)
        let codex = CountingProvider(kind: .codex)
        let claude = CountingProvider(kind: .claudeCode)
        let ai = AIController(database: db, defaults: suite.defaults, providerFor: { $0 == .codex ? codex : claude })
        let codexConfiguration = AIProviderConfiguration(provider: .codex)
        let claudeConfiguration = AIProviderConfiguration(provider: .claudeCode)

        let first = Task { await ai.ask(question: "indicador de ingresos", scope: .allMeetings, useAI: true,
                                        configuration: codexConfiguration) }
        try await waitUntil { ai.consentQueue.count == 1 }
        let other = Task { await ai.ask(question: "indicador de ingresos", scope: .allMeetings, useAI: true,
                                        configuration: claudeConfiguration) }
        try await waitUntil { ai.consentQueue.count == 2 }
        let third = Task { await ai.ask(question: "equipo de ingresos", scope: .allMeetings, useAI: true,
                                        configuration: codexConfiguration) }
        try await waitUntil { ai.consentQueue.count == 3 }

        ai.confirmConsent(remember: true)
        let firstAnswer = try #require(await first.value)
        let thirdAnswer = try #require(await third.value)
        #expect(firstAnswer.provider == .codex && thirdAnswer.provider == .codex)
        #expect(codex.calls == 2 && claude.calls == 0)
        #expect(ai.pendingConsent?.provider == .claudeCode)
        #expect(!ai.asksConsent(for: .codex))

        ai.declineConsent()
        let otherAnswer = try #require(await other.value)
        #expect(otherAnswer.provider == nil)
        #expect(claude.calls == 0)
    }

    @Test func ollamaCloudModelsAskForConsentAndLocalOnesDoNot() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        let meeting = try AppFixture.meeting(db)
        let provider = CountingProvider(kind: .ollama)
        let ai = AIController(database: db, defaults: suite.defaults, providerFor: { _ in provider })
        ai.selectedProvider = .ollama

        ai.selectModel("gpt-oss:120b-cloud", for: .ollama)
        #expect(ai.sendsDataToRemoteService(.ollama))
        ai.analyze(meetingId: meeting.id)
        let consent = try #require(ai.pendingConsent)
        #expect(consent.provider == .ollama && consent.model == "gpt-oss:120b-cloud")
        ai.declineConsent()
        #expect(provider.calls == 0)

        ai.selectModel("llama3.2", for: .ollama)
        #expect(!ai.sendsDataToRemoteService(.ollama))
        ai.analyze(meetingId: meeting.id)
        #expect(ai.pendingConsent == nil)
        try await waitUntil { !ai.isAnalyzing(meeting.id) }
        #expect(provider.calls == 1)
    }

    @Test func cancellingAnAnalysisIsNotAFailureAndErrorsStayWithTheirMeeting() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        let first = try AppFixture.meeting(db)
        let second = try AppFixture.meeting(db)
        var behavior = ScriptedProvider.Behavior.hangUntilCancelled
        let ai = AIController(database: db, defaults: suite.defaults,
                              providerFor: { ScriptedProvider(kind: $0, behavior: behavior) })
        ai.selectedProvider = .ollama

        ai.analyze(meetingId: first.id)
        #expect(ai.isAnalyzing(first.id))
        try await Task.sleep(for: .milliseconds(50))
        ai.cancelAnalysis(first.id)
        try await waitUntil { !ai.isAnalyzing(first.id) }
        #expect(ai.analysisError(for: first.id) == nil)

        behavior = .fail
        ai.analyze(meetingId: second.id)
        try await waitUntil { !ai.isAnalyzing(second.id) }
        #expect(ai.analysisError(for: second.id) != nil)
        #expect(ai.analysisError(for: first.id) == nil)
        ai.dismissAnalysisError(for: second.id)
        #expect(ai.analysisError(for: second.id) == nil)

        let reply = await ai.reply(question: "indicador de ingresos", scope: .allMeetings, useAI: true)
        #expect(reply.aiError != nil)
        #expect(reply.answer?.provider == nil && reply.answer?.excerpts.isEmpty == false)
        #expect(ai.analysisError(for: first.id) == nil && ai.analysisError(for: second.id) == nil)
    }

    @Test func statusesAndTracksAreLabelledInSpanish() {
        let statuses: [AnalysisStatus] = [.running, .succeeded, .invalidOutput, .failed, .cancelled]
        for status in statuses {
            #expect(AnalysisStatusLabel.text(status) != status.rawValue)
        }
        for source in AudioSource.allCases {
            #expect(AudioTab.trackDetail(source) != source.rawValue)
        }
    }

    @Test func ollamaCloudChatAsksFirstAndPassesConsentOnlyForRemoteModels() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let db = try AppDatabase.inMemory()
        _ = try AppFixture.meeting(db)
        let provider = CountingProvider(kind: .ollama)
        let ai = AIController(database: db, defaults: suite.defaults, providerFor: { _ in provider })
        let cloud = AIProviderConfiguration(provider: .ollama, model: "gpt-oss:120b-cloud")

        let asked = Task { await ai.ask(question: "indicador de ingresos", scope: .allMeetings, useAI: true,
                                        configuration: cloud) }
        try await waitUntil { ai.pendingConsent != nil }
        #expect(ai.pendingConsent?.provider == .ollama && ai.pendingConsent?.model == "gpt-oss:120b-cloud")
        #expect(provider.calls == 0)
        ai.confirmConsent(remember: true)
        let confirmed = try #require(await asked.value)
        #expect(confirmed.provider == .ollama && provider.calls == 1)

        let standing = try #require(await ai.ask(question: "indicador de ingresos", scope: .allMeetings, useAI: true,
                                                 configuration: cloud))
        #expect(ai.pendingConsent == nil)
        #expect(standing.provider == .ollama && provider.calls == 2)

        let local = try #require(await ai.ask(question: "indicador de ingresos", scope: .allMeetings, useAI: true,
                                              configuration: AIProviderConfiguration(provider: .ollama, model: "llama3.2")))
        #expect(local.provider == .ollama && provider.calls == 3)
    }
}
