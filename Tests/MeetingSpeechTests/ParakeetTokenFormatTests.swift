import FluidAudio
import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingSpeech

@Suite("Parakeet: marcas de palabra y progreso")
struct ParakeetTokenFormatTests {
    @Test func fluidAudioTimingsUseSpacesAsWordMarkers() {
        let timings = [TokenTiming(token: " presu", tokenId: 1, startTime: 2.4, endTime: 2.7, confidence: 1),
                       TokenTiming(token: "puesto", tokenId: 2, startTime: 2.7, endTime: 3.0, confidence: 1),
                       TokenTiming(token: ".", tokenId: 3, startTime: 3.0, endTime: 3.08, confidence: 1),
                       TokenTiming(token: " Dale", tokenId: 4, startTime: 7.2, endTime: 7.5, confidence: 1)]
        let tokens = ParakeetUltraProvider.tokensOnFileTimeline(timings, compaction: nil)
        #expect(tokens[2].start == 3.0 && tokens[2].end == 3.08)
        let words = WordGrouping.words(from: tokens.map { ($0.piece, $0.start, $0.end, $0.confidence) })
        #expect(words.map(\.word) == ["presupuesto.", "Dale"])
        #expect(words[0].end == 3.08)
    }

    @Test func progressIsOnlyRequestedBeyondOneModelWindow() {
        let window = Int64(ASRConstants.maxModelSamples)
        #expect(!ParakeetUltraProvider.emitsProgress(frames: window, sampleRate: 16_000))
        #expect(!ParakeetUltraProvider.emitsProgress(frames: window + 1_000, sampleRate: 16_000))
        #expect(ParakeetUltraProvider.emitsProgress(frames: window + 16_000, sampleRate: 16_000))
        #expect(!ParakeetUltraProvider.emitsProgress(frames: window * 3, sampleRate: 48_000))
        #expect(ParakeetUltraProvider.emitsProgress(frames: (window + 16_000) * 3, sampleRate: 48_000))
        #expect(!ParakeetUltraProvider.emitsProgress(frames: 0, sampleRate: 0))
    }
}
