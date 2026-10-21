import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingSemantic

/// Real multilingual-e5-small on synthetic Spanish text. Runs only when the model is
/// already downloaded (never downloads in tests): `MI_E5_MODELS` or the default library.
enum E5Environment {
    static let engine = SemanticSearchEngine(modelsDirectory: ProcessInfo.processInfo.environment["MI_E5_MODELS"]
        .map { URL(fileURLWithPath: $0) } ?? AppPaths.resolveDefault().modelsDirectory)
}

@Suite("Integración: e5-small", .enabled(if: E5Environment.engine.isModelCached()))
struct SemanticEngineIntegrationTests {
    var engine: SemanticSearchEngine { E5Environment.engine }

    @Test func paraphraseIsFoundWhereKeywordsFail() async throws {
        let db = try AppDatabase.inMemory()
        let meeting = Meeting(title: "FIXTURE · semántica", origin: .imported, captureScope: .importedFile, status: .ready)
        let track = AudioTrack(meetingId: meeting.id, source: .imported, relativePath: "x.wav", sampleRate: 16_000,
                               channelCount: 1, durationSeconds: 30)
        try db.insert(meeting: meeting, tracks: [track])
        let transcript = Transcript(meetingId: meeting.id, trackId: track.id, engine: "fixture", modelIdentifier: "fixture",
                                    language: "es-CO", isFinal: true, audioDurationSeconds: 30, processingSeconds: 1,
                                    meanConfidence: 0.9)
        let texts = ["Se me cayó el internet y no podía escuchar nada", "El cliente se quejó porque la factura llegó duplicada",
                     "Mi perro se llama Toby y le gusta correr"]
        try db.replaceTranscript(transcript, segments: texts.enumerated().map { i, text in
            TranscriptSegment(transcriptId: transcript.id, meetingId: meeting.id, trackId: track.id, source: .imported,
                              orderIndex: i, startTime: Double(i * 5), endTime: Double(i * 5 + 4), asrText: text)
        })

        #expect(try await engine.indexPending(database: db) == 3)
        let search = SearchService(reader: db.reader)
        // No shared word with the answer: keyword search finds nothing, e5 ranks it first.
        #expect(try search.search("nos cobraron dos veces").isEmpty)
        let hits = try search.semanticSearch(try await engine.embedQuery("nos cobraron dos veces"))
        #expect(hits.first?.text == texts[1])
        #expect(try search.semanticSearch(try await engine.embedQuery("¿Cuál es la receta del ajiaco?")).isEmpty)
    }
}
