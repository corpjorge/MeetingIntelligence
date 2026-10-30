import FluidAudio
import Foundation
import MeetingCore

/// Groups SentencePiece token timings into words, keeping per-word confidence.
/// Mirrors FluidAudio's `buildWordTimings` boundary rule (`▁` / leading space)
/// but also averages token confidences, which `buildWordTimings` drops.
enum WordGrouping {
    static func words(from tokens: [TokenTiming]) -> [MeetingCore.WordTiming] {
        words(from: tokens.map { ($0.token, $0.startTime, $0.endTime, $0.confidence) })
    }

    static func startsWord(_ piece: String) -> Bool {
        piece.hasPrefix("▁") || piece.hasPrefix(" ")
    }

    static func words(from tokens: [(piece: String, start: Double, end: Double, confidence: Float)]) -> [MeetingCore.WordTiming] {
        var words: [MeetingCore.WordTiming] = []
        var text = ""
        var start = 0.0, end = 0.0
        var confidences: [Float] = []

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let mean = confidences.isEmpty ? nil : Double(confidences.reduce(0, +) / Float(confidences.count))
            words.append(MeetingCore.WordTiming(word: trimmed, start: start, end: end, confidence: mean))
        }

        for token in tokens {
            let piece = token.piece
            if piece.isEmpty || piece == "<blank>" || piece == "<pad>" { continue }
            if startsWord(piece) || text.isEmpty {
                flush()
                text = String(piece.drop(while: { $0 == "▁" || $0 == " " }))
                start = token.start
                end = token.end
                confidences = [token.confidence]
            } else {
                text += piece
                end = max(end, token.end)
                confidences.append(token.confidence)
            }
        }
        flush()
        return words
    }
}
