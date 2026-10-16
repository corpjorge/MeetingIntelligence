public import MeetingCore

/// Assigns diarized speakers to ASR words and re-segments at speaker changes.
///
/// * Each word takes the turn with the largest time overlap; words falling in
///   no turn snap to the nearest turn within `snapSeconds`, otherwise remain
///   unattributed (never guessed).
/// * Segments are split where the speaker changes. Isolated one-word flips
///   between the same speaker are smoothed (diarization frame jitter).
/// * A segment overlapped by a second speaker for ≥ `overlapRatio` of its
///   duration is marked `uncertain` — overlapping speech is kept, not dropped.
/// * Original word timestamps are preserved untouched.
public struct SpeakerAlignment: Sendable {
    public var snapSeconds: Double = 0.4
    public var overlapRatio: Double = 0.3

    public init() {}

    public struct AlignedSegment: Sendable, Equatable {
        public var words: [WordTiming]
        public var clusterKey: String?
        /// Fraction of the segment's word time agreeing with `clusterKey`.
        public var agreement: Double
        public var overlapsOtherSpeaker: Bool

        public var text: String { words.map(\.word).joined(separator: " ") }
        public var start: Double { words.first?.start ?? 0 }
        public var end: Double { words.last?.end ?? 0 }
        public var meanConfidence: Double? {
            let v = words.compactMap(\.confidence)
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
    }

    public func speaker(for word: WordTiming, turns: [SpeakerTurn]) -> String? {
        var best: (key: String, overlap: Double)?
        for turn in turns where turn.end > word.start && turn.start < word.end {
            let overlap = min(turn.end, word.end) - max(turn.start, word.start)
            if overlap > (best?.overlap ?? 0) { best = (turn.clusterKey, overlap) }
        }
        if let best { return best.key }
        let mid = (word.start + word.end) / 2
        let nearest = turns.min { distance(mid, $0) < distance(mid, $1) }
        if let nearest, distance(mid, nearest) <= snapSeconds { return nearest.clusterKey }
        return nil
    }

    private func distance(_ t: Double, _ turn: SpeakerTurn) -> Double {
        t < turn.start ? turn.start - t : (t > turn.end ? t - turn.end : 0)
    }

    /// - Parameter drafts: pause/punctuation-based segments from `SegmentBuilder`.
    public func align(_ drafts: [SegmentBuilder.Draft], turns: [SpeakerTurn]) -> [AlignedSegment] {
        var output: [AlignedSegment] = []
        for draft in drafts {
            var labels = draft.words.map { speaker(for: $0, turns: turns) }
            // Smooth single-word flips: A B A → A A A.
            if labels.count >= 3 {
                for i in 1..<(labels.count - 1) where labels[i - 1] == labels[i + 1] && labels[i] != labels[i - 1] {
                    labels[i] = labels[i - 1]
                }
            }
            var runStart = 0
            for i in 1...draft.words.count {
                if i == draft.words.count || labels[i] != labels[runStart] {
                    let words = Array(draft.words[runStart..<i])
                    output.append(makeSegment(words: words, key: labels[runStart], turns: turns))
                    runStart = i
                }
            }
        }
        return output
    }

    private func makeSegment(words: [WordTiming], key: String?, turns: [SpeakerTurn]) -> AlignedSegment {
        let start = words.first?.start ?? 0, end = words.last?.end ?? 0
        let span = max(0.001, end - start)
        var agreeing = 0.0, total = 0.0
        for w in words {
            let d = max(0.01, w.end - w.start)
            total += d
            if speaker(for: w, turns: turns) == key { agreeing += d }
        }
        var otherOverlap = 0.0
        if let key {
            for turn in turns where turn.clusterKey != key && turn.end > start && turn.start < end {
                otherOverlap += min(turn.end, end) - max(turn.start, start)
            }
        }
        return AlignedSegment(words: words, clusterKey: key,
                              agreement: total > 0 ? agreeing / total : 0,
                              overlapsOtherSpeaker: otherOverlap / span >= overlapRatio)
    }
}

/// Flags microphone segments that are acoustic echo of the remote track
/// (remote voices played on speakers and picked up by the mic).
///
/// A mic segment is a probable echo when most of its words also occur in
/// remote speech within ±`windowSeconds`. Flagged segments are kept and
/// marked, never deleted.
public struct EchoDetector: Sendable {
    public var windowSeconds: Double = 2.0
    public var minimumOverlap: Double = 0.6
    public var minimumWords = 3

    public init() {}

    public func isProbableEcho(micText: String, micStart: Double, micEnd: Double,
                               remoteWords: [WordTiming]) -> Bool {
        let micTokens = TextNormalization.tokens(micText)
        guard micTokens.count >= minimumWords else { return false }
        let nearby = remoteWords.filter { $0.end >= micStart - windowSeconds && $0.start <= micEnd + windowSeconds }
        guard !nearby.isEmpty else { return false }
        var remoteCounts: [String: Int] = [:]
        for w in nearby { for t in TextNormalization.tokens(w.word) { remoteCounts[t, default: 0] += 1 } }
        var matched = 0
        for t in micTokens where (remoteCounts[t] ?? 0) > 0 {
            matched += 1
            remoteCounts[t]! -= 1
        }
        return Double(matched) / Double(micTokens.count) >= minimumOverlap
    }
}
