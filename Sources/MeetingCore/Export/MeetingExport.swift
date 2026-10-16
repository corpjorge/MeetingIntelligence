public import Foundation
import GRDB

/// Complete, lossless snapshot of a meeting for export (JSON is its direct encoding).
/// Biometric data (embeddings) is never included.
public struct MeetingExportDocument: Codable, Sendable {
    public static let schemaVersion = 1

    public struct TrackInfo: Codable, Sendable {
        public var id: String
        public var source: String
        public var file: String
        public var originalFileName: String?
        public var durationSeconds: Double
        public var sampleRate: Double
        public var channels: Int
        public var timelineOffsetSeconds: Double
        public var device: String?
        public var captureDetail: String?
    }

    public struct TranscriptInfo: Codable, Sendable {
        public var id: String
        public var trackId: String
        public var engine: String
        public var model: String
        public var language: String
        public var createdAt: Date
        public var processingSeconds: Double
        public var meanConfidence: Double?
    }

    public struct ParticipantInfo: Codable, Sendable {
        public var id: String
        public var name: String
        public var email: String?
        public var role: String?
        public var isLocalUser: Bool
    }

    public struct SpeakerInfo: Codable, Sendable {
        public var id: String
        public var source: String
        public var label: String
        public var clusterKey: String
        public var speechSeconds: Double
        public var participantId: String?
        public var participantName: String?
        public var identification: [IdentificationInfo]
    }

    public struct IdentificationInfo: Codable, Sendable {
        public var method: String
        public var decision: String
        public var participantId: String?
        public var similarity: Double?
        public var margin: Double?
        public var threshold: Double?
        public var note: String?
        public var createdAt: Date
        public var superseded: Bool
    }

    public struct SegmentInfo: Codable, Sendable {
        public var id: String
        public var meetingId: String
        public var start: Double
        public var end: Double
        public var source: String
        public var speakerId: String?
        public var speakerName: String
        public var participantId: String?
        public var speakerConfidence: Double?
        public var attribution: String
        /// Text shown to the user (edited > vocabulary > ASR).
        public var text: String
        public var textOrigin: String
        public var asrText: String
        public var vocabularyText: String?
        public var editedText: String?
        public var asrConfidence: Double?
        public var words: [WordTiming]?
    }

    public struct AnalysisInfo: Codable, Sendable {
        public var id: String
        public var provider: String
        public var model: String?
        public var promptVersion: String
        public var status: String
        public var startedAt: Date
        public var durationSeconds: Double?
        public var sharedContent: String
        public var executiveSummary: String?
        public var technicalSummary: String?
        public var items: [ItemInfo]
    }

    public struct ItemInfo: Codable, Sendable {
        public var id: String
        public var category: String
        public var nature: String
        public var text: String
        public var owner: String?
        public var due: String?
        public var evidence: EvidenceInfo?
        public var evidenceStatus: String
        public var completedAt: Date?
    }

    public struct EvidenceInfo: Codable, Sendable {
        public var segmentId: String?
        public var quote: String?
        public var start: Double?
        public var timestamp: String?
        public var speaker: String?
    }

    public var schemaVersion: Int = MeetingExportDocument.schemaVersion
    public var exportedAt: Date
    public var application: String
    public var meeting: Meeting
    public var tracks: [TrackInfo]
    public var transcripts: [TranscriptInfo]
    public var participants: [ParticipantInfo]
    public var speakers: [SpeakerInfo]
    public var segments: [SegmentInfo]
    public var analyses: [AnalysisInfo]
    public var corrections: [CorrectionEvent]
}

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case txt, markdown, json, srt, pdf

    public var id: String { rawValue }
    public var fileExtension: String {
        switch self {
        case .txt: "txt"
        case .markdown: "md"
        case .json: "json"
        case .srt: "srt"
        case .pdf: "pdf"
        }
    }
    public var displayName: String {
        switch self {
        case .txt: "Texto (.txt)"
        case .markdown: "Markdown (.md)"
        case .json: "JSON completo (.json)"
        case .srt: "Subtítulos (.srt)"
        case .pdf: "PDF (.pdf)"
        }
    }
}

public struct MeetingExporter: Sendable {
    public let database: AppDatabase
    public var includeWordTimings = true
    /// Segments flagged as probable echo are excluded from text formats (always kept in JSON).
    public var includeProbableEcho = false

    public init(database: AppDatabase) {
        self.database = database
    }

    public func document(meetingId: String) throws -> MeetingExportDocument {
        guard let detail = try database.meetingDetail(id: meetingId) else {
            throw AppDatabaseError.notFound("reunión \(meetingId)")
        }
        let (assignments, analyses, items, corrections, allParticipants) = try database.reader.read { db in
            (try SpeakerAssignment.filter(Column("meetingId") == meetingId).order(Column("createdAt")).fetchAll(db),
             try AIAnalysis.filter(Column("meetingId") == meetingId).order(Column("startedAt")).fetchAll(db),
             try AnalysisItem.filter(Column("meetingId") == meetingId).order(Column("orderIndex")).fetchAll(db),
             try CorrectionEvent.filter(Column("meetingId") == meetingId).order(Column("createdAt")).fetchAll(db),
             try Participant.fetchAll(db))
        }
        let participantsByID = Dictionary(uniqueKeysWithValues: allParticipants.map { ($0.id, $0) })
        let referenced = Set(detail.segments.compactMap(\.participantId) + detail.speakers.compactMap(\.participantId)
                             + items.compactMap(\.ownerParticipantId))
        return MeetingExportDocument(
            exportedAt: Date(),
            application: "\(AppIdentity.displayName) \(AppIdentity.version)",
            meeting: detail.meeting,
            tracks: detail.tracks.map {
                .init(id: $0.id, source: $0.source.rawValue, file: $0.relativePath, originalFileName: $0.originalFileName,
                      durationSeconds: $0.durationSeconds, sampleRate: $0.sampleRate, channels: $0.channelCount,
                      timelineOffsetSeconds: $0.timelineOffsetSeconds, device: $0.deviceName, captureDetail: $0.captureDetail)
            },
            transcripts: detail.transcripts.filter { $0.supersededAt == nil }.map {
                .init(id: $0.id, trackId: $0.trackId, engine: $0.engine, model: $0.modelIdentifier, language: $0.language,
                      createdAt: $0.createdAt, processingSeconds: $0.processingSeconds, meanConfidence: $0.meanConfidence)
            },
            participants: referenced.compactMap { participantsByID[$0] }.sorted { $0.displayName < $1.displayName }.map {
                .init(id: $0.id, name: $0.displayName, email: $0.email, role: $0.role, isLocalUser: $0.isLocalUser)
            },
            speakers: detail.speakers.map { s in
                .init(id: s.id, source: s.source.rawValue, label: s.defaultLabel, clusterKey: s.clusterKey,
                      speechSeconds: s.totalSpeechSeconds, participantId: s.participantId,
                      participantName: s.participantId.flatMap { participantsByID[$0]?.displayName },
                      identification: assignments.filter { $0.meetingSpeakerId == s.id }.map {
                          .init(method: $0.method.rawValue, decision: $0.decision.rawValue, participantId: $0.participantId,
                                similarity: $0.similarity, margin: $0.margin, threshold: $0.threshold, note: $0.note,
                                createdAt: $0.createdAt, superseded: $0.supersededAt != nil)
                      })
            },
            segments: detail.segments.map { seg in
                .init(id: seg.id, meetingId: seg.meetingId, start: seg.startTime, end: seg.endTime, source: seg.source.rawValue,
                      speakerId: seg.meetingSpeakerId, speakerName: detail.speakerName(for: seg),
                      participantId: seg.participantId, speakerConfidence: seg.speakerConfidence,
                      attribution: seg.attribution.rawValue, text: seg.displayText, textOrigin: seg.textOrigin.rawValue,
                      asrText: seg.asrText, vocabularyText: seg.vocabularyText, editedText: seg.editedText,
                      asrConfidence: seg.asrConfidence, words: includeWordTimings ? seg.words : nil)
            },
            analyses: analyses.map { a in
                .init(id: a.id, provider: a.provider.rawValue, model: a.model, promptVersion: a.promptVersion,
                      status: a.status.rawValue, startedAt: a.startedAt, durationSeconds: a.durationSeconds,
                      sharedContent: a.sharedContentSummary, executiveSummary: a.executiveSummary,
                      technicalSummary: a.technicalSummary,
                      items: items.filter { $0.analysisId == a.id }.map { i in
                          .init(id: i.id, category: i.category.rawValue, nature: i.nature.rawValue, text: i.text,
                                owner: i.ownerName, due: i.dueText,
                                evidence: (i.evidenceSegmentId == nil && i.evidenceQuote == nil) ? nil : .init(
                                    segmentId: i.evidenceSegmentId, quote: i.evidenceQuote, start: i.evidenceStartTime,
                                    timestamp: i.evidenceStartTime.map(Timecode.hms), speaker: i.evidenceSpeakerName),
                                evidenceStatus: i.evidenceStatus.rawValue, completedAt: i.completedAt)
                      })
            },
            corrections: corrections)
    }

    public func data(meetingId: String, format: ExportFormat) throws -> Data {
        let doc = try document(meetingId: meetingId)
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(doc)
        case .txt: return Data(plainText(doc).utf8)
        case .markdown: return Data(markdown(doc).utf8)
        case .srt: return Data(srt(doc).utf8)
        case .pdf: return try PDFRenderer.render(document: doc, segments: textSegments(doc))
        }
    }

    @discardableResult
    public func export(meetingId: String, format: ExportFormat, to url: URL) throws -> URL {
        let data = try data(meetingId: meetingId, format: format)
        try data.write(to: url, options: [.atomic])
        return url
    }

    public static func suggestedFileName(for meeting: Meeting, format: ExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let safeTitle = meeting.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        return "\(formatter.string(from: meeting.displayDate)) \(safeTitle).\(format.fileExtension)"
    }

    // MARK: Text formats

    func textSegments(_ doc: MeetingExportDocument) -> [MeetingExportDocument.SegmentInfo] {
        doc.segments.filter { includeProbableEcho || $0.attribution != AttributionStatus.probableEcho.rawValue }
    }

    private static func marker(_ seg: MeetingExportDocument.SegmentInfo) -> String {
        switch seg.attribution {
        case AttributionStatus.uncertain.rawValue: " (atribución incierta)"
        case AttributionStatus.probableEcho.rawValue: " (eco probable)"
        default: ""
        }
    }

    private func header(_ doc: MeetingExportDocument) -> [String] {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_CO")
        df.dateStyle = .long
        df.timeStyle = .short
        var lines = ["Fecha: \(df.string(from: doc.meeting.displayDate))",
                     "Duración: \(Timecode.humanDuration(doc.meeting.durationSeconds))"]
        if !doc.participants.isEmpty {
            lines.append("Participantes identificados: \(doc.participants.map(\.name).joined(separator: ", "))")
        }
        if let t = doc.transcripts.first { lines.append("Transcripción: \(t.model)") }
        return lines
    }

    func plainText(_ doc: MeetingExportDocument) -> String {
        var out = [doc.meeting.title, String(repeating: "=", count: doc.meeting.title.count)] + header(doc) + [""]
        for seg in textSegments(doc) {
            out.append("[\(Timecode.hms(seg.start))] \(seg.speakerName)\(Self.marker(seg)): \(seg.text)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    func markdown(_ doc: MeetingExportDocument) -> String {
        var out = ["# \(doc.meeting.title)", ""] + header(doc).map { "- \($0)" } + [""]
        if let analysis = doc.analyses.last(where: { $0.status == AnalysisStatus.succeeded.rawValue }) {
            if let summary = analysis.executiveSummary {
                out += ["## Resumen ejecutivo", "", "> Generado por IA (\(analysis.provider)\(analysis.model.map { " · \($0)" } ?? "")).", "", summary, ""]
            }
            let grouped = Dictionary(grouping: analysis.items, by: \.category)
            for category in AnalysisCategory.allCases {
                guard let items = grouped[category.rawValue], !items.isEmpty else { continue }
                out += ["## \(category.displayName)", ""]
                for item in items {
                    var line = "- \(item.text)"
                    if let owner = item.owner { line += " — **\(owner)**" }
                    if let due = item.due { line += " (\(due))" }
                    if let e = item.evidence, let ts = e.timestamp {
                        line += " · [\(ts)] \(e.speaker ?? "")"
                        if let q = e.quote { line += ": “\(q)”" }
                    }
                    if item.evidenceStatus == EvidenceStatus.unconfirmed.rawValue { line += " · _Información no confirmada_" }
                    if item.nature != StatementNature.fact.rawValue { line += " · _\(item.nature == "recommendation" ? "Recomendación de la IA" : "Interpretación de la IA")_" }
                    out.append(line)
                }
                out.append("")
            }
        }
        out += ["## Transcripción", ""]
        for seg in textSegments(doc) {
            out.append("**[\(Timecode.hms(seg.start))] \(seg.speakerName)**\(Self.marker(seg)): \(seg.text)  ")
        }
        return out.joined(separator: "\n") + "\n"
    }

    func srt(_ doc: MeetingExportDocument) -> String {
        textSegments(doc).enumerated().map { index, seg in
            "\(index + 1)\n\(Timecode.srt(seg.start)) --> \(Timecode.srt(max(seg.end, seg.start + 0.3)))\n\(seg.speakerName): \(seg.text)\n"
        }.joined(separator: "\n")
    }
}
