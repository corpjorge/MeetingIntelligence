import Foundation

/// Vector helpers for L2-normalized speaker embeddings.
public enum EmbeddingMath {
    public static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return -1 }
        return Double(dot / (sqrt(na) * sqrt(nb)))
    }

    public static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == first.count {
            let n = normalized(v)
            for i in 0..<n.count { sum[i] += n[i] }
        }
        return normalized(sum)
    }
}

/// Enrolled identity used for matching (decrypted, in memory only).
public struct EnrolledVoice: Sendable {
    public var participantId: String
    public var samples: [[Float]]

    public init(participantId: String, samples: [[Float]]) {
        self.participantId = participantId
        self.samples = samples
    }

    public var centroid: [Float]? { EmbeddingMath.centroid(samples) }
}

/// Decision thresholds derived from the enrolled data itself.
///
/// * Genuine scores: each sample vs. the centroid of the *other* samples of the
///   same person (leave-one-out).
/// * Impostor scores: each sample vs. the centroids of every other person.
/// * `acceptThreshold` = highest impostor score observed → zero false accepts on
///   the calibration set (conservative by construction).
/// * `requiredMargin` = spread (standard deviation) of genuine scores: the best
///   candidate must beat the runner-up by more than normal within-person variation.
///
/// Without enough data (≥ 2 people with ≥ 2 samples each) the calibration is
/// `nil` and the system only *suggests* identities; it never auto-assigns.
public struct SpeakerCalibration: Sendable, Equatable, Codable {
    public var acceptThreshold: Double
    public var requiredMargin: Double
    public var genuineCount: Int
    public var impostorCount: Int
    public var genuineMean: Double
    public var genuineMin: Double
    public var impostorMax: Double

    /// Genuine and impostor distributions overlap: some true matches will be rejected.
    public var hasOverlap: Bool { genuineMin <= impostorMax }

    public static func derive(from voices: [EnrolledVoice]) -> SpeakerCalibration? {
        let usable = voices.filter { $0.samples.count >= 2 }
        guard usable.count >= 2 else { return nil }
        var genuine: [Double] = []
        var impostor: [Double] = []
        let centroids = Dictionary(uniqueKeysWithValues: voices.compactMap { v in v.centroid.map { (v.participantId, $0) } })
        for voice in usable {
            for (i, sample) in voice.samples.enumerated() {
                var others = voice.samples
                others.remove(at: i)
                if let loo = EmbeddingMath.centroid(others) {
                    genuine.append(EmbeddingMath.cosine(sample, loo))
                }
                for (pid, c) in centroids where pid != voice.participantId {
                    impostor.append(EmbeddingMath.cosine(sample, c))
                }
            }
        }
        guard genuine.count >= 4, impostor.count >= 4 else { return nil }
        let mean = genuine.reduce(0, +) / Double(genuine.count)
        let variance = genuine.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, genuine.count - 1))
        return SpeakerCalibration(
            acceptThreshold: impostor.max()!,
            requiredMargin: sqrt(variance),
            genuineCount: genuine.count, impostorCount: impostor.count,
            genuineMean: mean, genuineMin: genuine.min()!, impostorMax: impostor.max()!)
    }
}

public struct MatchCandidate: Sendable, Equatable {
    public var participantId: String
    public var similarity: Double
}

public struct MatchDecision: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        /// Applied automatically.
        case accepted
        /// Best candidate shown to the user for confirmation; not applied.
        case suggested
        /// No enrolled voice is close: "Participante desconocido".
        case unknown
    }

    public var outcome: Outcome
    public var best: MatchCandidate?
    public var runnerUp: MatchCandidate?
    public var threshold: Double?
    public var margin: Double? {
        guard let best else { return nil }
        return best.similarity - (runnerUp?.similarity ?? -1)
    }
    public var reason: String
}

public struct SpeakerMatcher: Sendable {
    public var calibration: SpeakerCalibration?
    /// Clusters with less speech have unreliable embeddings: suggest only.
    public var minimumSpeechSecondsForAutoAccept: Double

    public init(calibration: SpeakerCalibration?, minimumSpeechSecondsForAutoAccept: Double = 3) {
        self.calibration = calibration
        self.minimumSpeechSecondsForAutoAccept = minimumSpeechSecondsForAutoAccept
    }

    public func decide(query: [Float], speechSeconds: Double, voices: [EnrolledVoice]) -> MatchDecision {
        let ranked = voices.compactMap { v -> MatchCandidate? in
            guard let c = v.centroid else { return nil }
            return MatchCandidate(participantId: v.participantId, similarity: EmbeddingMath.cosine(query, c))
        }.sorted { $0.similarity > $1.similarity }

        guard let best = ranked.first else {
            return MatchDecision(outcome: .unknown, best: nil, runnerUp: nil, threshold: nil,
                                 reason: "No hay perfiles de voz registrados.")
        }
        let runnerUp = ranked.dropFirst().first
        guard let calibration else {
            // Uncalibrated: only a suggestion, and only if the best candidate is
            // at least as close as people are to themselves would require — unknown.
            return MatchDecision(outcome: .suggested, best: best, runnerUp: runnerUp, threshold: nil,
                                 reason: "Calibración insuficiente (se requieren ≥2 personas con ≥2 muestras). Solo sugerencia.")
        }
        let margin = best.similarity - (runnerUp?.similarity ?? -1)
        if best.similarity < calibration.acceptThreshold {
            let nearMiss = best.similarity >= calibration.acceptThreshold - calibration.requiredMargin
            return MatchDecision(outcome: nearMiss ? .suggested : .unknown, best: best, runnerUp: runnerUp,
                                 threshold: calibration.acceptThreshold,
                                 reason: nearMiss ? "Similitud cercana pero inferior al umbral calibrado."
                                                  : "Ningún perfil supera el umbral calibrado.")
        }
        if margin < calibration.requiredMargin {
            return MatchDecision(outcome: .suggested, best: best, runnerUp: runnerUp,
                                 threshold: calibration.acceptThreshold,
                                 reason: "Ambiguo: dos perfiles con similitud parecida.")
        }
        if speechSeconds < minimumSpeechSecondsForAutoAccept {
            return MatchDecision(outcome: .suggested, best: best, runnerUp: runnerUp,
                                 threshold: calibration.acceptThreshold,
                                 reason: "Muy poca voz para una identificación automática fiable.")
        }
        return MatchDecision(outcome: .accepted, best: best, runnerUp: runnerUp,
                             threshold: calibration.acceptThreshold,
                             reason: "Supera el umbral calibrado con margen suficiente.")
    }
}
