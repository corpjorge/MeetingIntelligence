public import MeetingCore

/// Splits a word stream into readable transcript segments (utterances).
///
/// Boundaries, in priority order:
/// 1. a silence gap ≥ `pauseSplitSeconds` between words,
/// 2. sentence-final punctuation once the segment is ≥ `minSentenceSeconds`,
/// 3. a hard cap (`maxSegmentSeconds`) at the nearest word.
///
/// Timestamps come only from the ASR word timings; nothing is interpolated.
public struct SegmentBuilder: Sendable {
    public var pauseSplitSeconds: Double = 0.9
    public var minSentenceSeconds: Double = 2.5
    public var maxSegmentSeconds: Double = 22

    public init() {}

    public struct Draft: Sendable, Equatable {
        public var words: [WordTiming]
        public var text: String { words.map(\.word).joined(separator: " ") }
        public var start: Double { words.first?.start ?? 0 }
        public var end: Double { words.last?.end ?? 0 }
        public var meanConfidence: Double? {
            let values = words.compactMap(\.confidence)
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
    }

    public func segments(from words: [WordTiming]) -> [Draft] {
        var drafts: [Draft] = []
        var current: [WordTiming] = []
        for word in words {
            if let last = current.last {
                let gap = word.start - last.end
                let length = last.end - (current.first?.start ?? last.end)
                let sentenceEnded = Self.endsSentence(last.word) && length >= minSentenceSeconds
                if gap >= pauseSplitSeconds || sentenceEnded || (word.end - current[0].start) > maxSegmentSeconds {
                    drafts.append(Draft(words: current))
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { drafts.append(Draft(words: current)) }
        return drafts
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return last == "." || last == "?" || last == "!" || last == "…"
    }
}
