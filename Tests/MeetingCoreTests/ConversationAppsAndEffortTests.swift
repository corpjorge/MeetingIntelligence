import Foundation
import GRDB
import Testing
@testable import MeetingCore

@Suite("Migración v2 y esfuerzo de IA")
struct ConversationAppsAndEffortTests {
    @Test func migrationV2AddsSourceAppPausesAndEffort() throws {
        let db = try AppDatabase.inMemory()
        let columns = try db.reader.read { db in
            (try db.columns(in: "meeting").map(\.name), try db.columns(in: "aiProviderConfiguration").map(\.name),
             try db.columns(in: "aiAnalysis").map(\.name), try db.tableExists("recordingPause"))
        }
        #expect(columns.0.contains("sourceAppBundleID") && columns.0.contains("sourceAppName"))
        #expect(columns.1.contains("effort"))
        #expect(columns.2.contains("effort"))
        #expect(columns.3)

        var meeting = Meeting(title: "FIXTURE · Zoom", origin: .recording, captureScope: .applicationProcesses,
                              status: .recorded, sourceAppBundleID: "us.zoom.xos", sourceAppName: "zoom.us")
        try db.insert(meeting: meeting, tracks: [])
        try db.writer.write { db in
            try RecordingPause(meetingId: meeting.id, source: .localMicrophone, startTime: 10, endTime: 25,
                               reason: .microphonePausedByUser).insert(db)
        }
        let detail = try #require(try db.meetingDetail(id: meeting.id))
        #expect(detail.meeting.captureSourceDescription == "zoom.us")
        #expect(detail.pauses.map(\.endTime) == [25])
        meeting.captureScope = .teamsProcesses
        #expect(meeting.captureSourceDescription == "Microsoft Teams")

        var config = AIProviderConfiguration(provider: .codex)
        config.effort = "high"
        try db.save(providerConfiguration: config)
        #expect(try db.providerConfiguration(.codex).effort == "high")
    }

    private func request(effort: String?) -> AIRequest {
        AIRequest(instructions: "i", input: "x", jsonSchema: "{}", requiredKeys: [], model: "m", effort: effort, timeoutSeconds: 60)
    }

    @Test func effortReachesEachCLIWithItsVerifiedFlag() {
        let claude = ClaudeCodeProvider.arguments(for: request(effort: "xhigh"))
        #expect(claude.windowContains(["--effort", "xhigh"]))
        let codex = CodexProvider.arguments(for: request(effort: "high"), schemaPath: "/s", outputPath: "/o", workingDirectory: "/w")
        #expect(codex.windowContains(["-c", "model_reasoning_effort=\"high\""]))
        #expect(codex.last == "-")
        let agy = AntigravityProvider.arguments(for: request(effort: "max"), prompt: "p")
        #expect(agy.windowContains(["--effort", "max"]))
        // Unknown levels are never forwarded; no effort → provider default.
        #expect(!ClaudeCodeProvider.arguments(for: request(effort: "turbo")).contains("--effort"))
        #expect(!CodexProvider.arguments(for: request(effort: nil), schemaPath: "", outputPath: "", workingDirectory: "")
            .contains { $0.contains("reasoning") })
        // Safety: no permission-bypass flags in any provider.
        for args in [claude, codex, agy] {
            #expect(!args.contains { $0.localizedCaseInsensitiveContains("dangerously") })
        }
        #expect(claude.windowContains(["--tools", ""]))
        #expect(codex.windowContains(["--sandbox", "read-only"]))
    }

    @Test func analysisRecordsTheEffortUsed() async throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, _) = try Fixture.meeting(db, texts: [("hola equipo", 0, 1)])
        let service = MeetingAnalysisService(database: db)
        let prepared = try service.prepare(meetingId: meeting.id, model: "m", effort: "high", timeout: 30)
        #expect(prepared.request.effort == "high")
        let fake = FakeProvider(answer: #"{"executiveSummary":"s","technicalSummary":"t","items":[]}"#)
        let analysis = try await service.run(meetingId: meeting.id, provider: fake,
                                             configuration: AIProviderConfiguration(provider: .ollama),
                                             prepared: prepared, consentGiven: true)
        #expect(analysis.effort == "high")
        #expect(fake.lastRequest?.effort == "high")
    }
}

extension Array where Element == String {
    func windowContains(_ pair: [String]) -> Bool {
        guard pair.count <= count else { return false }
        return (0...(count - pair.count)).contains { Array(self[$0..<($0 + pair.count)]) == pair }
    }
}
