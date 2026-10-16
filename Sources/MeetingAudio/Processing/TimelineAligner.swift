/// Keeps a track's written sample count locked to the shared host clock.
///
/// Each incoming buffer carries the host time of its first sample. The aligner
/// compares where that buffer *should* start on the meeting timeline with how
/// many frames have been written so far and decides to pad silence (gaps:
/// device switches, dropouts, late start) or drop leading frames (clock drift
/// running ahead). Jitter below `toleranceFrames` is ignored so normal
/// scheduling noise never produces clicks.
public struct TimelineAligner: Sendable {
    public struct Plan: Equatable, Sendable {
        /// Silent frames to write before the buffer.
        public var padFrames: Int
        /// Leading frames of the buffer to discard.
        public var dropFrames: Int
    }

    public let sampleRate: Double
    public let toleranceFrames: Int
    public private(set) var framesWritten: Int = 0
    public private(set) var totalPaddedFrames: Int = 0
    public private(set) var totalDroppedFrames: Int = 0

    public init(sampleRate: Double, toleranceSeconds: Double = 0.04) {
        self.sampleRate = sampleRate
        self.toleranceFrames = max(1, Int(sampleRate * toleranceSeconds))
    }

    /// - Parameters:
    ///   - startSeconds: timeline position of the buffer's first frame, or nil if
    ///     the timestamp is unknown (the buffer is then appended contiguously).
    ///   - frameCount: frames in the (already resampled) buffer.
    public mutating func plan(startSeconds: Double?, frameCount: Int) -> Plan {
        var plan = Plan(padFrames: 0, dropFrames: 0)
        if let startSeconds {
            let expected = Int((max(0, startSeconds) * sampleRate).rounded())
            let delta = expected - framesWritten
            if delta > toleranceFrames {
                plan.padFrames = delta
            } else if delta < -toleranceFrames {
                plan.dropFrames = min(-delta, frameCount)
            }
        }
        framesWritten += plan.padFrames + (frameCount - plan.dropFrames)
        totalPaddedFrames += plan.padFrames
        totalDroppedFrames += plan.dropFrames
        return plan
    }
}
