import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingSpeech

@Suite("Contexto de respuestas cortas")
struct ShortUtteranceContextTests {
    private let url = URL(fileURLWithPath: "/fixture/remote.wav")

    private func token(_ start: Double, _ end: Double, confidence: Float = 0.9) -> ASRToken {
        ASRToken(piece: "▁voz", tokenId: 1, start: start, end: end, confidence: confidence)
    }

    @Test func remoteContextUsesMeetingOffsetsAndExcludesOverlappingSpeech() throws {
        let context = ASRContextTrack(fileURL: url,
                                      tokens: [token(0, 4), token(4, 8), token(8, 12)],
                                      timelineOffsetSeconds: 40)
        let spans = ShortUtteranceContext.remoteSpans(start: 48, end: 50, contextTracks: [context])
        let span = try #require(spans.first)
        #expect(spans.count == 1)
        #expect(span.fileURL == url && span.start == 0 && span.end == 8)
    }

    @Test func prefersPrecedingSpeechAndCapsAudioBudget() throws {
        let context = ASRContextTrack(fileURL: url,
                                      tokens: [token(1, 12), token(20, 25)], timelineOffsetSeconds: 0)
        let spans = ShortUtteranceContext.remoteSpans(start: 15, end: 17, contextTracks: [context])
        let span = try #require(spans.first)
        #expect(spans.count == 1)
        #expect(span.start == 4 && span.end == 12)
    }

    @Test func skipsDistantEmptyOrSimultaneousContext() {
        for tokens in [[], [token(0, 2)], [token(50, 52)], [token(100, 102)]] {
            let context = ASRContextTrack(fileURL: url, tokens: tokens, timelineOffsetSeconds: 0)
            #expect(ShortUtteranceContext.remoteSpans(start: 50, end: 52, contextTracks: [context]).isEmpty)
        }
    }

    @Test func lowConfidenceExpandedReplyIsRetriedButLongSpeechIsNot() {
        let reply = (0..<11).map { token(Double($0) * 0.4, Double($0 + 1) * 0.4, confidence: 0.6) }
        #expect(ShortUtteranceContext.needsContext(reply.indices, in: reply))
        let confident = reply.map { var t = $0; t.confidence = 0.9; return t }
        #expect(!ShortUtteranceContext.needsContext(confident.indices, in: confident))
        let long = (0..<20).map { token(Double($0), Double($0 + 1), confidence: 0.5) }
        #expect(!ShortUtteranceContext.needsContext(long.indices, in: long))
    }
}

/// Opt-in measurement on synthetic paired-track replies; never reads real meetings.
@Suite("Experimento: contexto remoto",
       .enabled(if: ProcessInfo.processInfo.environment["MI_CROSS_TRACK_DATA"] != nil), .serialized)
struct CrossTrackContextExperiment {
    @Test func measure() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MI_CROSS_TRACK_DATA"] ?? "/nonexistent")
        let provider = ParakeetUltraProvider()
        let remoteURL = IntegrationEnvironment.fixtures.appendingPathComponent("es_single_speaker.wav")
        let remote = try await provider.transcribe(fileURL: remoteURL, languageHint: "es-CO") { _ in }
        let context = ASRContextTrack(fileURL: remoteURL, tokens: remote.tokens, timelineOffsetSeconds: 0)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines: [String] = []
        for url in files {
            let reference = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
            let base = try await provider.transcribe(fileURL: url, languageHint: "es-CO") { _ in }
            let result = try await provider.transcribe(fileURL: url, languageHint: "es-CO",
                                                       timelineOffsetSeconds: remote.audioDurationSeconds + 1,
                                                       contextTracks: [context]) { _ in }
            lines.append("\(url.lastPathComponent) | \(reference.trimmingCharacters(in: .whitespacesAndNewlines)) | base: \(base.text) | context: \(result.text) | WER: \(Metrics.wordErrorRate(reference: reference, hypothesis: base.text).wer) → \(Metrics.wordErrorRate(reference: reference, hypothesis: result.text).wer)")
            #expect(result.words.allSatisfy { $0.start >= 0 && $0.end <= result.audioDurationSeconds + 0.3 })
        }
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
