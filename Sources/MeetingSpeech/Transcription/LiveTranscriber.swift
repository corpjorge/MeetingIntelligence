@preconcurrency import AVFoundation
@preconcurrency import FluidAudio
public import Foundation
public import MeetingCore
import os
import OSLog

/// Provisional live transcription text for one source.
public struct LiveTranscriptUpdate: Sendable, Equatable {
    public var source: MeetingCore.AudioSource
    /// Text FluidAudio has confirmed (stable within the live session).
    public var confirmed: String
    /// Latest hypothesis that may still change.
    public var volatile: String
    public var at: Date
}

/// Live, *provisional* transcription during recording using FluidAudio's
/// `SlidingWindowAsrManager` with the already-loaded Parakeet Ultra models
/// (11 s chunk + 2 s left/right context, quick 1 s hypotheses).
///
/// The final transcript always comes from the offline Parakeet Ultra pass over
/// the complete recording; live text is never persisted as the transcript.
public actor LiveTranscriber {
    public nonisolated let updates: AsyncStream<LiveTranscriptUpdate>
    private let continuation: AsyncStream<LiveTranscriptUpdate>.Continuation
    private var managers: [MeetingCore.AudioSource: SlidingWindowAsrManager] = [:]
    private nonisolated let inputs = LiveAudioInputs()
    private var tasks: [Task<Void, Never>] = []
    private var state: [MeetingCore.AudioSource: (confirmed: String, volatile: String)] = [:]
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "live-asr")

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    func start(models: AsrModels, sources: [MeetingCore.AudioSource], language: Language?) async throws {
        let config = SlidingWindowAsrConfig.streaming
            .applying(tdtConfig: TdtConfig(blankId: models.version.blankId))
            .applying(language: language)
        do { for source in sources {
            try Task.checkCancellation()
            let manager = SlidingWindowAsrManager(config: config)
            managers[source] = manager
            try await manager.loadModels(models)
            try Task.checkCancellation()
            try await manager.startStreaming(source: source == .localMicrophone ? .microphone : .system)
            try Task.checkCancellation()
            state[source] = ("", "")

            let updates = await manager.transcriptionUpdates
            tasks.append(Task { [weak self] in
                for await update in updates {
                    await self?.apply(update, source: source)
                }
            })

            inputs.open(source) { samples in
                guard let buffer = Self.pcmBuffer(samples) else { return }
                await manager.streamAudio(buffer)
            }
        } } catch {
            await stop()
            throw error
        }
    }

    static func pcmBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    /// Thread-safe entry point for 16 kHz mono samples from the recorder.
    public nonisolated func feed(_ samples: [Float], source: MeetingCore.AudioSource) {
        inputs.send(samples, to: source)
    }

    private func apply(_ update: SlidingWindowTranscriptionUpdate, source: MeetingCore.AudioSource) async {
        guard let manager = managers[source] else { return }
        // The manager keeps the cumulative confirmed text and the current volatile tail.
        let confirmed = await manager.confirmedTranscript
        let volatile = await manager.volatileTranscript
        state[source] = (confirmed, volatile)
        continuation.yield(LiveTranscriptUpdate(source: source, confirmed: confirmed, volatile: volatile, at: update.timestamp))
    }

    /// Ends input and returns the final live text per source (used by tests;
    /// the app discards live text in favour of the offline pass).
    public func finish() async -> [MeetingCore.AudioSource: String] {
        await inputs.close()
        var result: [MeetingCore.AudioSource: String] = [:]
        for (source, manager) in managers {
            result[source] = (try? await manager.finish()) ?? ""
        }
        return result
    }

    /// Stops all live streams and discards their state.
    public func stop() async {
        inputs.cancel()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        for manager in managers.values { await manager.cancel() }
        managers.removeAll()
        continuation.finish()
    }
}

extension ParakeetUltraProvider {
    /// Starts provisional live transcription for the given sources, reusing
    /// the loaded Ultra models (no second download or load).
    public func makeLiveTranscriber(sources: [MeetingCore.AudioSource], languageHint: String) async throws -> LiveTranscriber {
        let models = try await loadedModels()
        try Task.checkCancellation()
        let transcriber = LiveTranscriber()
        try await transcriber.start(models: models, sources: sources, language: Self.fluidLanguage(for: languageHint))
        return transcriber
    }
}

final class LiveAudioInputs: Sendable {
    private struct Input: Sendable {
        var continuation: AsyncStream<[Float]>.Continuation
        var consumer: Task<Void, Never>
    }

    private let inputs = OSAllocatedUnfairLock<[MeetingCore.AudioSource: Input]>(initialState: [:])
    private let bufferLimit: Int

    init(bufferLimit: Int = 400) {
        self.bufferLimit = bufferLimit
    }

    func open(_ source: MeetingCore.AudioSource, consumer: @escaping @Sendable ([Float]) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self,
                                                            bufferingPolicy: .bufferingNewest(bufferLimit))
        let task = Task {
            for await samples in stream { await consumer(samples) }
        }
        let replaced = inputs.withLock { current in
            let previous = current[source]
            current[source] = Input(continuation: continuation, consumer: task)
            return previous
        }
        replaced?.continuation.finish()
    }

    func send(_ samples: [Float], to source: MeetingCore.AudioSource) {
        inputs.withLock { current in _ = current[source]?.continuation.yield(samples) }
    }

    func close() async {
        let closed = removeAll()
        for input in closed { input.continuation.finish() }
        for input in closed { await input.consumer.value }
    }

    func cancel() {
        for input in removeAll() {
            input.continuation.finish()
            input.consumer.cancel()
        }
    }

    private func removeAll() -> [Input] {
        inputs.withLock { current in
            defer { current.removeAll() }
            return Array(current.values)
        }
    }
}
