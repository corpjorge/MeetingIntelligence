public import Foundation
public import MeetingCore

/// Shared timeline origin for all tracks of one recording.
///
/// The timeline excludes paused intervals: while paused, buffers are dropped
/// and on resume the origin shifts by the paused duration for every track at
/// once, so tracks stay mutually aligned.
public final class CaptureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var originSeconds: Double
    private var pausedAt: Double?
    private var pausedTotal: Double = 0

    public init(originHostSeconds: Double = HostClock.nowSeconds()) {
        self.originSeconds = originHostSeconds
    }

    /// Timeline position of an event that happened at `hostSeconds`, or nil while paused.
    public func timelineSeconds(forHostSeconds hostSeconds: Double) -> Double? {
        lock.withLock {
            guard pausedAt == nil else { return nil }
            return hostSeconds - originSeconds - pausedTotal
        }
    }

    public var isPaused: Bool { lock.withLock { pausedAt != nil } }

    /// Elapsed recorded time (excluding pauses).
    public var elapsed: Double {
        lock.withLock {
            let now = pausedAt ?? HAL.nowSeconds()
            return max(0, now - originSeconds - pausedTotal)
        }
    }

    public func pause() {
        lock.withLock { if pausedAt == nil { pausedAt = HAL.nowSeconds() } }
    }

    public func resume() {
        lock.withLock {
            if let pausedAt {
                pausedTotal += HAL.nowSeconds() - pausedAt
                self.pausedAt = nil
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

    private let queue: DispatchQueue
    private let clock: CaptureClock
    private let writer: CrashSafeWAVWriter
    private var aligner: TimelineAligner
    private var resampler: MonoResampler?
    private var seenRates: [Double] = []
    private var lastLevelEmit: Double = 0
    private var digitalSilenceSeconds: Double = 0
    private var silenceWarningSent = false
    private var finished = false
    private var tailPaddedFrames = 0
    /// While muted the recorder writes digital silence instead of the input, so
    /// the timeline stays aligned with the other track. Queue-confined.
    private var muted = false
    private var pauses: [PauseInterval] = []
    private let onLevel: @Sendable (AudioSource, AudioLevel) -> Void
    private let onWarning: @Sendable (RecordingWarning) -> Void
    /// Receives every converted 16 kHz mono block (e.g. live transcription).
    var onSamples: (@Sendable (AudioSource, [Float]) -> Void)?

    init(source: AudioSource, url: URL, outputSampleRate: Double, clock: CaptureClock,
         onLevel: @escaping @Sendable (AudioSource, AudioLevel) -> Void,
         onWarning: @escaping @Sendable (RecordingWarning) -> Void) throws {
        self.source = source
        self.outputSampleRate = outputSampleRate
        self.clock = clock
        self.writer = try CrashSafeWAVWriter(url: url, sampleRate: Int(outputSampleRate))
        self.aligner = TimelineAligner(sampleRate: outputSampleRate)
        self.queue = DispatchQueue(label: "mi.track.\(source.rawValue)", qos: .userInitiated)
        self.onLevel = onLevel
        self.onWarning = onWarning
    }

    /// - Parameters:
    ///   - mono: mono Float32 samples at `sampleRate`.
    ///   - hostTime: host time of the first sample, if valid.
    func ingest(_ mono: [Float], sampleRate: Double, hostTime: UInt64?) {
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
            emitLevel(mono)
            var converted = try resampler!.process(mono)
            guard !converted.isEmpty else { return }
            if muted { converted = [Float](repeating: 0, count: converted.count) }
            onSamples?(source, converted)
            let plan = aligner.plan(startSeconds: timelineSeconds, frameCount: converted.count)
            if plan.padFrames > 0 { try writer.appendSilence(frames: plan.padFrames) }
            if plan.dropFrames < converted.count {
                try converted.withUnsafeBufferPointer { buffer in
                    try writer.append(UnsafeBufferPointer(rebasing: buffer[plan.dropFrames...]))
                }
            }
        } catch {
            onWarning(.writeFailed(source, error.localizedDescription))
        }
    }

    private func emitLevel(_ mono: [Float]) {
        let now = HAL.nowSeconds()
        guard now - lastLevelEmit >= 0.05 else { return }
        lastLevelEmit = now
        onLevel(source, muted ? .silence : LevelMeter.measure(mono))
    }

    /// Starts/ends an intentional pause at a timeline position.
    func setMuted(_ value: Bool, atTimelineSeconds time: Double) {
        queue.async { [self] in
            guard value != muted, !finished else { return }
            muted = value
            if value {
                pauses.append(PauseInterval(start: time, end: time))
            } else if let last = pauses.indices.last {
                pauses[last].end = time
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
                if muted, let last = pauses.indices.last { pauses[last].end = end }
                let target = Int(end * outputSampleRate)
                let missing = target - aligner.framesWritten
                if missing > 0 {
                    try? writer.appendSilence(frames: missing)
                    tailPaddedFrames = missing
                }
                try? writer.close()
                finished = true
            }
            return TrackStatistics(source: source, url: writer.url,
                                   durationSeconds: writer.durationSeconds,
                                   paddedSeconds: Double(aligner.totalPaddedFrames + tailPaddedFrames) / outputSampleRate,
                                   droppedSeconds: Double(aligner.totalDroppedFrames) / outputSampleRate,
                                   inputSampleRates: seenRates, pauses: pauses)
        }
    }

    /// Periodic header flush is automatic; this forces one (e.g. on app termination).
    func flush() {
        queue.sync { try? writer.flushHeader() }
    }
}
