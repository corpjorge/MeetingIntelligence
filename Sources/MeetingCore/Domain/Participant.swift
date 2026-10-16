public import Foundation
public import GRDB

/// A person known to the library. Participants exist independently of voice
/// profiles: a name can be assigned manually without any biometric data.
public struct Participant: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var displayName: String
    public var email: String?
    public var role: String?
    public var notes: String?
    /// The person who owns this Mac (maps the microphone track).
    public var isLocalUser: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        email: String? = nil,
        role: String? = nil,
        notes: String? = nil,
        isLocalUser: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.role = role
        self.notes = notes
        self.isLocalUser = isLocalUser
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Participant: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "participant"
    public static let profile = hasOne(SpeakerProfile.self)
}

public enum ProfileStatus: String, Codable, Sendable {
    case active
    /// Consent revoked: embeddings deleted, profile kept only as an audit stub.
    case revoked
}

/// Biometric voice profile. Created only with explicit, recorded consent.
/// Embeddings live in `VoiceSample` rows, encrypted at rest.
public struct SpeakerProfile: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var participantId: String
    public var consentStatement: String
    public var consentRecordedAt: Date
    public var status: ProfileStatus
    /// Automatic deletion after N days without use (nil = keep until deleted).
    public var retentionDays: Int?
    public var lastMatchedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        participantId: String,
        consentStatement: String,
        consentRecordedAt: Date = Date(),
        status: ProfileStatus = .active,
        retentionDays: Int? = nil,
        lastMatchedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.participantId = participantId
        self.consentStatement = consentStatement
        self.consentRecordedAt = consentRecordedAt
        self.status = status
        self.retentionDays = retentionDays
        self.lastMatchedAt = lastMatchedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension SpeakerProfile: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speakerProfile"
    public static let participant = belongsTo(Participant.self)
    public static let samples = hasMany(VoiceSample.self)
}

public enum VoiceSampleOrigin: String, Codable, Sendable {
    /// Recorded in the enrollment flow with the person's consent.
    case enrollment
    /// Taken from a meeting segment and explicitly validated by the user.
    case validatedMeetingSegment
}

public struct VoiceSample: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var profileId: String
    public var origin: VoiceSampleOrigin
    public var meetingId: String?
    public var startTime: Double?
    public var endTime: Double?
    public var durationSeconds: Double
    /// AES-GCM sealed `[Float]` speaker embedding.
    public var embeddingCiphertext: Data
    /// Embedding model provenance; samples from different models are never compared.
    public var embeddingModel: String
    public var validatedAt: Date
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        profileId: String,
        origin: VoiceSampleOrigin,
        meetingId: String? = nil,
        startTime: Double? = nil,
        endTime: Double? = nil,
        durationSeconds: Double,
        embeddingCiphertext: Data,
        embeddingModel: String,
        validatedAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.profileId = profileId
        self.origin = origin
        self.meetingId = meetingId
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = durationSeconds
        self.embeddingCiphertext = embeddingCiphertext
        self.embeddingModel = embeddingModel
        self.validatedAt = validatedAt
        self.createdAt = createdAt
    }
}

extension VoiceSample: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "voiceSample"
}

/// A diarization cluster inside one meeting ("Hablante 1" on the remote track).
public struct MeetingSpeaker: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var meetingId: String
    public var source: AudioSource
    /// Stable cluster key emitted by the diarizer, e.g. `S1`.
    public var clusterKey: String
    /// Ordinal used for the default label ("Hablante 1").
    public var ordinal: Int
    public var totalSpeechSeconds: Double
    /// Encrypted mean embedding of the cluster (biometric; never exported).
    public var embeddingCiphertext: Data?
    public var embeddingModel: String?
    /// Current resolved identity (nil = unknown participant).
    public var participantId: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        meetingId: String,
        source: AudioSource,
        clusterKey: String,
        ordinal: Int,
        totalSpeechSeconds: Double,
        embeddingCiphertext: Data? = nil,
        embeddingModel: String? = nil,
        participantId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.source = source
        self.clusterKey = clusterKey
        self.ordinal = ordinal
        self.totalSpeechSeconds = totalSpeechSeconds
        self.embeddingCiphertext = embeddingCiphertext
        self.embeddingModel = embeddingModel
        self.participantId = participantId
        self.createdAt = createdAt
    }

    public var defaultLabel: String {
        switch source {
        case .localMicrophone: "Local \(ordinal)"
        default: "Hablante \(ordinal)"
        }
    }
}

extension MeetingSpeaker: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meetingSpeaker"
}

public enum AssignmentMethod: String, Codable, Sendable {
    case localUserTrack
    case automaticRecognition
    case manual
    case merge
    case split
}

public enum AssignmentDecision: String, Codable, Sendable {
    /// Identity applied to the transcript.
    case accepted
    /// Candidate below the acceptance criteria; not applied.
    case suggested
    /// Candidate explicitly rejected by the user.
    case rejected
    /// No candidate qualified: "Participante desconocido".
    case unknown
}

/// Immutable audit log of every identity decision for a meeting speaker,
/// including automatic matches (with scores) and manual corrections.
public struct SpeakerAssignment: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var meetingId: String
    public var meetingSpeakerId: String
    public var participantId: String?
    public var method: AssignmentMethod
    public var decision: AssignmentDecision
    public var similarity: Double?
    public var margin: Double?
    public var threshold: Double?
    public var note: String?
    public var createdAt: Date
    public var supersededAt: Date?

    public init(
        id: String = UUID().uuidString,
        meetingId: String,
        meetingSpeakerId: String,
        participantId: String?,
        method: AssignmentMethod,
        decision: AssignmentDecision,
        similarity: Double? = nil,
        margin: Double? = nil,
        threshold: Double? = nil,
        note: String? = nil,
        createdAt: Date = Date(),
        supersededAt: Date? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.meetingSpeakerId = meetingSpeakerId
        self.participantId = participantId
        self.method = method
        self.decision = decision
        self.similarity = similarity
        self.margin = margin
        self.threshold = threshold
        self.note = note
        self.createdAt = createdAt
        self.supersededAt = supersededAt
    }
}

extension SpeakerAssignment: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speakerAssignment"
}
