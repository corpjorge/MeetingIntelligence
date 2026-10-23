public import Foundation
public import GRDB

/// Local full-text search over transcripts (SQLite FTS5, accent-insensitive).
/// Works without any LLM; every hit carries meeting + timestamp references.
public struct SearchHit: Sendable, Hashable, Identifiable, Codable {
    public var id: String { segmentId }
    public var segmentId: String
    public var meetingId: String
    public var meetingTitle: String
    public var meetingDate: Date
    public var startTime: Double
    public var endTime: Double
    public var speakerName: String
    public var text: String
    /// Snippet with matched terms wrapped in `[` `]`.
    public var snippet: String
    public var rank: Double
}

public enum SearchScope: Sendable, Hashable {
    case allMeetings
    case meetings([String])
}

public struct SearchService: Sendable {
    let reader: any DatabaseReader

    /// Resolved speaker label (participant > diarized speaker > track source).
    static let speakerNameSQL = """
        COALESCE(p.displayName,
                 CASE WHEN ms.id IS NOT NULL THEN
                     (CASE ms.source WHEN 'local_microphone' THEN 'Local ' ELSE 'Hablante ' END) || ms.ordinal
                 ELSE (CASE s.source WHEN 'local_microphone' THEN 'Micrófono local'
                                     WHEN 'remote_system_audio' THEN 'Audio remoto'
                                     ELSE 'Sin identificar' END) END)
        """

    public init(reader: any DatabaseReader) {
        self.reader = reader
    }

    /// - Parameters:
    ///   - query: free text or a natural-language question. Stopwords are dropped
    ///     and remaining terms are matched as prefixes (any term), ranked by BM25.
    ///   - speakerName: optional filter on the resolved participant / speaker label.
    public func search(_ query: String, scope: SearchScope = .allMeetings,
                       speakerName: String? = nil, limit: Int = 50) throws -> [SearchHit] {
        let terms = TextNormalization.searchTerms(from: query)
        guard !terms.isEmpty else { return [] }
        // Prefix match on every term, OR-combined, so "viabilidad inicial" also
        // finds "viabilidades iniciales". BM25 ranks segments matching more terms first.
        let raw = Set(terms.map(TextNormalization.searchStem)).sorted()
            .map { "\"\($0)\"*" }.joined(separator: " OR ")
        let pattern = try FTS5Pattern(rawPattern: raw)

        return try reader.read { db in
            var sql = """
                SELECT s.id AS segmentId, s.meetingId, m.title AS meetingTitle,
                       COALESCE(m.startedAt, m.createdAt) AS meetingDate,
                       s.startTime, s.endTime,
                       COALESCE(s.editedText, s.vocabularyText, s.asrText) AS text,
                       \(Self.speakerNameSQL) AS speakerName,
                       snippet(transcriptSegmentFts, -1, '[', ']', '…', 24) AS snippet,
                       bm25(transcriptSegmentFts) AS rank
                FROM transcriptSegmentFts
                JOIN transcriptSegment s ON s.rowid = transcriptSegmentFts.rowid
                JOIN transcript t ON t.id = s.transcriptId AND t.supersededAt IS NULL
                JOIN meeting m ON m.id = s.meetingId
                LEFT JOIN participant p ON p.id = s.participantId
                LEFT JOIN meetingSpeaker ms ON ms.id = s.meetingSpeakerId
                WHERE transcriptSegmentFts MATCH ?
                """
            var arguments: StatementArguments = [pattern]
            if case .meetings(let ids) = scope {
                guard !ids.isEmpty else { return [] }
                sql += " AND s.meetingId IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
                arguments += StatementArguments(ids)
            }
            sql += " ORDER BY rank LIMIT ?"
            arguments += [limit * 3]

            var hits = try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                SearchHit(segmentId: row["segmentId"], meetingId: row["meetingId"],
                          meetingTitle: row["meetingTitle"], meetingDate: row["meetingDate"],
                          startTime: row["startTime"], endTime: row["endTime"],
                          speakerName: row["speakerName"], text: row["text"],
                          snippet: row["snippet"], rank: row["rank"])
            }
            if let speakerName {
                let wanted = TextNormalization.comparable(speakerName)
                hits = hits.filter { TextNormalization.comparable($0.speakerName).contains(wanted) }
            }
            return Array(hits.prefix(limit))
        }
    }

    public func transcriptSample(meetingIds: [String], limit: Int) throws -> [SearchHit] {
        guard !meetingIds.isEmpty, limit > 0 else { return [] }
        return try reader.read { db in
            let sql = """
                SELECT s.id AS segmentId, s.meetingId, m.title AS meetingTitle,
                       COALESCE(m.startedAt, m.createdAt) AS meetingDate,
                       s.startTime, s.endTime,
                       COALESCE(s.editedText, s.vocabularyText, s.asrText) AS text,
                       \(Self.speakerNameSQL) AS speakerName
                FROM transcriptSegment s
                JOIN transcript t ON t.id = s.transcriptId AND t.supersededAt IS NULL
                JOIN meeting m ON m.id = s.meetingId
                LEFT JOIN participant p ON p.id = s.participantId
                LEFT JOIN meetingSpeaker ms ON ms.id = s.meetingSpeakerId
                WHERE s.meetingId IN (\(meetingIds.map { _ in "?" }.joined(separator: ",")))
                ORDER BY meetingDate, s.meetingId, s.startTime
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(meetingIds))
            let picked = rows.count <= limit ? rows : (0..<limit).map { rows[$0 * rows.count / limit] }
            return picked.map { row in
                let text: String = row["text"]
                return SearchHit(segmentId: row["segmentId"], meetingId: row["meetingId"],
                                 meetingTitle: row["meetingTitle"], meetingDate: row["meetingDate"],
                                 startTime: row["startTime"], endTime: row["endTime"],
                                 speakerName: row["speakerName"], text: text, snippet: text, rank: 0)
            }
        }
    }
}
