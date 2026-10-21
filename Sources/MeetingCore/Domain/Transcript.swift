public import Foundation
public import GRDB

/// One ASR run over one audio track. Transcripts are append-only: re-running
/// transcription creates a new transcript and marks the old one as superseded,
/// so original output is never silently overwritten.
public struct Transcript: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var meetingId: String
    public var trackId: String
    /// Engine identifier, e.g. `parakeet-ultra`.
    public var engine: String
    /// Exact model/library provenance, e.g. `FluidInference/parakeet-ultra-coreml (FluidAudio 0.17.7)`.
    public var modelIdentifier: String
    public var language: String
    public var isFinal: Bool
    public var audioDurationSeconds: Double
    public var processingSeconds: Double
    public var meanConfidence: Double?
    public var createdAt: Date
    public var supersededAt: Date?

    public init(
        id: String = UUID().uuidString,
        meetingId: String,
        trackId: String,
        engine: String,
        modelIdentifier: String,
        language: String,
        isFinal: Bool,
        audioDurationSeconds: Double,
        processingSeconds: Double,
        meanConfidence: Double?,
        createdAt: Date = Date(),
        supersededAt: Date? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.trackId = trackId
        self.engine = engine
        self.modelIdentifier = modelIdentifier
        self.language = language
        self.isFinal = isFinal
        self.audioDurationSeconds = audioDurationSeconds
        self.processingSeconds = processingSeconds
        self.meanConfidence = meanConfidence
        self.createdAt = createdAt
        self.supersededAt = supersededAt
    }
}

extension Transcript: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcript"
    public static let segments = hasMany(TranscriptSegment.self)
}

/// Word-level timing reported by the ASR engine (seconds on the meeting timeline).
public struct WordTiming: Codable, Sendable, Hashable {
    public var word: String
    public var start: Double
    public var end: Double
    public var confidence: Double?

    public init(word: String, start: Double, end: Double, confidence: Double? = nil) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// Where the speaker attribution of a segment comes from.
public enum AttributionStatus: String, Codable, Sendable, CaseIterable {
    /// No diarization has run yet.
    case unattributed
    /// Microphone track with a single detected local speaker → local user.
    case localUserTrack
    /// Diarization cluster known, identity unknown ("Participante desconocido").
    case diarized
    /// Identity accepted automatically from a voice profile above calibrated threshold.
    case recognized
    /// A candidate identity exists but confidence was insufficient; shown as unknown.
    case suggested
    /// Identity set or corrected by the user.
    case manual
    /// Overlapping speech or ambiguous attribution.
    case uncertain
    /// Microphone segment that repeats remote speech (speaker echo). Kept, hidden by default.
    case probableEcho
}

public struct TranscriptSegment: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var transcriptId: String
    public var meetingId: String
    public var trackId: String
    public var source: AudioSource
    public var orderIndex: Int
    /// Seconds on the meeting timeline.
    public var startTime: Double
    public var endTime: Double
    /// Raw ASR output. Never modified after insertion.
    public var asrText: String
    /// ASR output after deterministic custom-vocabulary replacements (nil if none applied).
    public var vocabularyText: String?
    /// User correction (nil if never edited).
    public var editedText: String?
    public var editedAt: Date?
    public var asrConfidence: Double?
    public var wordsJSON: Data?
    /// Current speaker (changes with merges / manual moves).
    public var meetingSpeakerId: String?
    /// Speaker originally produced by diarization. Immutable; enables undoing merges.
    public var diarizedSpeakerId: String?
    public var participantId: String?
    public var speakerConfidence: Double?
    public var attribution: AttributionStatus

    public init(
        id: String = UUID().uuidString,
        transcriptId: String,
        meetingId: String,
        trackId: String,
        source: AudioSource,
        orderIndex: Int,
        startTime: Double,
        endTime: Double,
        asrText: String,
        vocabularyText: String? = nil,
        editedText: String? = nil,
        editedAt: Date? = nil,
        asrConfidence: Double? = nil,
        words: [WordTiming]? = nil,
        meetingSpeakerId: String? = nil,
        participantId: String? = nil,
        speakerConfidence: Double? = nil,
        attribution: AttributionStatus = .unattributed
    ) {
        self.id = id
        self.transcriptId = transcriptId
        self.meetingId = meetingId
        self.trackId = trackId
        self.source = source
        self.orderIndex = orderIndex
        self.startTime = startTime
        self.endTime = endTime
        self.asrText = asrText
        self.vocabularyText = vocabularyText
        self.editedText = editedText
        self.editedAt = editedAt
        self.asrConfidence = asrConfidence
        self.wordsJSON = words.flatMap { try? JSONEncoder().encode($0) }
        self.meetingSpeakerId = meetingSpeakerId
        self.diarizedSpeakerId = meetingSpeakerId
        self.participantId = participantId
        self.speakerConfidence = speakerConfidence
        self.attribution = attribution
    }

    /// Text shown to the user: user edit > vocabulary-corrected > raw ASR.
    public var displayText: String { editedText ?? vocabularyText ?? asrText }

    public var textOrigin: TextOrigin {
        if editedText != nil { return .userEdited }
        if vocabularyText != nil { return .vocabularyCorrected }
        return .asr
    }

    public var words: [WordTiming] {
        guard let wordsJSON else { return [] }
        return (try? JSONDecoder().decode([WordTiming].self, from: wordsJSON)) ?? []
    }

    public var duration: Double { max(0, endTime - startTime) }

    /// Mean ASR confidence below which a segment is flagged for review (TD-22: catches 24/59 errors, 4/196 false alarms).
    public static let lowConfidenceThreshold = 0.7

    /// True when the ASR was unsure and the user has not reviewed the text yet.
    public var isLowConfidence: Bool {
        guard editedText == nil, let asrConfidence else { return false }
        return asrConfidence < Self.lowConfidenceThreshold
    }
}

/// Provenance of a piece of transcript text, kept distinct from AI-generated content.
public enum TextOrigin: String, Codable, Sendable {
    case asr
    case vocabularyCorrected
    case userEdited
}

extension TranscriptSegment: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcriptSegment"
    public static let transcript = belongsTo(Transcript.self)
    public static let participant = belongsTo(Participant.self)
    public static let meetingSpeaker = belongsTo(MeetingSpeaker.self, using: ForeignKey(["meetingSpeakerId"]))
}
