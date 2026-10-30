import CSpeexDSP
import Foundation

/// Recording-only AEC. Both inputs must already be mono, resampled and aligned
/// to the same capture timeline. Confined to the two recorders' shared queue.
/// Never opens an audio device or changes another application's input.
final class RecordingEchoCanceller {
    let frameSize: Int
    let referenceLookahead: Int
    let maximumPendingFrames: Int
    let recoveryFrames: Int
    private let maximumReferenceFrames: Int
    private let echo: OpaquePointer
    private var microphone = SampleFIFO()
    private var reference = SampleFIFO()
    private var finished = false
    private var referenceStarted = false
    private var warnedAboutReference = false
    private var framesWithReference = 0

    var onOutput: (([Float]) -> Void)?
    var onMissingReference: (() -> Void)?
    var onReferenceRecovered: (() -> Void)?

    init(sampleRate: Int) throws {
        guard (8_000...48_000).contains(sampleRate) else {
            throw CaptureError.unsupportedFormat("cancelación de eco a \(sampleRate) Hz")
        }
        frameSize = sampleRate / 50 // 20 ms
        // Make small timestamp/resampler offsets causal for the adaptive filter.
        referenceLookahead = sampleRate * 80 / 1_000
        maximumPendingFrames = sampleRate / 2
        recoveryFrames = 50
        maximumReferenceFrames = sampleRate * 2
        guard let echo = speex_echo_state_init(Int32(frameSize), Int32(sampleRate * 3 / 10)) else {
            throw CaptureError.unsupportedFormat("no se pudo crear el cancelador de eco")
        }
        self.echo = echo
        var rate = Int32(sampleRate)
        speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
    }

    deinit {
        speex_echo_state_destroy(echo)
    }

    func appendMicrophone(_ samples: [Float]) {
        guard !finished else { return }
        microphone.append(samples)
        drain(final: false)
    }

    func appendReference(_ samples: [Float]) {
        guard !finished else { return }
        if !samples.isEmpty { referenceStarted = true }
        reference.append(samples)
        drain(final: false)
        // A stopped/disconnected microphone must not retain the whole meeting.
        reference.discard(before: reference.end - maximumReferenceFrames)
    }

    /// Call after both capture sources and their queued input have been drained.
    func finish() {
        guard !finished else { return }
        drain(final: true)
        reference.discard(before: reference.end)
        finished = true
    }

    var pendingMicrophoneFrames: Int { microphone.count }
    var bufferedReferenceFrames: Int { reference.count }

    private func drain(final: Bool) {
        while microphone.count >= frameSize || (final && microphone.count > 0) {
            let count = min(frameSize, microphone.count)
            let start = microphone.start
            let referenceStart = start + referenceLookahead
            let hasReference = reference.contains(start: referenceStart, count: count)
            guard hasReference || final || microphone.count >= maximumPendingFrames else { break }
            let mic = microphone.read(start: start, count: count)
            let output: [Float]
            if !hasReference {
                // Preserve the user's speech rather than mute a track whose
                // reference is late or unavailable. Never block capture.
                output = mic
                speex_echo_state_reset(echo)
                framesWithReference = 0
                // Both tracks normally end together, leaving no future reference
                // for the last lookahead window. Pass it through without a false
                // missing-source warning; never filter it with invented silence.
                let unexpectedGap = !final || reference.end <= start || reference.start > referenceStart
                if unexpectedGap, referenceStarted, !warnedAboutReference, mic.contains(where: { $0 != 0 }) {
                    warnedAboutReference = true
                    onMissingReference?()
                }
            } else {
                output = cancel(microphone: mic, reference: reference.read(start: referenceStart, count: count))
                if warnedAboutReference {
                    framesWithReference += 1
                    if framesWithReference >= recoveryFrames {
                        warnedAboutReference = false
                        framesWithReference = 0
                        onReferenceRecovered?()
                    }
                }
            }
            microphone.discard(before: start + count)
            reference.discard(before: microphone.start + referenceLookahead)
            onOutput?(output)
        }
    }

    private func cancel(microphone: [Float], reference: [Float]) -> [Float] {
        var near = [Int16](repeating: 0, count: frameSize)
        var far = near
        var cleaned = near
        for i in microphone.indices {
            near[i] = Self.pcm(microphone[i])
            far[i] = Self.pcm(reference[i])
        }
        near.withUnsafeBufferPointer { near in
            far.withUnsafeBufferPointer { far in
                cleaned.withUnsafeMutableBufferPointer { cleaned in
                    speex_echo_cancellation(echo, near.baseAddress!, far.baseAddress!, cleaned.baseAddress!)
                }
            }
        }
        // Digital silence includes intentional microphone pauses and alignment
        // gaps. The filter must never synthesize sound into those samples.
        return microphone.indices.map { microphone[$0] == 0 ? 0 : Float(cleaned[$0]) / Float(Int16.max) }
    }

    private static func pcm(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16((max(-1, min(1, value)) * Float(Int16.max)).rounded())
    }
}

/// Absolute sample positions survive compaction; bounded reads retain their positions.
private struct SampleFIFO {
    private var storage: [Float] = []
    private var offset = 0
    private(set) var start = 0
    var count: Int { storage.count - offset }
    var end: Int { start + count }

    mutating func append(_ samples: [Float]) { storage.append(contentsOf: samples) }

    func contains(start position: Int, count: Int) -> Bool {
        position >= start && position + count <= end
    }

    func read(start position: Int, count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        let lower = max(start, position), upper = min(end, position + count)
        if lower < upper {
            for i in lower..<upper { result[i - position] = storage[offset + i - start] }
        }
        return result
    }

    mutating func discard(before position: Int) {
        let n = min(count, max(0, position - start))
        offset += n
        start += n
        if offset == storage.count {
            storage.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset > 16_000 && offset > storage.count / 2 {
            storage.removeFirst(offset)
            offset = 0
        }
    }
}
