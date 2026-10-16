public import Foundation
@preconcurrency import FluidAudio
import OSLog

/// One speaker turn produced by diarization (file timeline, seconds).
public struct SpeakerTurn: Sendable, Hashable {
    public var clusterKey: String
    public var start: Double
    public var end: Double
    public var quality: Double

    public init(clusterKey: String, start: Double, end: Double, quality: Double) {
        self.clusterKey = clusterKey
        self.start = start
        self.end = end
        self.quality = quality
    }

    public var duration: Double { max(0, end - start) }
}

public struct DiarizationOutput: Sendable {
    public var turns: [SpeakerTurn]
    /// Mean L2-normalized WeSpeaker embedding per cluster (biometric — encrypt before storing).
    public var embeddings: [String: [Float]]
    public var processingSeconds: Double
    public var modelIdentifier: String

    /// False when the diarizer found no speech it could embed (very short or
    /// faint fragments). The transcript is kept; its segments stay unattributed
    /// (or go to the local user on a single-speaker microphone track).
    public var speechDetected: Bool { !turns.isEmpty }

    /// Total speech per cluster, largest first.
    public var speechByCluster: [(key: String, seconds: Double)] {
        Dictionary(grouping: turns, by: \.clusterKey)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.duration }) }
            .sorted { $0.1 > $1.1 }
    }
}

/// Offline (whole-file) diarization with FluidAudio's pyannote-community
/// segmentation + WeSpeaker embeddings + VBx clustering.
///
/// The remote Teams track is a *mix* of all remote voices; diarization is what
/// separates them. Overlapping turns are preserved as returned.
public actor DiarizationService {
    public static let modelIdentifier = "FluidInference/speaker-diarization-coreml offline VBx (FluidAudio 0.17.7)"

    /// Denser segmentation windows recover short turns ("sí", "ok") that the
    /// default step absorbs into neighbours (FluidAudio #879: 0.1 measured best
    /// for rapid exchanges). Costs more segments/compute.
    public var segmentationStepRatio: Double

    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "diarization")
    private var manager: ExclusiveBox<OfflineDiarizerManager>?
    private var gate = SerialGate()

    public init(segmentationStepRatio: Double = 0.1) {
        self.segmentationStepRatio = segmentationStepRatio
    }

    /// FluidAudio's cache folder for the diarizer repo (`<models>/speaker-diarization`).
    public nonisolated var cacheDirectory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .diarizer)
    }

    public func isModelCached() -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        return contents.contains { $0.hasSuffix(".mlmodelc") }
    }

    public func prepare() async throws {
        await acquire()
        defer { gate.leave() }
        _ = try await loadedManager()
    }

    private func acquire() async {
        if !gate.tryEnter() { await withCheckedContinuation { gate.enqueue($0) } }
    }

    public func unload() {
        manager = nil
    }

    /// Must be called while holding `gate`.
    private func loadedManager() async throws -> ExclusiveBox<OfflineDiarizerManager> {
        if let manager { return manager }
        var config = OfflineDiarizerConfig()
        config.segmentation.stepRatio = segmentationStepRatio
        let box = ExclusiveBox(OfflineDiarizerManager(config: config))
        try await box.value.prepareModels()
        self.manager = box
        return box
    }

    public func diarize(fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizationOutput {
        await acquire()
        defer { gate.leave() }
        let manager = try await loadedManager()
        let started = Date()
        let result: DiarizationResult
        do {
            result = try await manager.value.process(fileURL) { done, total in
                progress(total > 0 ? Double(done) / Double(total) : 0)
            }
        } catch OfflineDiarizationError.noSpeechDetected {
            // Not a failure: ASR may still find a few words the segmentation/embedding
            // stages consider too short to cluster (e.g. a "sí" on the microphone).
            let elapsed = Date().timeIntervalSince(started)
            logger.notice("Diarization: no embeddable speech in \(elapsed, format: .fixed(precision: 2)) s")
            return DiarizationOutput(turns: [], embeddings: [:], processingSeconds: elapsed,
                                     modelIdentifier: Self.modelIdentifier)
        }
        let turns = result.segments.map {
            SpeakerTurn(clusterKey: $0.speakerId, start: Double($0.startTimeSeconds),
                        end: Double($0.endTimeSeconds), quality: Double($0.qualityScore))
        }.sorted { $0.start < $1.start }
        let elapsed = Date().timeIntervalSince(started)
        logger.info("Diarization: \(turns.count) turns, \(Set(turns.map(\.clusterKey)).count) clusters in \(elapsed, format: .fixed(precision: 2)) s")
        return DiarizationOutput(turns: turns, embeddings: result.speakerDatabase ?? [:],
                                 processingSeconds: elapsed, modelIdentifier: Self.modelIdentifier)
    }
}
