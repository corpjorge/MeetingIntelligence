public import Foundation
public import GRDB

public enum ProcessingStage: String, Codable, Sendable, CaseIterable {
    case modelPreparation
    case transcription
    case diarization
    case speakerRecognition
    case alignment
    case analysis

    public var displayName: String {
        switch self {
        case .modelPreparation: "Preparando modelos"
        case .transcription: "Transcripción (Parakeet Ultra)"
        case .diarization: "Diarización"
        case .speakerRecognition: "Reconocimiento de participantes"
        case .alignment: "Alineación"
        case .analysis: "Análisis IA"
        }
    }
}

public enum JobStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
}

/// Persistent record of every processing stage with real timings, used to
/// evaluate performance and to recover after interruptions.
public struct ProcessingJob: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var meetingId: String
    public var trackId: String?
    public var stage: ProcessingStage
    public var status: JobStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var audioSeconds: Double?
    public var wallSeconds: Double?
    /// Peak resident memory sampled during the stage (bytes).
    public var peakMemoryBytes: Int64?
    public var detail: String?
    public var errorMessage: String?

    public init(
        id: String = UUID().uuidString,
        meetingId: String,
        trackId: String? = nil,
        stage: ProcessingStage,
        status: JobStatus = .running,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        audioSeconds: Double? = nil,
        wallSeconds: Double? = nil,
        peakMemoryBytes: Int64? = nil,
        detail: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.trackId = trackId
        self.stage = stage
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.audioSeconds = audioSeconds
        self.wallSeconds = wallSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.detail = detail
        self.errorMessage = errorMessage
    }

    /// Real-time factor: audio duration / processing time.
    public var realTimeFactor: Double? {
        guard let audioSeconds, let wallSeconds, wallSeconds > 0 else { return nil }
        return audioSeconds / wallSeconds
    }
}

extension ProcessingJob: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "processingJob"
}

/// Append-only history of user corrections (text edits, identity changes, merges).
public struct CorrectionEvent: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var meetingId: String?
    public var entityType: String
    public var entityId: String
    public var field: String
    public var previousValue: String?
    public var newValue: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        meetingId: String?,
        entityType: String,
        entityId: String,
        field: String,
        previousValue: String?,
        newValue: String?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.entityType = entityType
        self.entityId = entityId
        self.field = field
        self.previousValue = previousValue
        self.newValue = newValue
        self.createdAt = createdAt
    }
}

extension CorrectionEvent: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "correctionEvent"
}

/// Custom dictionary entry: a canonical spelling plus the variants the ASR
/// tends to produce for it (proper names, technical and financial terms).
public struct VocabularyTerm: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var canonical: String
    /// JSON-encoded `[String]` of misrecognized variants.
    public var variantsJSON: Data
    public var category: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        canonical: String,
        variants: [String],
        category: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.canonical = canonical
        self.variantsJSON = (try? JSONEncoder().encode(variants)) ?? Data("[]".utf8)
        self.category = category
        self.createdAt = createdAt
    }

    public var variants: [String] {
        (try? JSONDecoder().decode([String].self, from: variantsJSON)) ?? []
    }
}

extension VocabularyTerm: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "vocabularyTerm"
}
