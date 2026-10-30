import Foundation
import GRDB
import Testing
@testable import MeetingCore

final class DetectUntilCancelledProvider: AIProvider, @unchecked Sendable {
    let kind = AIProviderKind.claudeCode
    private let lock = NSLock()
    private var calls = 0

    var completeCalls: Int { lock.withLock { calls } }

    func detect(configuration: AIProviderConfiguration) async -> ProviderStatus {
        try? await Task.sleep(for: .seconds(20))
        return ProviderStatus(kind: kind, installed: true, version: "fake", authenticated: true)
    }

    func complete(_ request: AIRequest, configuration: AIProviderConfiguration) async throws -> AIResponse {
        lock.withLock { calls += 1 }
        throw AIProviderError.failed(kind, "no debía enviarse")
    }
}

struct SleepingCLIProvider: AIProvider {
    let kind = AIProviderKind.ollama

    func detect(configuration: AIProviderConfiguration) async -> ProviderStatus {
        ProviderStatus(kind: kind, installed: true, version: "fake", authenticated: true)
    }

    func complete(_ request: AIRequest, configuration: AIProviderConfiguration) async throws -> AIResponse {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 60)
        throw AIProviderError.failed(kind, "terminó con el código \(result.exitCode)")
    }
}

@Suite("IA: cancelación, consentimiento de Ollama Cloud, citas y decisiones previas")
struct AIFixServiceTests {
    private func isConsentError(_ error: AIProviderError?) -> Bool {
        if case .remoteConsentRequired? = error { return true }
        return false
    }

    private func items(_ db: AppDatabase, analysisId: String) async throws -> [AnalysisItem] {
        try await db.reader.read { db in
            try AnalysisItem.filter(Column("analysisId") == analysisId).order(Column("orderIndex")).fetchAll(db)
        }
    }

    @Test func cancellingDuringDetectionSendsNothing() async throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, _) = try Fixture.meeting(db, texts: [("hola equipo", 0, 1)])
        let service = MeetingAnalysisService(database: db)
        let prepared = try service.prepare(meetingId: meeting.id, model: nil, timeout: 30)
        let provider = DetectUntilCancelledProvider()
        let task = Task {
            try await service.run(meetingId: meeting.id, provider: provider,
                                  configuration: AIProviderConfiguration(provider: .claudeCode),
                                  prepared: prepared, consentGiven: true)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(provider.completeCalls == 0)
        #expect(try await db.reader.read { try AIAnalysis.fetchCount($0) } == 0)
    }

    @Test func cancellingTheCLIMarksTheAnalysisCancelled() async throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, _) = try Fixture.meeting(db, texts: [("hola equipo", 0, 1)])
        let service = MeetingAnalysisService(database: db)
        let prepared = try service.prepare(meetingId: meeting.id, model: "llama3.2", timeout: 30)
        let task = Task {
            try await service.run(meetingId: meeting.id, provider: SleepingCLIProvider(),
                                  configuration: AIProviderConfiguration(provider: .ollama),
                                  prepared: prepared, consentGiven: false)
        }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let stored = try await db.reader.read { try AIAnalysis.fetchAll($0) }
        #expect(stored.map(\.status) == [.cancelled])
    }

    @Test func ollamaCloudModelsNeedConsent() async throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, _) = try Fixture.meeting(db, texts: [("hola equipo, revisemos el plan", 0, 1)])
        let service = MeetingAnalysisService(database: db)
        let answer = #"{"executiveSummary":"s","technicalSummary":"t","items":[]}"#

        let cloud = try service.prepare(meetingId: meeting.id, model: "gpt-oss:120b-cloud", timeout: 30)
        let fake = FakeProvider(kind: .ollama, answer: answer)
        let refused = await #expect(throws: AIProviderError.self) {
            try await service.run(meetingId: meeting.id, provider: fake, configuration: AIProviderConfiguration(provider: .ollama),
                                  prepared: cloud, consentGiven: false)
        }
        #expect(isConsentError(refused))

        var configured = AIProviderConfiguration(provider: .ollama)
        configured.model = "glm-4.6:cloud"
        let unnamed = try service.prepare(meetingId: meeting.id, model: nil, timeout: 30)
        let refusedFromConfiguration = await #expect(throws: AIProviderError.self) {
            try await service.run(meetingId: meeting.id, provider: fake, configuration: configured, prepared: unnamed,
                                  consentGiven: false)
        }
        #expect(isConsentError(refusedFromConfiguration))
        #expect(fake.lastRequest == nil)

        let local = try service.prepare(meetingId: meeting.id, model: "llama3.2", timeout: 30)
        #expect(try await service.run(meetingId: meeting.id, provider: fake, configuration: configured, prepared: local,
                                      consentGiven: false).status == .succeeded)
        #expect(try await service.run(meetingId: meeting.id, provider: fake, configuration: configured, prepared: cloud,
                                      consentGiven: true).status == .succeeded)

        let chat = MeetingChatService(database: db)
        let retrieval = try chat.retrieve(question: "¿Qué plan?", scope: .allMeetings, model: "gpt-oss:120b-cloud", timeout: 30)
        let chatFake = FakeProvider(kind: .ollama, answer: #"{"answer":"x","citations":[],"found":false}"#)
        let chatRefused = await #expect(throws: AIProviderError.self) {
            try await chat.answer(question: "¿Qué plan?", retrieval: retrieval, provider: chatFake,
                                  configuration: AIProviderConfiguration(provider: .ollama), consentGiven: false)
        }
        #expect(isConsentError(chatRefused))
        #expect(chatFake.lastRequest == nil)
        _ = try await chat.answer(question: "¿Qué plan?", retrieval: retrieval, provider: chatFake,
                                  configuration: AIProviderConfiguration(provider: .ollama), consentGiven: true)
        #expect(chatFake.lastRequest != nil)
    }

    @Test func quotesMatchWholeWordsOnly() {
        #expect(!MeetingAnalysisService.quote("acuerdo con el plan", isSupportedBy: "Estoy en desacuerdo con el plan"))
        #expect(!MeetingAnalysisService.quote("Sí", isSupportedBy: "Así es"))
        #expect(MeetingAnalysisService.quote("Sí", isSupportedBy: "Sí, de acuerdo."))
        #expect(MeetingAnalysisService.quote("de acuerdo con el plan", isSupportedBy: "Estoy de acuerdo con el plan."))
        #expect(MeetingAnalysisService.quote("validar ese campo", isSupportedBy: "Debemos validar ese campo en el response"))
    }

    @Test func fallbackNeedsThreeWordsAndIgnoresEcho() async throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, segments) = try Fixture.meeting(db, texts: [
            ("Así es, el plan sigue igual", 0, 2),
            ("Estoy en desacuerdo con el plan de migración", 3, 6),
            ("vamos a migrar todo a Oracle", 7, 9),
        ])
        try await db.writer.write { db in
            var echo = segments[2]
            echo.attribution = .probableEcho
            try echo.update(db)
        }
        func item(_ text: String, _ reference: String, _ quote: String) -> String {
            #"{"category":"agreement","nature":"fact","text":"\#(text)","owner":null,"due":null,"evidenceSegmentId":"\#(reference)","evidenceQuote":"\#(quote)"}"#
        }
        let fake = FakeProvider(answer: #"{"executiveSummary":"s","technicalSummary":"t","items":["#
            + [item("a", "S1", "Sí"), item("b", "S1", "acuerdo con el plan"), item("c", "S2", "Así es"),
               item("d", "S2", "migrar todo a Oracle"), item("e", "S1", "en desacuerdo con el plan")].joined(separator: ",")
            + "]}")
        let service = MeetingAnalysisService(database: db)
        let prepared = try service.prepare(meetingId: meeting.id, model: nil, timeout: 30)
        let analysis = try await service.run(meetingId: meeting.id, provider: fake,
                                             configuration: AIProviderConfiguration(provider: .ollama),
                                             prepared: prepared, consentGiven: false)
        let stored = try await items(db, analysisId: analysis.id)
        #expect(stored.map(\.evidenceStatus) == [.unconfirmed, .unconfirmed, .unconfirmed, .unconfirmed, .verified])
        #expect(stored.last?.evidenceSegmentId == segments[1].id)
        #expect(stored.dropLast().allSatisfy { $0.evidenceSegmentId == nil })
    }

    @Test func previousDecisionsComeFromTheLatestSuccessfulAnalysis() async throws {
        let db = try AppDatabase.inMemory()
        let (previous, _, _, _) = try Fixture.meeting(db, title: "FIXTURE · Comité 1", texts: [("Usaremos PostgreSQL", 0, 2)])
        let (current, _, _, _) = try Fixture.meeting(db, title: "FIXTURE · Comité 2", texts: [("Seguimos con el plan", 0, 2)])
        func analysis(_ status: AnalysisStatus, at seconds: Double) -> AIAnalysis {
            AIAnalysis(meetingId: previous.id, provider: .ollama, model: "m", promptVersion: MeetingAnalysisService.promptVersion,
                       sharedContentSummary: "", status: status, startedAt: Date(timeIntervalSince1970: seconds))
        }
        let old = analysis(.succeeded, at: 1_000), latest = analysis(.succeeded, at: 2_000), failed = analysis(.failed, at: 3_000)
        try await db.writer.write { db in
            for record in [old, latest, failed] { try record.insert(db) }
            try AnalysisItem(analysisId: old.id, meetingId: previous.id, category: .decision, nature: .fact,
                             text: "Usar MySQL", evidenceStatus: .verified, orderIndex: 0).insert(db)
            try AnalysisItem(analysisId: latest.id, meetingId: previous.id, category: .decision, nature: .fact,
                             text: "Usar PostgreSQL", evidenceStatus: .verified, orderIndex: 0).insert(db)
            try AnalysisItem(analysisId: latest.id, meetingId: previous.id, category: .commitment, nature: .fact,
                             text: "Migrar el esquema", evidenceStatus: .verified, orderIndex: 1).insert(db)
        }
        let prepared = try MeetingAnalysisService(database: db)
            .prepare(meetingId: current.id, previousMeetingIds: [previous.id], model: nil, timeout: 30)
        #expect(prepared.request.input.contains("[P1 | FIXTURE · Comité 1"))
        #expect(prepared.request.input.contains("decision: Usar PostgreSQL"))
        #expect(prepared.request.input.contains("[P2 | FIXTURE · Comité 1"))
        #expect(!prepared.request.input.contains("Usar MySQL"))
        #expect(prepared.sharedSummary.contains("2 decisiones verificadas"))
    }

    @Test func chatCitationsAreUniqueAndKeepTheirOrder() async throws {
        let db = try AppDatabase.inMemory()
        _ = try Fixture.meeting(db, texts: [("El indicador de ingresos validados se expone", 10, 14),
                                            ("El indicador de riesgo se calcula al cierre", 20, 24)])
        let chat = MeetingChatService(database: db)
        let retrieval = try chat.retrieve(question: "indicador", scope: .allMeetings, model: nil, timeout: 30)
        #expect(retrieval.context.count == 2)
        let fake = FakeProvider(answer: #"{"answer":"x","citations":["C2","C1","[C2]"," C1 ","C2"],"found":true}"#)
        let answer = try await chat.answer(question: "indicador", retrieval: retrieval, provider: fake,
                                           configuration: AIProviderConfiguration(provider: .ollama), consentGiven: false)
        #expect(answer.citations.map(\.reference) == ["C2", "C1"])
        #expect(Set(answer.citations.map(\.id)).count == answer.citations.count)
    }
}
