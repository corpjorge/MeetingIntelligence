import Foundation

/// Reproducible quality metrics used by tests and the CLI `evaluate` command.
public enum Metrics {
    public struct WERResult: Sendable, Equatable {
        public var substitutions: Int
        public var deletions: Int
        public var insertions: Int
        public var referenceWords: Int
        public var wer: Double {
            referenceWords == 0 ? (insertions == 0 ? 0 : 1) : Double(substitutions + deletions + insertions) / Double(referenceWords)
        }
    }

    /// Word error rate on normalized text (case, accents and punctuation ignored).
    public static func wordErrorRate(reference: String, hypothesis: String) -> WERResult {
        let ref = TextNormalization.tokens(reference)
        let hyp = TextNormalization.tokens(hypothesis)
        let n = ref.count, m = hyp.count
        // dp[i][j] = (cost, subs, dels, ins)
        var prev = (0...m).map { (cost: $0, s: 0, d: 0, i: $0) }
        for i in 1...max(1, n) where n > 0 {
            var cur = [(cost: Int, s: Int, d: Int, i: Int)](repeating: (0, 0, 0, 0), count: m + 1)
            cur[0] = (i, 0, i, 0)
            for j in stride(from: 1, through: m, by: 1) {
                if ref[i - 1] == hyp[j - 1] {
                    cur[j] = prev[j - 1]
                } else {
                    let sub = prev[j - 1], del = prev[j], ins = cur[j - 1]
                    if sub.cost <= del.cost && sub.cost <= ins.cost {
                        cur[j] = (sub.cost + 1, sub.s + 1, sub.d, sub.i)
                    } else if del.cost <= ins.cost {
                        cur[j] = (del.cost + 1, del.s, del.d + 1, del.i)
                    } else {
                        cur[j] = (ins.cost + 1, ins.s, ins.d, ins.i + 1)
                    }
                }
            }
            prev = cur
        }
        let last = prev[m]
        return n == 0 ? WERResult(substitutions: 0, deletions: 0, insertions: m, referenceWords: 0)
                      : WERResult(substitutions: last.s, deletions: last.d, insertions: last.i, referenceWords: n)
    }

    public struct SpeakerTurn: Sendable, Hashable {
        public var speaker: String
        public var start: Double
        public var end: Double
        public init(speaker: String, start: Double, end: Double) {
            self.speaker = speaker
            self.start = start
            self.end = end
        }
    }

    public struct DERResult: Sendable {
        public var missed: Double
        public var falseAlarm: Double
        public var confusion: Double
        public var totalReference: Double
        public var der: Double { totalReference > 0 ? (missed + falseAlarm + confusion) / totalReference : 0 }
        /// Hypothesis label → reference label chosen by the optimal mapping.
        public var mapping: [String: String]
    }

    /// Frame-based diarization error rate (10 ms frames, no collar) with an
    /// optimal one-to-one speaker mapping (exhaustive for ≤ 8 speakers, greedy above).
    public static func diarizationErrorRate(reference: [SpeakerTurn], hypothesis: [SpeakerTurn],
                                            frame: Double = 0.01) -> DERResult {
        let end = max(reference.map(\.end).max() ?? 0, hypothesis.map(\.end).max() ?? 0)
        let frames = Int((end / frame).rounded(.up))
        func labels(_ turns: [SpeakerTurn]) -> [Set<String>] {
            var out = [Set<String>](repeating: [], count: frames)
            for t in turns {
                let a = max(0, Int(t.start / frame)), b = min(frames, Int((t.end / frame).rounded(.up)))
                if a < b { for f in a..<b { out[f].insert(t.speaker) } }
            }
            return out
        }
        let ref = labels(reference), hyp = labels(hypothesis)
        let refSpeakers = Array(Set(reference.map(\.speaker))).sorted()
        let hypSpeakers = Array(Set(hypothesis.map(\.speaker))).sorted()

        // Co-occurrence matrix (frames where both labels are active).
        var overlap = [String: [String: Int]]()
        for f in 0..<frames where !ref[f].isEmpty && !hyp[f].isEmpty {
            for h in hyp[f] { for r in ref[f] { overlap[h, default: [:]][r, default: 0] += 1 } }
        }
        let mapping = bestMapping(hyp: hypSpeakers, ref: refSpeakers, overlap: overlap)

        var missed = 0, falseAlarm = 0, confusion = 0, total = 0
        for f in 0..<frames {
            let r = ref[f], h = hyp[f]
            total += r.count
            let mapped = Set(h.compactMap { mapping[$0] })
            let correct = r.intersection(mapped).count
            missed += max(0, r.count - h.count)
            falseAlarm += max(0, h.count - r.count)
            confusion += min(r.count, h.count) - correct
        }
        return DERResult(missed: Double(missed) * frame, falseAlarm: Double(falseAlarm) * frame,
                         confusion: Double(confusion) * frame, totalReference: Double(total) * frame,
                         mapping: mapping)
    }

    private static func bestMapping(hyp: [String], ref: [String], overlap: [String: [String: Int]]) -> [String: String] {
        func score(_ m: [String: String]) -> Int { m.reduce(0) { $0 + (overlap[$1.key]?[$1.value] ?? 0) } }
        if hyp.count <= 8 && ref.count <= 8 {
            var best: [String: String] = [:]
            var bestScore = -1
            func search(_ i: Int, _ used: Set<String>, _ current: [String: String]) {
                if i == hyp.count {
                    let s = score(current)
                    if s > bestScore { bestScore = s; best = current }
                    return
                }
                search(i + 1, used, current) // leave unmapped
                for r in ref where !used.contains(r) {
                    var next = current
                    next[hyp[i]] = r
                    search(i + 1, used.union([r]), next)
                }
            }
            search(0, [], [:])
            return best
        }
        var mapping: [String: String] = [:]
        var used = Set<String>()
        let pairs = overlap.flatMap { h, refs in refs.map { (h, $0.key, $0.value) } }.sorted { $0.2 > $1.2 }
        for (h, r, _) in pairs where mapping[h] == nil && !used.contains(r) {
            mapping[h] = r
            used.insert(r)
        }
        return mapping
    }
}
