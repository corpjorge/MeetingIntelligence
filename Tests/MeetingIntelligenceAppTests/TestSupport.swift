import Foundation
@testable import MeetingCore
import Testing
@testable import MeetingIntelligenceApp

/// Private UserDefaults suite so tests never touch the user's preferences.
struct IsolatedDefaults {
    let name = "dev.meetingintelligence.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: name))
    }

    func remove() { defaults.removePersistentDomain(forName: name) }
}

/// Canned provider that counts calls; answers analysis or chat requests by their expected keys.
nonisolated final class CountingProvider: AIProvider, @unchecked Sendable {
    let kind: AIProviderKind
    private let lock = NSLock()
    private var count = 0
    private var request: AIRequest?
    private let models: [String]
    private let catalogLoaded: Bool
    var calls: Int { lock.withLock { count } }
    var lastRequest: AIRequest? { lock.withLock { request } }

    init(kind: AIProviderKind, models: [String] = [], catalogLoaded: Bool = false) {
        self.kind = kind; self.models = models; self.catalogLoaded = catalogLoaded
    }

    func detect(configuration: AIProviderConfiguration) async -> ProviderStatus {
        var status = ProviderStatus(kind: kind, installed: true, version: "fake-1", authenticated: true, models: models)
        status.modelCatalogLoaded = catalogLoaded
        return status
    }

    func complete(_ request: AIRequest, configuration: AIProviderConfiguration) async throws -> AIResponse {
        lock.withLock { count += 1; self.request = request }
        let answer = request.requiredKeys.contains("answer")
            ? #"{"answer":"Se validó el indicador [C1].","citations":["C1"],"found":true}"#
            : #"{"executiveSummary":"s","technicalSummary":"t","items":[]}"#
        return AIResponse(json: Data(answer.utf8), rawOutput: answer, model: "fake-model", durationSeconds: 0.01)
    }
}

enum AppFixture {
    static func meeting(_ db: AppDatabase) throws -> Meeting {
        let meeting = Meeting(title: "FIXTURE · Comité", origin: .imported, captureScope: .importedFile, status: .ready)
        let track = AudioTrack(meetingId: meeting.id, source: .imported, relativePath: "Recordings/\(meeting.id)/imported.wav",
                               sampleRate: 16_000, channelCount: 1, durationSeconds: 60)
        try db.insert(meeting: meeting, tracks: [track])
        let transcript = Transcript(meetingId: meeting.id, trackId: track.id, engine: "fixture", modelIdentifier: "fixture",
                                    language: "es-CO", isFinal: true, audioDurationSeconds: 60, processingSeconds: 1,
                                    meanConfidence: 0.9)
        let segment = TranscriptSegment(transcriptId: transcript.id, meetingId: meeting.id, trackId: track.id,
                                        source: .imported, orderIndex: 0, startTime: 10, endTime: 14,
                                        asrText: "Validamos el indicador de ingresos con el equipo")
        try db.replaceTranscript(transcript, segments: [segment])
        return meeting
    }

    static func temporaryPaths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-app-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AppPaths(root: root)
    }
}

/// Polls a main-actor condition (async work in the controllers runs on the main actor).
func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("La condición no se cumplió a tiempo")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
