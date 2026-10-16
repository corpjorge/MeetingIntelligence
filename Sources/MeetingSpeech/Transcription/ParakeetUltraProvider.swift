public import Foundation
@preconcurrency import FluidAudio
import MeetingCore
import OSLog

/// FluidAudio + Parakeet Ultra (`FluidInference/parakeet-ultra-coreml`).
///
/// * Models are downloaded once into FluidAudio's cache
///   (`~/Library/Application Support/FluidAudio/Models/parakeet-ultra`) and
///   loaded once per process; the loaded manager is reused for every file.
/// * Never falls back to another model: if Ultra cannot be prepared the error
///   is surfaced to the user.
/// * Runs on the Apple Neural Engine (FluidAudio default compute units).
public actor ParakeetUltraProvider: ASRProvider {
    public static let fluidAudioVersion = "0.17.7"
    static let modelVersion = AsrModelVersion.ultra

    public nonisolated let descriptor = ASREngineDescriptor(
        id: "parakeet-ultra",
        displayName: "Parakeet Ultra",
        modelIdentifier: "FluidInference/parakeet-ultra-coreml (FluidAudio \(fluidAudioVersion))",
        approximateDownloadBytes: 630_000_000
    )

    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "asr")
    private var manager: AsrManager?
    private var models: AsrModels?
    private var preparation: Task<AsrManager, any Error>?
    /// One transcription at a time: AsrManager supports a single progress session.
    private var gate = SerialGate()

    public init() {}

    public nonisolated var cacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: Self.modelVersion)
    }

    public func isModelCached() async -> Bool {
        AsrModels.modelsExist(at: cacheDirectory, version: Self.modelVersion)
    }

    public func prepare(progress: @escaping @Sendable (ModelPreparationPhase) -> Void) async throws {
        _ = try await loadedManager(progress: progress)
    }

    public func unload() async {
        preparation?.cancel()
        preparation = nil
        if let manager { await manager.cleanup() }
        manager = nil
        models = nil
    }

    private func loadedManager(progress: (@Sendable (ModelPreparationPhase) -> Void)? = nil) async throws -> AsrManager {
        if let manager { return manager }
        if let preparation { return try await preparation.value }
        let version = Self.modelVersion
        let logger = self.logger
        let task = Task<AsrManager, any Error> {
            progress?(.checking)
            let started = Date()
            let models: AsrModels
            do {
                models = try await AsrModels.downloadAndLoad(version: version, progressHandler: { p in
                    switch p.phase {
                    case .listing: progress?(.checking)
                    case .downloading: progress?(.downloading(fraction: p.fractionCompleted))
                    case .compiling(let name): progress?(.compiling(name))
                    }
                })
            } catch {
                throw ASRProviderError.modelUnavailable(ProcessingErrorText.describe(error))
            }
            guard models.version == version else {
                throw ASRProviderError.modelUnavailable("se cargó \(models.version) en lugar de ultra")
            }
            progress?(.loading)
            let config = ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId),
                                   encoderHiddenSize: version.encoderHiddenSize)
            let manager = AsrManager(config: config)
            try await manager.loadModels(models)
            self.store(models: models)
            logger.info("Parakeet Ultra ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
            progress?(.ready)
            return manager
        }
        preparation = task
        do {
            let ready = try await task.value
            manager = ready
            preparation = nil
            return ready
        } catch {
            preparation = nil
            throw error
        }
    }

    private func store(models: AsrModels) { self.models = models }

    /// Loaded Ultra models (loads them on first use).
    func loadedModels() async throws -> AsrModels {
        _ = try await loadedManager()
        guard let models else { throw ASRProviderError.modelUnavailable("modelos no cargados") }
        return models
    }

    public func transcribe(fileURL: URL, languageHint: String,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> ASRTranscription {
        let manager = try await loadedManager()
        if !gate.tryEnter() { await withCheckedContinuation { gate.enqueue($0) } }
        defer { gate.leave() }
        try Task.checkCancellation()

        // Progress is only emitted for audio longer than one 15 s window.
        let stream = await manager.transcriptionProgressStream
        let progressTask = Task {
            do {
                for try await value in stream { progress(min(1, max(0, value))) }
            } catch {}
        }
        defer { progressTask.cancel() }

        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let started = Date()
        let result: ASRResult
        do {
            result = try await manager.transcribe(fileURL, decoderState: &state,
                                                  language: Self.fluidLanguage(for: languageHint))
        } catch let error as CancellationError {
            throw error
        } catch let error as ASRError {
            if case .invalidAudioData = error { throw ASRProviderError.emptyAudio }
            throw ASRProviderError.failed(ProcessingErrorText.describe(error))
        }
        progress(1)
        let words = WordGrouping.words(from: result.tokenTimings ?? [])
        let confidences = (result.tokenTimings ?? []).map { Double($0.confidence) }
        return ASRTranscription(
            text: result.text,
            words: words,
            meanConfidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
            audioDurationSeconds: result.duration,
            processingSeconds: Date().timeIntervalSince(started))
    }

    /// FluidAudio's language hint only filters tokens by *script*; Spanish and
    /// English share the Latin script, so mixed es/en speech is unaffected.
    static func fluidLanguage(for tag: String) -> Language? {
        let primary = tag.split(separator: "-").first.map(String.init)?.lowercased() ?? tag
        return Language(rawValue: primary)
    }
}
