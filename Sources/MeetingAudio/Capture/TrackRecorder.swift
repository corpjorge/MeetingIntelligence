public import Foundation
public import MeetingCore

/// Shared timeline origin for all tracks of one recording.
///
/// The timeline excludes paused intervals: while paused, buffers are dropped
/// and on resume the origin shifts by the paused duration for every track at
/// once, so tracks stay mutually aligned.
public final class CaptureClock: @unchecked Sendable {
    private let lock = NSLock()
    private let originSeconds: Double
    private var pausedAt: Double?
    private var pauses: [(start: Double, end: Double)] = []

    public init(originHostSeconds: Double = HostClock.nowSeconds()) {
        self.originSeconds = originHostSeconds
    }

    /// Historical mapping also handles video/audio buffers delivered after a pause.
    public func timelineSeconds(forHostSeconds hostSeconds: Double) -> Double? {
        lock.withLock { position(hostSeconds) }
    }

    private func position(_ hostSeconds: Double) -> Double? {
        if let pausedAt, hostSeconds >= pausedAt { return nil }
        var removed = 0.0
        for pause in pauses {
            if hostSeconds >= pause.start && hostSeconds < pause.end { return nil }
            if hostSeconds >= pause.end { removed += pause.end - pause.start }
        }
        return hostSeconds - originSeconds - removed
    }

    public var isPaused: Bool { lock.withLock { pausedAt != nil } }

    public var elapsed: Double {
        lock.withLock { max(0, position(pausedAt ?? HostClock.nowSeconds()) ?? positionBeforePause) }
    }

    private var positionBeforePause: Double {
        (pausedAt ?? HostClock.nowSeconds()) - originSeconds - pauses.reduce(0) { $0 + $1.end - $1.start }
    }

    public func pause(atHostSeconds now: Double = HostClock.nowSeconds()) {
        lock.withLock { if pausedAt == nil { pausedAt = now } }
    }

    public func resume(atHostSeconds now: Double = HostClock.nowSeconds()) {
        lock.withLock {
            if let start = pausedAt {
                pauses.append((start, max(start, now)))
                pausedAt = nil
            }
        }
    }
}

public struct TrackStatistics: Sendable {
    public var source: AudioSource
    public var url: URL
    public var durationSeconds: Double
    public var paddedSeconds: Double
    public var droppedSeconds: Double
    public var inputSampleRates: [Double]
    public var pauses: [PauseInterval]
}

/// Converts, aligns and writes one source to disk. All work happens on a
/// private serial queue; `ingest` may be called from any (real-time) thread.
public final class TrackRecorder: @unchecked Sendable {
    public let source: AudioSource
    public let outputSampleRate: Double

    let writer: CrashSafeWAVWriter
    private let queue: DispatchQueue
    private let clock: CaptureClock
    /// If present, both track recorders and the AEC share this recorder's queue.
    private let echoCanceller: RecordingEchoCanceller?
    private var aligner: TimelineAligner
    private var resampler: MonoResampler?
    private var seenRates: [Double] = []
    private var lastLevelEmit: Double = 0
    private let receiptLock = NSLock()
    private var receivedAt: Double?
    var lastReceivedHostTime: Double? { receiptLock.withLock { receivedAt } }
    private var digitalSilenceSeconds: Double = 0
    private var silenceWarningSent = false
    private var finished = false
    private var tailPaddedFrames = 0
    private var missingPadFrames = 0
    private var missingAudioFrames = 0
    private var replacedAudioFrames = 0
    private var writeFailureReported = false
    private let pauseLock = NSLock()
    /// While muted the recorder writes digital silence instead of the input, so
    /// the timeline stays aligned with the other track. Guarded by `pauseLock`.
    private var pauses: [PauseInterval] = []
    private var pausesClosed = false
    private let onLevel: @Sendable (AudioSource, AudioLevel) -> Void
    private let onWarning: @Sendable (RecordingWarning) -> Void
    /// Receives every converted 16 kHz mono block (e.g. live transcription).
    var onSamples: (@Sendable (AudioSource, [Float]) -> Void)?

    init(source: AudioSource, url: URL, outputSampleRate: Double, clock: CaptureClock,
         queue: DispatchQueue? = nil, echoCanceller: RecordingEchoCanceller? = nil,
         onLevel: @escaping @Sendable (AudioSource, AudioLevel) -> Void,
         onWarning: @escaping @Sendable (RecordingWarning) -> Void,
         onRecovered: @escaping @Sendable (RecordingWarning) -> Void = { _ in }) throws {
        self.source = source
        self.outputSampleRate = outputSampleRate
        self.clock = clock
        self.writer = try CrashSafeWAVWriter(url: url, sampleRate: Int(outputSampleRate))
        self.aligner = TimelineAligner(sampleRate: outputSampleRate)
        self.queue = queue ?? DispatchQueue(label: "mi.track.\(source.rawValue)", qos: .userInitiated)
        self.echoCanceller = echoCanceller
        self.onLevel = onLevel
        self.onWarning = onWarning
        if source == .localMicrophone {
            echoCanceller?.onOutput = { [weak self] samples in self?.writeOutput(samples) }
            echoCanceller?.onMissingReference = { onWarning(.echoReferenceUnavailable) }
            echoCanceller?.onReferenceRecovered = { onRecovered(.echoReferenceUnavailable) }
        }
    }

    /// - Parameters:
    ///   - mono: mono Float32 samples at `sampleRate`.
    ///   - hostTime: host time of the first sample, if valid.
    func ingest(_ mono: [Float], sampleRate: Double, hostTime: UInt64?) {
        guard !mono.isEmpty, sampleRate > 0 else { return }
        receiptLock.withLock { receivedAt = HostClock.nowSeconds() }
        let hostSeconds = hostTime.map(HAL.hostTimeToSeconds)
        // Resolve the timeline position now (pause state is time-sensitive).
        let timeline: Double?? = hostSeconds.map { clock.timelineSeconds(forHostSeconds: $0) }
        if case .some(.none) = timeline { return } // paused
        if hostSeconds == nil && clock.isPaused { return }
        queue.async { [self] in
            process(mono, sampleRate: sampleRate, timelineSeconds: timeline ?? nil)
        }
    }

    private func process(_ mono: [Float], sampleRate: Double, timelineSeconds: Double?) {
        guard !finished, !mono.isEmpty, sampleRate > 0 else { return }
        do {
            if resampler?.inputRate != sampleRate {
                resampler = try MonoResampler(inputRate: sampleRate, outputRate: outputSampleRate)
                if !seenRates.contains(sampleRate) { seenRates.append(sampleRate) }
            }
            trackSilence(mono, sampleRate: sampleRate)
            let converted = try resampler!.process(mono)
            guard !converted.isEmpty else { return }
            let plan = aligner.plan(startSeconds: timelineSeconds, frameCount: converted.count)
            if plan.padFrames > 0 { appendSilence(frames: plan.padFrames) }
            if plan.dropFrames < converted.count {
                var aligned = Array(converted.dropFirst(plan.dropFrames))
                silencePausedFrames(&aligned, endingAt: aligner.framesWritten)
                appendAligned(aligned)
            }
        } catch {
            onWarning(.writeFailed(source, error.localizedDescription))
        }
    }

    private func silencePausedFrames(_ samples: inout [Float], endingAt end: Int) {
        let start = end - samples.count
        let rate = outputSampleRate
        let spans: [Range<Int>] = pauseLock.withLock {
            var result: [Range<Int>] = []
            for pause in pauses.reversed() {
                let upper = pause.end.isFinite ? Int((pause.end * rate).rounded()) : Int.max
                guard upper > start else { break }
                let lower = max(start, Int((pause.start * rate).rounded()))
                if lower < min(upper, end) { result.append(lower..<min(upper, end)) }
            }
            return result
        }
        for span in spans {
            for index in span { samples[index - start] = 0 }
        }
    }

    private func appendAligned(_ samples: [Float]) {
        if let echoCanceller, source == .localMicrophone {
            echoCanceller.appendMicrophone(samples)
        } else {
            writeOutput(samples)
            echoCanceller?.appendReference(samples)
        }
    }

    private func writeOutput(_ samples: [Float]) {
        emitLevel(samples)
        guard restoreMissingFrames() else {
            missingAudioFrames += samples.count
            return
        }
        let before = writer.framesWritten
        do {
            try writer.append(samples)
            writeFailureReported = false
        } catch {
            reportWriteFailure(error)
        }
        let written = Int(writer.framesWritten - before)
        missingAudioFrames += samples.count - written
        if written > 0 { onSamples?(source, written == samples.count ? samples : Array(samples.prefix(written))) }
    }

    private func appendSilence(frames: Int) {
        if echoCanceller == nil {
            missingPadFrames += frames
            _ = restoreMissingFrames()
            return
        }
        // Bound allocations for late starts and disconnected devices.
        var remaining = frames
        while remaining > 0 {
            let count = min(remaining, Int(outputSampleRate) / 50)
            appendAligned([Float](repeating: 0, count: count))
            remaining -= count
        }
    }

    private func restoreMissingFrames() -> Bool {
        let missing = missingPadFrames + missingAudioFrames
        guard missing > 0 else { return true }
        let before = writer.framesWritten
        do {
            try writer.appendSilence(frames: missing)
        } catch {
            reportWriteFailure(error)
        }
        var written = Int(writer.framesWritten - before)
        let audio = min(written, missingAudioFrames)
        missingAudioFrames -= audio
        replacedAudioFrames += audio
        written -= audio
        missingPadFrames -= min(written, missingPadFrames)
        return missingPadFrames + missingAudioFrames == 0
    }

    private func reportWriteFailure(_ error: any Error) {
        guard !writeFailureReported else { return }
        writeFailureReported = true
        onWarning(.writeFailed(source, error.localizedDescription))
    }

    private func emitLevel(_ mono: [Float]) {
        let now = HAL.nowSeconds()
        guard now - lastLevelEmit >= 0.05 else { return }
        lastLevelEmit = now
        onLevel(source, LevelMeter.measure(mono))
    }

    /// Starts/ends an intentional pause at a timeline position.
    func setMuted(_ value: Bool, atTimelineSeconds time: Double) {
        pauseLock.withLock {
            guard !pausesClosed, value != (pauses.last?.end == .infinity) else { return }
            if value {
                pauses.append(PauseInterval(start: time, end: .infinity))
            } else {
                pauses[pauses.count - 1].end = max(pauses[pauses.count - 1].start, time)
            }
        }
    }

    /// Exact digital zeros for a long time usually mean a missing system-audio
    /// permission (the HAL delivers silence instead of failing).
    private func trackSilence(_ mono: [Float], sampleRate: Double) {
        if mono.allSatisfy({ $0 == 0 }) {
            digitalSilenceSeconds += Double(mono.count) / sampleRate
            if !silenceWarningSent, digitalSilenceSeconds >= 15 {
                silenceWarningSent = true
                onWarning(.prolongedDigitalSilence(source))
            }
        } else {
            digitalSilenceSeconds = 0
        }
    }

    /// Pads the track to the shared end time and closes the file.
    func finish(atTimelineSeconds end: Double) -> TrackStatistics {
        queue.sync {
            if !finished {
                pauseLock.withLock {
                    pausesClosed = true
                    if let last = pauses.indices.last, !pauses[last].end.isFinite {
                        pauses[last].end = max(pauses[last].start, end)
                    }
                }
                let target = Int(end * outputSampleRate)
                let missing = target - aligner.framesWritten
                if missing > 0 {
                    appendSilence(frames: missing)
                    tailPaddedFrames = missing
                }
                if source == .localMicrophone { echoCanceller?.finish() }
                _ = restoreMissingFrames()
                try? writer.close()
                finished = true
            }
            let padded = aligner.totalPaddedFrames + tailPaddedFrames + replacedAudioFrames
            return TrackStatistics(source: source, url: writer.url,
                                   durationSeconds: writer.durationSeconds,
                                   paddedSeconds: Double(padded) / outputSampleRate,
                                   droppedSeconds: Double(aligner.totalDroppedFrames) / outputSampleRate,
                                   inputSampleRates: seenRates, pauses: pauseLock.withLock { pauses })
        }
    }

    /// Periodic header flush is automatic; this forces one (e.g. on app termination).
    func flush() {
        queue.sync { try? writer.flushHeader() }
    }
}
