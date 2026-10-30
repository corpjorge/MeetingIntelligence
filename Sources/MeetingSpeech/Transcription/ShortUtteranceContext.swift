import AVFoundation
@preconcurrency import FluidAudio
import Foundation

/// Short isolated utterances decoded alone often drift to another language ("¿Ya está?"
/// → "Wie er ist da?", TD-26). Ultra has no language prompt, but its encoder does use
/// context: re-decoding the utterance after nearby speech fixes most cases. Prefer
/// the same track; a microphone with no other speech can use the remote track.
/// The re-decode is kept only when it is non-empty and at least as confident,
/// which protects genuine short English phrases in mixed meetings.
enum ShortUtteranceContext {
    static let isolationGap = 2.0
    static let maxUtteranceSeconds = 3.0
    static let maxUtteranceWords = 6
    static let maxContextSeconds = 8.0
    static let sampleRate = 16_000.0
    static let maxCrossTrackGap = 30.0

    struct ContextSpan {
        var fileURL: URL
        var start: Double
        var end: Double
    }

    /// Nearby remote speech in meeting time, converted back to its own file time.
    /// Prefer preceding speech, excluding distant or simultaneous utterances.
    static func remoteSpans(start: Double, end: Double, contextTracks: [ASRContextTrack]) -> [ContextSpan] {
        var candidates: [(span: ContextSpan, gap: Double, preceding: Bool)] = []
        for track in contextTracks {
            for range in utterances(track.tokens) {
                let before = track.tokens[range].filter { $0.end + track.timelineOffsetSeconds <= start }
                let after = track.tokens[range].filter { $0.start + track.timelineOffsetSeconds >= end }
                let nearby = before.isEmpty ? after : before
                guard let first = nearby.first?.start, let last = nearby.last?.end else { continue }
                let meetingStart = first + track.timelineOffsetSeconds
                let meetingEnd = last + track.timelineOffsetSeconds
                let preceding = meetingEnd <= start
                let gap = preceding ? start - meetingEnd : meetingStart - end
                guard gap >= 0, gap <= maxCrossTrackGap, last > first else { continue }
                candidates.append((ContextSpan(fileURL: track.fileURL, start: first, end: last), gap, preceding))
            }
        }
        candidates.sort {
            if $0.preceding != $1.preceding { return $0.preceding }
            return $0.gap < $1.gap
        }
        var spans: [ContextSpan] = []
        var remaining = maxContextSeconds
        for candidate in candidates {
            guard remaining > 0.2 else { break }
            let take = min(candidate.span.end - candidate.span.start, remaining)
            guard take > 0.2 else { continue }
            var span = candidate.span
            if candidate.preceding { span.start = span.end - take } else { span.end = span.start + take }
            spans.append(span)
            remaining -= take
        }
        return spans
    }

    /// Token index ranges separated by at least `isolationGap` seconds.
    static func utterances(_ tokens: [ASRToken], gap: Double = isolationGap) -> [Range<Int>] {
        guard !tokens.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        for i in 1..<tokens.count where tokens[i].start - tokens[i - 1].end >= gap {
            ranges.append(start..<i)
            start = i
        }
        ranges.append(start..<tokens.count)
        return ranges
    }

    static func isShort(_ range: Range<Int>, in tokens: [ASRToken]) -> Bool {
        let duration = tokens[range.upperBound - 1].end - tokens[range.lowerBound].start
        let words = tokens[range].filter { WordGrouping.startsWord($0.piece) }.count
        return duration <= maxUtteranceSeconds && max(1, words) <= maxUtteranceWords
    }

    static func needsContext(_ range: Range<Int>, in tokens: [ASRToken]) -> Bool {
        if isShort(range, in: tokens) { return true }
        let duration = tokens[range.upperBound - 1].end - tokens[range.lowerBound].start
        let words = tokens[range].filter { WordGrouping.startsWord($0.piece) }.count
        // A misdecoded short reply can expand into many foreign words. Include
        // low-confidence replies beyond the usual six-word limit, within a bound.
        return duration <= 6 && words <= 16 && meanConfidence(tokens[range]) < 0.7
    }

    /// Other utterances of the track to use as context, nearest first (earlier before later), up to `maxSeconds`.
    static func contextSpans(for index: Int, in ranges: [Range<Int>], tokens: [ASRToken],
                             maxSeconds: Double = maxContextSeconds) -> [(start: Double, end: Double)] {
        let order = ranges.indices.filter { $0 != index }
            .sorted { abs($0 - index) != abs($1 - index) ? abs($0 - index) < abs($1 - index) : $0 < $1 }
        var spans: [(start: Double, end: Double)] = []
        var total = 0.0
        for i in order {
            guard maxSeconds - total > 0.2 else { break }
            let start = tokens[ranges[i].lowerBound].start, end = tokens[ranges[i].upperBound - 1].end
            let take = min(end - start, maxSeconds - total)
            guard take > 0.2 else { continue }
            // Keep the part of a long neighbour closest to the utterance.
            spans.append(i < index ? (end - take, end) : (start, start + take))
            total += take
        }
        return spans.sorted { $0.start < $1.start }
    }

    static func meanConfidence(_ tokens: some Collection<ASRToken>) -> Float {
        tokens.isEmpty ? 0 : tokens.map(\.confidence).reduce(0, +) / Float(tokens.count)
    }

    /// Re-decodes every short isolated utterance with context; returns the final tokens and how many changed.
    static func redecode(tokens: [ASRToken], fileURL: URL, manager: AsrManager,
                         language: Language?, timelineOffsetSeconds: Double = 0,
                         contextTracks: [ASRContextTrack] = []) async throws -> (tokens: [ASRToken], replaced: Int) {
        let ranges = utterances(tokens)
        guard !ranges.isEmpty, ranges.count > 1 || !contextTracks.isEmpty else { return (tokens, 0) }
        let file = try AVAudioFile(forReading: fileURL)
        let converter = AudioConverter()
        var output: [ASRToken] = []
        var replaced = 0
        for (index, range) in ranges.enumerated() {
            let original = Array(tokens[range])
            guard needsContext(range, in: tokens) else { output += original; continue }
            try Task.checkCancellation()
            var context: [Float] = []
            for span in contextSpans(for: index, in: ranges, tokens: tokens) {
                context += try AudioSlice.samples(of: file, from: span.start - 0.2, to: span.end + 0.2, converter: converter)
                context += silence(0.3)
            }
            if context.isEmpty {
                // Other voices are a recovery aid for uncertain replies, not a
                // reason to rewrite a confident isolated phrase (including English).
                guard meanConfidence(original) < 0.7 else { output += original; continue }
                let spans = remoteSpans(start: original[0].start + timelineOffsetSeconds,
                                        end: original[original.count - 1].end + timelineOffsetSeconds,
                                        contextTracks: contextTracks)
                for span in spans {
                    let remote = try AVAudioFile(forReading: span.fileURL)
                    context += try AudioSlice.samples(of: remote, from: span.start, to: span.end, converter: converter)
                    context += silence(0.3)
                }
            }
            guard !context.isEmpty else { output += original; continue }
            let sliceStart = max(0, original[0].start - 0.3)
            let phrase = try AudioSlice.samples(of: file, from: sliceStart, to: original[original.count - 1].end + 0.3,
                                                converter: converter)
            let prefix = context + silence(0.6)
            let offset = Double(prefix.count) / sampleRate
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(prefix + phrase, decoderState: &state, language: language)
            // Token onsets can precede the acoustic boundary. The 0.9 s silence
            // between context and phrase leaves a safe midpoint for extraction;
            // a tighter cut can drop the first piece ("Listo" → "isto").
            let candidate = (result.tokenTimings ?? []).filter { $0.startTime >= offset - 0.45 }.map {
                ASRToken(piece: $0.token, tokenId: $0.tokenId, start: max(sliceStart, $0.startTime - offset + sliceStart),
                         end: max(sliceStart, $0.endTime - offset + sliceStart), confidence: $0.confidence)
            }
            if !candidate.isEmpty, meanConfidence(candidate) >= meanConfidence(original) {
                output += candidate
                if candidate.map(\.piece) != original.map(\.piece) { replaced += 1 }
            } else {
                output += original
            }
        }
        return (output, replaced)
    }

    private static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }
}

/// 16 kHz mono samples of part of an audio file (memory stays proportional to the slice).
enum AudioSlice {
    static func samples(of file: AVAudioFile, from start: Double, to end: Double,
                        converter: AudioConverter) throws -> [Float] {
        let rate = file.processingFormat.sampleRate
        let first = AVAudioFramePosition(max(0, start) * rate)
        guard first < file.length else { return [] }
        let count = AVAudioFrameCount(max(0, min(Double(file.length - first), (end - max(0, start)) * rate)))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return [] }
        file.framePosition = first
        try file.read(into: buffer, frameCount: count)
        return try converter.resampleBuffer(buffer)
    }
}
