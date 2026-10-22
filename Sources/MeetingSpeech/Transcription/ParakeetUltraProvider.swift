public import Foundation
@preconcurrency import FluidAudio
import MeetingAudio
public import MeetingCore
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

    /// For in-app updates (TD-27): FluidAudio downloads this repository's `main`.
    public nonisolated var managedModel: ManagedModel {
        ManagedModel(id: descriptor.id, displayName: "Parakeet Ultra · transcripción",
                     repository: Repo.parakeetUltra.remotePath, revision: .from(Repo.parakeetUltra.revision),
                     directory: cacheDirectory)
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

        // Long dead-silence runs are collapsed before decoding (TD-22); times are mapped back below.
        let compactedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mi-asr-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: compactedURL) }
        let compaction: SilenceCompaction?
        do {
            compaction = try SilenceCompactor.compact(fileURL, to: compactedURL)
        } catch {
            logger.error("Silence compaction skipped: \(error.localizedDescription)")
            compaction = nil
        }
        if let compaction {
            logger.info("Collapsed \(compaction.removedSeconds, format: .fixed(precision: 1)) s of dead silence before ASR")
        }

        let result: ASRResult
        do {
            result = try await manager.transcribe(compaction == nil ? fileURL : compactedURL, decoderState: &state,
                                                  language: Self.fluidLanguage(for: languageHint))
        } catch let error as CancellationError {
            throw error
        } catch let error as ASRError {
            if case .invalidAudioData = error { throw ASRProviderError.emptyAudio }
            throw ASRProviderError.failed(ProcessingErrorText.describe(error))
        }
        var tokens = Self.tokensOnFileTimeline(result.tokenTimings ?? [], compaction: compaction)
        var text = result.text
        // Short isolated replies: re-decode after nearby speech of the same file (TD-26).
        do {
            let redecoded = try await ShortUtteranceContext.redecode(
                tokens: tokens, fileURL: fileURL, manager: manager, language: Self.fluidLanguage(for: languageHint))
            if redecoded.replaced > 0 {
                tokens = redecoded.tokens
                text = tokens.map(\.piece).joined().replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
                logger.info("Re-decoded \(redecoded.replaced) short utterance(s) with context")
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            logger.error("Short-utterance re-decode skipped: \(error.localizedDescription, privacy: .public)")
        }
        progress(1)
        let confidences = tokens.map { Double($0.confidence) }
        return ASRTranscription(
            text: text,
            words: WordGrouping.words(from: tokens.map { ($0.piece, $0.start, $0.end, $0.confidence) }),
            meanConfidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
            audioDurationSeconds: compaction?.originalDurationSeconds ?? result.duration,
            processingSeconds: Date().timeIntervalSince(started),
            tokens: tokens)
    }

    /// Token timings mapped from the (possibly compacted) decoded audio back to the file's own timeline.
    static func tokensOnFileTimeline(_ timings: [TokenTiming], compaction: SilenceCompaction?) -> [ASRToken] {
        reattachSplitWords(timings.map { token in
            let interval = compaction?.originalInterval(start: token.startTime, end: token.endTime)
                ?? (start: token.startTime, end: token.endTime)
            return ASRToken(piece: token.token, tokenId: token.tokenId, start: interval.start, end: interval.end,
                            confidence: token.confidence)
        })
    }

    /// Across a removed gap the decoder can leave a piece on the wrong side: an opening
    /// mark ("▁¿") at the end of the previous span, or a closing mark (".") after the gap.
    /// The word would stretch over the gap and glue two utterances, so the letterless
    /// piece is moved next to the word it belongs to. Pieces with letters are not moved.
    static func reattachSplitWords(_ tokens: [ASRToken], maxGap: Double = 1.0) -> [ASRToken] {
        func hasLetters(_ piece: String) -> Bool { piece.contains { $0.isLetter || $0.isNumber } }
        var tokens = tokens
        guard tokens.count > 1 else { return tokens }
        for i in 0..<(tokens.count - 1) {
            let current = tokens[i], next = tokens[i + 1]
            guard !next.piece.hasPrefix("▁"), next.start - current.end > maxGap else { continue }
            if !hasLetters(next.piece) {
                let duration = min(max(0, next.end - next.start), 0.2)
                tokens[i + 1].start = current.end
                tokens[i + 1].end = current.end + duration
            } else if !hasLetters(current.piece) {
                let duration = min(max(0, current.end - current.start), 0.2)
                tokens[i].end = next.start
                tokens[i].start = next.start - duration
            }
        }
        return tokens
    }

    /// FluidAudio's language hint only filters tokens by *script* (Latin /
    /// Cyrillic / Greek); Ultra has no language prompt. Spanish, English,
    /// French and Portuguese share the Latin script, so the hint cannot stop a
    /// short Spanish utterance from drifting to another of them (TD-22); mixed
    /// es/en speech is likewise unaffected.
    static func fluidLanguage(for tag: String) -> Language? {
        let primary = tag.split(separator: "-").first.map(String.init)?.lowercased() ?? tag
        return Language(rawValue: primary)
    }
}
