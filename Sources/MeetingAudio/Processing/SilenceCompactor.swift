public import Foundation
import AVFoundation

/// Result of collapsing dead silence: which spans of the original audio were
/// kept and where each one starts on the compacted timeline.
public struct SilenceCompaction: Sendable, Equatable {
    public struct Span: Sendable, Equatable {
        public var originalStart: Int
        public var compactedStart: Int
        public var length: Int
    }

    /// Kept spans in order (sample offsets). Never empty.
    public var spans: [Span]
    public var sampleRate: Int
    public var originalSampleCount: Int

    public var compactedSampleCount: Int { spans.last.map { $0.compactedStart + $0.length } ?? 0 }
    public var originalDurationSeconds: Double { Double(originalSampleCount) / Double(sampleRate) }
    public var removedSeconds: Double { Double(originalSampleCount - compactedSampleCount) / Double(sampleRate) }

    /// Maps a compacted time back to the original file. A time exactly on a
    /// junction belongs to the following span.
    public func originalTime(_ compactedSeconds: Double) -> Double {
        let sample = compactedSeconds * Double(sampleRate)
        let span = spans[spanIndex(atCompacted: sample)]
        return (Double(span.originalStart) + sample - Double(span.compactedStart)) / Double(sampleRate)
    }

    /// Maps a compacted `[start, end]` interval (a token). The end is clipped to
    /// the kept span where the interval starts: nothing sounds in a removed gap,
    /// so a token never stretches across one.
    public func originalInterval(start: Double, end: Double) -> (start: Double, end: Double) {
        let startSample = start * Double(sampleRate)
        let span = spans[spanIndex(atCompacted: startSample)]
        let spanEnd = Double(span.compactedStart + span.length)
        let endSample = min(max(end * Double(sampleRate), startSample), max(spanEnd, startSample))
        let offset = Double(span.originalStart) - Double(span.compactedStart)
        return ((startSample + offset) / Double(sampleRate), (endSample + offset) / Double(sampleRate))
    }

    /// Last span starting at or before `sample` (the first span for earlier samples).
    private func spanIndex(atCompacted sample: Double) -> Int {
        var low = 0, high = spans.count - 1, index = 0
        while low <= high {
            let mid = (low + high) / 2
            if Double(spans[mid].compactedStart) <= sample {
                index = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return index
    }
}

/// Collapses long runs of dead silence (digital zeros from a paused or muted
/// capture, a silent system-audio tap) before ASR. Parakeet decodes fixed
/// ~15 s windows; a window that is mostly dead silence leaves a short
/// utterance without acoustic context and the multilingual model drifts to
/// another language ("Aló" → "Hello"). Only frames below `deadRMS`
/// — quieter than any real speech — are removed, and `keptFrames` stay on
/// each side of sound. See TD-22.
public enum SilenceCompactor {
    /// Only 16 kHz mono files (every recorded or imported track) are compacted.
    public static let sampleRate = 16_000
    /// One Parakeet encoder frame: 80 ms.
    public static let frameSamples = 1_280
    /// FluidAudio's `ChunkProcessor.speechRmsFloor` (−66 dBFS), internal there.
    public static let deadRMS: Float = 0.0005
    /// Shorter dead runs (pauses between words or turns) are left untouched (≈ 1 s).
    public static let minimumRunFrames = 13
    /// Dead frames kept next to sound on each side of a removed run (240 ms).
    public static let keptFrames = 3
    /// FluidAudio rejects inputs shorter than 0.3 s.
    static let minimumOutputSamples = 4_800

    /// Plans the compaction from per-frame RMS values (`frameSamples` each;
    /// the last frame may be partial). Returns nil when nothing would be
    /// removed or no frame carries sound: the file is then used unchanged.
    public static func plan(frameRMS: [Float], sampleCount: Int) -> SilenceCompaction? {
        let frames = frameRMS.count
        guard frames > 0, frameRMS.contains(where: { $0 >= deadRMS }) else { return nil }
        func offset(_ frame: Int) -> Int { min(frame * frameSamples, sampleCount) }

        var removed: [Range<Int>] = []
        var i = 0
        while i < frames {
            guard frameRMS[i] < deadRMS else { i += 1; continue }
            var j = i
            while j < frames && frameRMS[j] < deadRMS { j += 1 }
            if j - i >= minimumRunFrames {
                let head = i == 0 ? 0 : keptFrames
                let tail = j == frames ? 0 : keptFrames
                removed.append(offset(i + head)..<offset(j - tail))
            }
            i = j
        }

        var spans: [SilenceCompaction.Span] = []
        var cursor = 0, compacted = 0
        func keep(upTo end: Int) {
            guard end > cursor else { return }
            spans.append(.init(originalStart: cursor, compactedStart: compacted, length: end - cursor))
            compacted += end - cursor
        }
        for range in removed {
            keep(upTo: range.lowerBound)
            cursor = range.upperBound
        }
        keep(upTo: sampleCount)
        guard !spans.isEmpty, compacted < sampleCount, compacted >= minimumOutputSamples else { return nil }
        return SilenceCompaction(spans: spans, sampleRate: sampleRate, originalSampleCount: sampleCount)
    }

    /// Measures `source` and, when the plan removes anything, writes the kept
    /// spans to `destination` in the source's own file format, so kept samples
    /// reach the ASR unchanged. Streams in blocks (constant memory). Returns nil,
    /// without creating `destination`, when the file is used as is.
    public static func compact(_ source: URL, to destination: URL) throws -> SilenceCompaction? {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard format.channelCount == 1, format.sampleRate == Double(sampleRate),
              format.commonFormat == .pcmFormatFloat32 else { return nil }
        let blockFrames = AVAudioFrameCount(frameSamples * 50)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else { return nil }

        // Pass 1: RMS per 80 ms frame.
        var frameRMS: [Float] = []
        var sum: Float = 0, count = 0, total = 0
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: blockFrames)
            let n = Int(buffer.frameLength)
            guard n > 0, let samples = buffer.floatChannelData?[0] else { break }
            for k in 0..<n {
                sum += samples[k] * samples[k]
                count += 1
                if count == frameSamples {
                    frameRMS.append((sum / Float(count)).squareRoot())
                    sum = 0
                    count = 0
                }
            }
            total += n
        }
        if count > 0 { frameRMS.append((sum / Float(count)).squareRoot()) }
        guard let plan = plan(frameRMS: frameRMS, sampleCount: total) else { return nil }

        // Pass 2: copy the kept spans.
        let output = try AVAudioFile(forWriting: destination, settings: input.fileFormat.settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        for span in plan.spans {
            input.framePosition = AVAudioFramePosition(span.originalStart)
            var remaining = span.length
            while remaining > 0 {
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, Int(blockFrames))))
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                remaining -= Int(buffer.frameLength)
            }
        }
        output.close()
        return plan
    }
}
