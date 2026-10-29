public import GRDB

/// One silent video master on the same timeline as the meeting's audio tracks.
public struct VideoAsset: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "videoAsset"
    public enum State: String, Codable, Sendable { case recording, ready, interrupted, failed }
    public var id: String { meetingId }
    public var meetingId: String
    public var relativePath: String
    public var windowTitle: String
    public var applicationName: String
    public var width: Int
    public var height: Int
    public var durationSeconds: Double
    public var fileSizeBytes: Int64
    public var state: State

    public init(meetingId: String, relativePath: String, windowTitle: String, applicationName: String,
                width: Int, height: Int, durationSeconds: Double = 0, fileSizeBytes: Int64 = 0, state: State = .recording) {
        self.meetingId = meetingId; self.relativePath = relativePath
        self.windowTitle = windowTitle; self.applicationName = applicationName
        self.width = width; self.height = height; self.durationSeconds = durationSeconds
        self.fileSizeBytes = fileSizeBytes; self.state = state
    }
}

extension AppDatabase {
    public func video(meetingId: String) throws -> VideoAsset? {
        try reader.read { try VideoAsset.fetchOne($0, key: meetingId) }
    }

    public func save(video: VideoAsset) throws {
        try writer.write { try video.save($0) }
    }

    public func unfinishedVideos() throws -> [VideoAsset] {
        try reader.read { try VideoAsset.filter(Column("state") == VideoAsset.State.recording.rawValue).fetchAll($0) }
    }
}
