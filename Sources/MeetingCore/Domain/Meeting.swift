public import Foundation
public import GRDB

/// How a meeting entered the library.
public enum MeetingOrigin: String, Codable, Sendable, CaseIterable {
    case recording
    case imported
}

/// What the remote track actually contains. Shown in the UI so the user always
/// knows whether audio was limited to Teams or captured system-wide.
public enum CaptureScope: String, Codable, Sendable, CaseIterable {
    /// Core Audio process tap limited to Microsoft Teams processes (recordings before v2).
    case teamsProcesses
    /// Core Audio process tap limited to the processes of one chosen app (any conversation app).
    case applicationProcesses
    /// Process tap of every process except this app (Teams not isolatable).
    case systemWide
    /// Only the local microphone was recorded.
    case microphoneOnly
    /// Audio came from an imported file.
    case importedFile
}

public enum MeetingStatus: String, Codable, Sendable, CaseIterable {
    /// Capture in progress.
    case recording
    /// Audio saved; not processed yet.
    case recorded
    /// The app stopped unexpectedly while recording; audio was recovered.
    case interrupted
    /// Pipeline running (transcription / diarization / recognition).
    case processing
    /// Final transcript available.
    case ready
    /// Last processing attempt failed; audio is intact.
    case failed
}

public struct Meeting: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var durationSeconds: Double
    public var origin: MeetingOrigin
    public var captureScope: CaptureScope
    public var status: MeetingStatus
    /// BCP-47 tag of the primary spoken language (default `es-CO`).
    public var language: String
    public var notes: String?
    public var lastError: String?
    public var updatedAt: Date
    /// App whose audio was recorded (bundle ID + display name), when known.
    public var sourceAppBundleID: String?
    public var sourceAppName: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationSeconds: Double = 0,
        origin: MeetingOrigin,
        captureScope: CaptureScope,
        status: MeetingStatus,
        language: String = "es-CO",
        notes: String? = nil,
        lastError: String? = nil,
        updatedAt: Date = Date(),
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.origin = origin
        self.captureScope = captureScope
        self.status = status
        self.language = language
        self.notes = notes
        self.lastError = lastError
        self.updatedAt = updatedAt
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
    }

    /// Human description of what the remote track captured.
    public var captureSourceDescription: String {
        switch captureScope {
        case .teamsProcesses: "Microsoft Teams"
        case .applicationProcesses: sourceAppName ?? "Aplicación"
        case .systemWide: "Todo el sistema"
        case .microphoneOnly: "Solo micrófono"
        case .importedFile: "Importada"
        }
    }

    /// The date shown to the user: when the meeting happened, or when it was imported.
    public var displayDate: Date { startedAt ?? createdAt }
}

extension Meeting: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting"
    public static let tracks = hasMany(AudioTrack.self)
    public static let transcripts = hasMany(Transcript.self)
    public static let segments = hasMany(TranscriptSegment.self)
}
