public import Foundation
public import GRDB

/// Logical audio source. The raw values are part of the on-disk and export
/// contract (`local_microphone`, `remote_system_audio`).
public enum AudioSource: String, Codable, Sendable, CaseIterable {
    case localMicrophone = "local_microphone"
    case remoteSystemAudio = "remote_system_audio"
    case imported = "imported"

    public var fileStem: String { rawValue }
}

public struct AudioTrack: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var meetingId: String
    public var source: AudioSource
    /// Path relative to `AppPaths.root`.
    public var relativePath: String
    public var originalFileName: String?
    public var sampleRate: Double
    public var channelCount: Int
    public var durationSeconds: Double
    /// Offset of this track's first sample on the meeting timeline (seconds).
    /// Both live tracks share one host-clock origin, so offsets are comparable.
    public var timelineOffsetSeconds: Double
    public var deviceName: String?
    /// Human-readable description of what was captured (e.g. tapped processes).
    public var captureDetail: String?
    public var fileSizeBytes: Int64
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        meetingId: String,
        source: AudioSource,
        relativePath: String,
        originalFileName: String? = nil,
        sampleRate: Double,
        channelCount: Int,
        durationSeconds: Double,
        timelineOffsetSeconds: Double = 0,
        deviceName: String? = nil,
        captureDetail: String? = nil,
        fileSizeBytes: Int64 = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.source = source
        self.relativePath = relativePath
        self.originalFileName = originalFileName
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.durationSeconds = durationSeconds
        self.timelineOffsetSeconds = timelineOffsetSeconds
        self.deviceName = deviceName
        self.captureDetail = captureDetail
        self.fileSizeBytes = fileSizeBytes
        self.createdAt = createdAt
    }
}

extension AudioTrack: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "audioTrack"
    public static let meeting = belongsTo(Meeting.self)
}
