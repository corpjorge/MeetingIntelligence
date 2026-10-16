import Foundation

/// Carries manual speaker identities across re-processing.
///
/// Re-processing replaces a source's diarization clusters, so manual
/// assignments made on the previous clusters would be lost. Each new cluster
/// inherits a previous manual identity only when the evidence is unambiguous:
///
/// * at least `minimumShare` of the new cluster's speech falls inside the
///   speech of previous speakers manually assigned to that same participant, and
/// * that participant strictly beats every other participant's share.
///
/// Several new clusters may inherit the same identity (the diarizer split one
/// person in two). Anything less clear stays "Participante desconocido".
public struct ManualIdentityRemapper: Sendable {
    public struct Span: Sendable, Hashable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
        var duration: Double { max(0, end - start) }
    }

    /// A previous speaker whose identity was set manually.
    public struct PreviousIdentity: Sendable, Hashable {
        public var participantId: String
        public var spans: [Span]
        public init(participantId: String, spans: [Span]) {
            self.participantId = participantId
            self.spans = spans
        }
    }

    public struct Match: Sendable, Hashable {
        public var participantId: String
        /// Fraction of the new cluster's speech covered by that participant's previous spans.
        public var share: Double
    }

    public var minimumShare: Double

    public init(minimumShare: Double = 0.5) {
        self.minimumShare = minimumShare
    }

    /// - Parameter newClusters: new speaker id → its speech spans.
    /// - Returns: new speaker id → inherited identity (only unambiguous ones).
    public func remap(previous: [PreviousIdentity], newClusters: [String: [Span]]) -> [String: Match] {
        guard !previous.isEmpty else { return [:] }
        let byParticipant = Dictionary(grouping: previous, by: \.participantId)
            .mapValues { $0.flatMap(\.spans) }
        var result: [String: Match] = [:]
        for (clusterId, spans) in newClusters {
            let total = spans.reduce(0) { $0 + $1.duration }
            guard total > 0 else { continue }
            let shares = byParticipant.map { pid, old in (pid, Self.overlap(spans, old) / total) }
                .sorted { $0.1 > $1.1 }
            guard let best = shares.first, best.1 >= minimumShare else { continue }
            if shares.count > 1, shares[1].1 >= best.1 { continue } // tie → ambiguous
            result[clusterId] = Match(participantId: best.0, share: best.1)
        }
        return result
    }

    /// Total intersection between two sets of spans (each set may overlap itself;
    /// the second set is merged first so shared time is never double-counted).
    static func overlap(_ a: [Span], _ b: [Span]) -> Double {
        let merged = merge(b)
        var total = 0.0
        for span in merge(a) {
            for other in merged where other.end > span.start && other.start < span.end {
                total += min(span.end, other.end) - max(span.start, other.start)
            }
        }
        return total
    }

    static func merge(_ spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans.sorted(by: { $0.start < $1.start }) where span.duration > 0 {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1].end = max(last.end, span.end)
            } else {
                result.append(span)
            }
        }
        return result
    }
}
