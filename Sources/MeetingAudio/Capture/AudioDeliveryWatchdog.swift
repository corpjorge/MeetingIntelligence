import Foundation
import MeetingCore

/// A missing callback is different from quiet samples. Emit state transitions,
/// not repeated alerts, and allow a startup grace period for hardware negotiation.
struct AudioDeliveryWatchdog {
    enum Change: Equatable { case missing, recovered }
    private var missing: Set<AudioSource> = []
    var timeout = 5.0

    mutating func check(source: AudioSource, lastReceivedAt: Double?, startedAt: Double, now: Double) -> Change? {
        guard now - startedAt >= timeout else { return nil }
        let absent = lastReceivedAt.map { now - $0 >= timeout } ?? true
        if absent { return missing.insert(source).inserted ? .missing : nil }
        return missing.remove(source) != nil ? .recovered : nil
    }

    mutating func reset(_ source: AudioSource) {
        missing.remove(source)
    }
}
