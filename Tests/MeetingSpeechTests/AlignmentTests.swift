import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingSpeech

private func w(_ word: String, _ start: Double, _ end: Double) -> WordTiming {
    WordTiming(word: word, start: start, end: end, confidence: 0.9)
}

@Suite("Segmentación y alineación")
struct AlignmentTests {
    @Test func tokensGroupIntoWordsWithConfidence() {
        let words = WordGrouping.words(from: [
            ("▁Hola", 0.0, 0.2, 0.9), (",", 0.2, 0.25, 0.8),
            ("▁end", 0.5, 0.6, 1.0), ("point", 0.6, 0.8, 0.6),
        ])
        #expect(words.map(\.word) == ["Hola,", "endpoint"])
        #expect(words[1].start == 0.5 && words[1].end == 0.8)
        #expect(abs((words[1].confidence ?? 0) - 0.8) < 1e-6)
    }

    @Test func segmentsSplitOnPausesAndSentences() {
        let words = [w("Hola.", 0, 0.5), w("Sigo", 0.6, 0.9), w("hablando", 0.9, 3.2), w("aquí.", 3.2, 3.5),
                     w("Nuevo", 5.0, 5.4), w("turno", 5.4, 5.8)]
        let drafts = SegmentBuilder().segments(from: words)
        // "Hola." is too short to end a sentence segment; the 1.5 s pause splits.
        #expect(drafts.map(\.text) == ["Hola. Sigo hablando aquí.", "Nuevo turno"])
        #expect(drafts[1].start == 5.0)
    }

    @Test func alignmentSplitsAtSpeakerChangeAndKeepsTimestamps() {
        let words = [w("a", 0, 0.4), w("b", 0.5, 0.9), w("c", 1.0, 1.4), w("d", 1.5, 1.9)]
        let turns = [SpeakerTurn(clusterKey: "S1", start: 0, end: 0.95, quality: 1),
                     SpeakerTurn(clusterKey: "S2", start: 0.95, end: 2, quality: 1)]
        let aligned = SpeakerAlignment().align([SegmentBuilder.Draft(words: words)], turns: turns)
        #expect(aligned.map(\.clusterKey) == ["S1", "S2"])
        #expect(aligned.map(\.text) == ["a b", "c d"])
        #expect(aligned[1].start == 1.0 && aligned[1].end == 1.9)
    }

    @Test func singleWordFlipIsSmoothed() {
        let words = [w("uno", 0, 0.3), w("dos", 0.3, 0.6), w("tres", 0.6, 0.9)]
        let turns = [SpeakerTurn(clusterKey: "S1", start: 0, end: 0.3, quality: 1),
                     SpeakerTurn(clusterKey: "S2", start: 0.3, end: 0.6, quality: 1),
                     SpeakerTurn(clusterKey: "S1", start: 0.6, end: 1, quality: 1)]
        let aligned = SpeakerAlignment().align([SegmentBuilder.Draft(words: words)], turns: turns)
        #expect(aligned.count == 1)
        #expect(aligned[0].clusterKey == "S1")
    }

    @Test func overlapIsMarkedNotDropped() {
        let words = [w("hablamos", 0, 1), w("juntos", 1, 2)]
        let turns = [SpeakerTurn(clusterKey: "S1", start: 0, end: 2, quality: 1),
                     SpeakerTurn(clusterKey: "S2", start: 0.5, end: 2, quality: 1)]
        let aligned = SpeakerAlignment().align([SegmentBuilder.Draft(words: words)], turns: turns)
        #expect(aligned.flatMap(\.words).count == 2)
        #expect(aligned.contains { $0.overlapsOtherSpeaker })
    }

    @Test func wordsOutsideAnyTurnStayUnattributed() {
        let aligned = SpeakerAlignment().align(
            [SegmentBuilder.Draft(words: [w("lejos", 10, 10.5)])],
            turns: [SpeakerTurn(clusterKey: "S1", start: 0, end: 1, quality: 1)])
        #expect(aligned[0].clusterKey == nil)
    }

    @Test func echoDetection() {
        let remote = [w("debemos", 10, 10.4), w("validar", 10.4, 10.9), w("ese", 10.9, 11.1), w("campo", 11.1, 11.5)]
        let detector = EchoDetector()
        #expect(detector.isProbableEcho(micText: "debemos validar ese campo", micStart: 10.2, micEnd: 11.8, remoteWords: remote))
        #expect(!detector.isProbableEcho(micText: "yo me encargo del despliegue", micStart: 10.2, micEnd: 11.8, remoteWords: remote))
        #expect(!detector.isProbableEcho(micText: "debemos validar ese campo", micStart: 40, micEnd: 42, remoteWords: remote))
    }
}

@Suite("Reconocimiento de hablantes")
struct SpeakerMatcherTests {
    /// Synthetic embeddings: one base direction per person plus small noise.
    private func voice(_ id: String, base: Int, samples: Int, noise: Float = 0.08, seed: UInt64) -> EnrolledVoice {
        var rng = SeededGenerator(seed: seed)
        return EnrolledVoice(participantId: id, samples: (0..<samples).map { _ in embedding(base: base, noise: noise, rng: &rng) })
    }

    private func embedding(base: Int, noise: Float, rng: inout SeededGenerator) -> [Float] {
        var v = (0..<32).map { _ in Float.random(in: -noise...noise, using: &rng) }
        v[base] += 1
        return EmbeddingMath.normalized(v)
    }

    @Test func uncalibratedNeverAutoAccepts() {
        let voices = [voice("katty", base: 0, samples: 1, seed: 1)]
        var rng = SeededGenerator(seed: 9)
        let decision = SpeakerMatcher(calibration: SpeakerCalibration.derive(from: voices))
            .decide(query: embedding(base: 0, noise: 0.08, rng: &rng), speechSeconds: 30, voices: voices)
        #expect(decision.outcome == .suggested)
    }

    @Test func calibratedAcceptsGenuineRejectsStranger() throws {
        let voices = [voice("katty", base: 0, samples: 3, seed: 1), voice("carlos", base: 1, samples: 3, seed: 2),
                      voice("jorge", base: 2, samples: 3, seed: 3)]
        let calibration = try #require(SpeakerCalibration.derive(from: voices))
        #expect(!calibration.hasOverlap)
        let matcher = SpeakerMatcher(calibration: calibration)
        var rng = SeededGenerator(seed: 42)

        let katty = matcher.decide(query: embedding(base: 0, noise: 0.08, rng: &rng), speechSeconds: 20, voices: voices)
        #expect(katty.outcome == .accepted)
        #expect(katty.best?.participantId == "katty")

        let stranger = matcher.decide(query: embedding(base: 7, noise: 0.08, rng: &rng), speechSeconds: 20, voices: voices)
        #expect(stranger.outcome == .unknown)

        let short = matcher.decide(query: embedding(base: 1, noise: 0.08, rng: &rng), speechSeconds: 1, voices: voices)
        #expect(short.outcome == .suggested) // too little speech for automatic identity
    }

    @Test func ambiguousBetweenSimilarVoicesIsNotAccepted() throws {
        let voices = [voice("a", base: 0, samples: 3, seed: 1), voice("b", base: 1, samples: 3, seed: 2)]
        let calibration = try #require(SpeakerCalibration.derive(from: voices))
        // Query halfway between both voices.
        let query = EmbeddingMath.normalized(zip(voices[0].centroid!, voices[1].centroid!).map { $0 + $1 })
        let decision = SpeakerMatcher(calibration: calibration).decide(query: query, speechSeconds: 30, voices: voices)
        #expect(decision.outcome != .accepted)
    }
}

/// Deterministic RNG so biometric tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Métricas")
struct MetricsTests {
    @Test func werCountsEditsOnNormalizedText() {
        let r = Metrics.wordErrorRate(reference: "El campo de ingresos validados.", hypothesis: "el campo de ingreso validados extra")
        #expect(r.substitutions == 1 && r.insertions == 1 && r.deletions == 0)
        #expect(abs(r.wer - 0.4) < 1e-9)
        #expect(Metrics.wordErrorRate(reference: "", hypothesis: "").wer == 0)
    }

    @Test func derWithLabelPermutation() {
        let reference = [Metrics.SpeakerTurn(speaker: "A", start: 0, end: 5), .init(speaker: "B", start: 5, end: 10)]
        let hypothesis = [Metrics.SpeakerTurn(speaker: "S2", start: 0, end: 5), .init(speaker: "S1", start: 5, end: 9)]
        let der = Metrics.diarizationErrorRate(reference: reference, hypothesis: hypothesis)
        #expect(der.mapping == ["S2": "A", "S1": "B"])
        #expect(abs(der.der - 0.1) < 0.01) // 1 s missed out of 10 s
    }
}

@Suite("Tokens partidos por la compactación")
struct SplitWordTests {
    private func token(_ piece: String, _ start: Double, _ end: Double) -> ASRToken {
        ASRToken(piece: piece, tokenId: 0, start: start, end: end, confidence: 1)
    }

    @Test func leadingPieceMovesNextToItsContinuation() {
        let tokens = [token("▁aviso", 335.4, 336.1), token(".", 336.1, 336.16), token("▁¿", 336.16, 336.3),
                      token("Qu", 353.76, 353.9), token("ién", 353.9, 354.0), token("▁sigue", 354.0, 354.5)]
        let fixed = ParakeetUltraProvider.reattachSplitWords(tokens)
        #expect(fixed[2].start >= 353.5 && fixed[2].end == 353.76)
        #expect(fixed[0] == tokens[0] && fixed[3] == tokens[3])
        let words = WordGrouping.words(from: fixed.map { ($0.piece, $0.start, $0.end, $0.confidence) })
        #expect(words.map(\.word) == ["aviso.", "¿Quién", "sigue"])
        #expect(words[1].start > 353)
        // A closing mark emitted after the gap goes back to its word.
        let late = ParakeetUltraProvider.reattachSplitWords([token("▁Listo", 10, 10.4), token(".", 30, 30.1),
                                                             token("▁Dale", 30.1, 30.5)])
        #expect(late[1].start == 10.4 && late[2] == token("▁Dale", 30.1, 30.5))
        // Pieces with letters are never moved, and a new word after a pause is left alone.
        #expect(ParakeetUltraProvider.reattachSplitWords([token("▁Qu", 0, 0.2), token("ién", 5, 5.2)])
                == [token("▁Qu", 0, 0.2), token("ién", 5, 5.2)])
        #expect(ParakeetUltraProvider.reattachSplitWords([token("▁hola", 0, 1), token("▁adiós", 5, 6)])
                == [token("▁hola", 0, 1), token("▁adiós", 5, 6)])
    }
}
