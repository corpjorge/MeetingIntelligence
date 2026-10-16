public import Foundation
public import GRDB

public enum PauseReason: String, Codable, Sendable {
    /// The user paused their own microphone during the recording.
    case microphonePausedByUser
}

/// A span of a track that was intentionally not recorded (silence was written
/// to keep tracks aligned). Shown in the Audio tab and exported.
public struct RecordingPause: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var meetingId: String
    public var source: AudioSource
    public var startTime: Double
    public var endTime: Double
    public var reason: PauseReason

    public init(id: String = UUID().uuidString, meetingId: String, source: AudioSource,
                startTime: Double, endTime: Double, reason: PauseReason) {
        self.id = id
        self.meetingId = meetingId
        self.source = source
        self.startTime = startTime
        self.endTime = endTime
        self.reason = reason
    }
}

extension RecordingPause: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "recordingPause"
}
