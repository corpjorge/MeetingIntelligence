import CoreAudio
import Foundation
import OSLog

/// Audio activity of one application at one instant (input from the HAL).
public struct AppAudioActivity: Sendable, Hashable, Identifiable {
    public var id: String { app.groupKey }
    public var app: AudioAppSelector
    public var kind: ConversationAppKind
    public var isolation: CaptureIsolation
    public var bundlePath: String?
    public var usingInput: Bool
    public var usingOutput: Bool

    public init(app: AudioAppSelector, kind: ConversationAppKind, isolation: CaptureIsolation, bundlePath: String?,
                usingInput: Bool, usingOutput: Bool) {
        self.app = app
        self.kind = kind
        self.isolation = isolation
        self.bundlePath = bundlePath
        self.usingInput = usingInput
        self.usingOutput = usingOutput
    }

    public init(_ application: AudioApplication) {
        self.init(app: application.selector, kind: application.kind, isolation: application.isolation,
                  bundlePath: application.bundlePath, usingInput: application.isUsingInput,
                  usingOutput: application.isUsingOutput)
    }
}

public enum CallEvent: Sendable, Equatable {
    /// An app has used the microphone *and* played audio for `startDebounce`.
    case callStarted(AppAudioActivity)
    case callEnded(AudioAppSelector, CallEndReason)
}

public enum CallEndReason: String, Sendable, Equatable {
    /// The app released the microphone for longer than `endDebounce`.
    case microphoneReleased
    /// The app stopped being an audio client (usually it quit).
    case appClosed
}

/// Pure state machine turning activity snapshots into call start/end events.
///
/// Rules (any app, no fixed list):
/// * **Start:** the same app uses the microphone and plays audio continuously
///   for `startDebounce` seconds (filters device tests and short dictation).
/// * **End:** the app released the microphone for `endDebounce` seconds
///   (survives AirPods/Bluetooth route changes, which release it briefly), or
///   it disappeared from the audio system for `closeDebounce` seconds.
/// * System processes are ignored unless the catalog marks them as
///   conversation software (e.g. FaceTime); ignored apps never trigger events.
///
/// The detector only *suggests*; it never starts or stops a recording.
public struct CallDetector: Sendable {
    public var startDebounce: Double = 3
    public var endDebounce: Double = 25
    public var closeDebounce: Double = 3
    public var ignoredAppIDs: Set<String> = []

    private struct Track {
        var candidateSince: Double?
        var inCall = false
        var activity: AppAudioActivity
        var releasedSince: Double?
        var missingSince: Double?
    }

    private var tracks: [String: Track] = [:]

    public init() {}

    public var activeCalls: [AppAudioActivity] {
        tracks.values.filter(\.inCall).map(\.activity).sorted { $0.app.name < $1.app.name }
    }

    func isEligible(_ activity: AppAudioActivity) -> Bool {
        guard !ignoredAppIDs.contains(activity.app.groupKey) else { return false }
        if activity.kind == .system {
            return ConversationAppCatalog.entry(forBundleID: activity.app.bundleIdentifier)?.kind == .system
        }
        return true
    }

    public mutating func update(_ snapshot: [AppAudioActivity], now: Double) -> [CallEvent] {
        var events: [CallEvent] = []
        let present = Dictionary(snapshot.filter(isEligible).map { ($0.app.groupKey, $0) }, uniquingKeysWith: { a, _ in a })

        for (key, activity) in present {
            var track = tracks[key] ?? Track(activity: activity)
            track.activity = activity
            track.missingSince = nil
            let candidate = activity.usingInput && activity.usingOutput
            if track.inCall {
                if activity.usingInput {
                    track.releasedSince = nil
                } else {
                    track.releasedSince = track.releasedSince ?? now
                    if now - track.releasedSince! >= endDebounce {
                        track.inCall = false
                        track.releasedSince = nil
                        track.candidateSince = nil
                        events.append(.callEnded(activity.app, .microphoneReleased))
                    }
                }
            } else if candidate {
                track.candidateSince = track.candidateSince ?? now
                if now - track.candidateSince! >= startDebounce {
                    track.inCall = true
                    track.releasedSince = nil
                    events.append(.callStarted(activity))
                }
            } else {
                track.candidateSince = nil
            }
            tracks[key] = track
        }

        for (key, var track) in tracks where present[key] == nil {
            track.missingSince = track.missingSince ?? now
            if now - track.missingSince! >= closeDebounce {
                if track.inCall { events.append(.callEnded(track.activity.app, .appClosed)) }
                tracks[key] = nil
            } else {
                tracks[key] = track
            }
        }
        return events
    }
}

/// Feeds `CallDetector` from the Core Audio HAL (1 s polling of process
/// input/output flags + process-list notifications). Needs no permission.
public final class CallMonitor: @unchecked Sendable {
    public let events: AsyncStream<CallEvent>
    /// Latest activity of every app that is an audio client (for source pickers).
    public let snapshots: AsyncStream<[AppAudioActivity]>

    private let eventContinuation: AsyncStream<CallEvent>.Continuation
    private let snapshotContinuation: AsyncStream<[AppAudioActivity]>.Continuation
    private let queue = DispatchQueue(label: "mi.call-monitor", qos: .utility)
    private var detector = CallDetector()
    private var timer: (any DispatchSourceTimer)?
    private var listener: HALPropertyListener?
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "call-monitor")

    public init() {
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
        (snapshots, snapshotContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func start(ignoredAppIDs: Set<String> = []) {
        queue.async { [self] in
            guard timer == nil else { return }
            detector.ignoredAppIDs = ignoredAppIDs
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            listener = HALPropertyListener(object: HAL.systemObject, selector: kAudioHardwarePropertyProcessObjectList,
                                           queue: queue) { [weak self] in
                guard let self else { return }
                self.queue.async { self.tick() }
            }
            logger.info("Call monitor started")
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            listener?.invalidate()
            listener = nil
        }
    }

    public func setIgnoredApps(_ ids: Set<String>) {
        queue.async { [self] in detector.ignoredAppIDs = ids }
    }

    private func tick() {
        let snapshot = AudioApplicationResolver.currentApplications().map(AppAudioActivity.init)
        snapshotContinuation.yield(snapshot)
        for event in detector.update(snapshot, now: HAL.nowSeconds()) {
            eventContinuation.yield(event)
        }
    }

    deinit {
        timer?.cancel()
        listener?.invalidate()
    }
}
