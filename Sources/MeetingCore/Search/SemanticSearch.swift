import CryptoKit
public import Foundation
import GRDB

/// A query vector plus the model that produced it (vectors of other models are ignored).
public struct SemanticQuery: Sendable {
    public var vector: [Float]
    public var model: String
    public init(vector: [Float], model: String) {
        self.vector = vector
        self.model = model
    }
}

/// A segment whose embedding is missing or stale.
public struct PendingEmbedding: Sendable, Hashable {
    public var segmentId: String
    public var text: String
    public var textHash: String
}

public struct SemanticIndexCoverage: Sendable, Equatable {
    public var indexed: Int
    public var total: Int
}

/// Float32 little-endian blobs and the hash that detects edited text.
public enum EmbeddingCodec {
    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    public static func textHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Cosine similarity (vectors are L2-normalized by the engine, but this does not rely on it).
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let norm = (na * nb).squareRoot()
        return norm > 0 ? dot / norm : 0
    }
}

extension AppDatabase {
    // MARK: Semantic index

    /// Active-transcript segments with no embedding for `model`, or whose text changed since.
    public func segmentsNeedingEmbedding(model: String, limit: Int) throws -> [PendingEmbedding] {
        try reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, COALESCE(s.editedText, s.vocabularyText, s.asrText) AS text, e.textHash, e.model
                FROM transcriptSegment s
                JOIN transcript t ON t.id = s.transcriptId AND t.supersededAt IS NULL
                LEFT JOIN segmentEmbedding e ON e.segmentId = s.id
                ORDER BY s.meetingId, s.startTime
                """)
            var pending: [PendingEmbedding] = []
            for row in rows {
                let text: String = row["text"]
                let hash = EmbeddingCodec.textHash(text)
                let storedModel: String? = row["model"], storedHash: String? = row["textHash"]
                guard storedModel != model || storedHash != hash else { continue }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                pending.append(PendingEmbedding(segmentId: row["id"], text: text, textHash: hash))
                if pending.count >= limit { break }
            }
            return pending
        }
    }

    public func storeEmbeddings(_ items: [(PendingEmbedding, [Float])], model: String) throws {
        try writer.write { db in
            for (item, vector) in items where try Int.fetchOne(
                db, sql: "SELECT 1 FROM transcriptSegment WHERE id = ?", arguments: [item.segmentId]) != nil {
                try db.execute(sql: """
                    INSERT INTO segmentEmbedding (segmentId, model, textHash, vector) VALUES (?, ?, ?, ?)
                    ON CONFLICT(segmentId) DO UPDATE SET model = excluded.model, textHash = excluded.textHash,
                                                         vector = excluded.vector
                    """, arguments: [item.segmentId, model, item.textHash, EmbeddingCodec.encode(vector)])
            }
        }
    }

    public func semanticIndexCoverage(model: String) throws -> SemanticIndexCoverage {
        try reader.read { db in
            let total = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcriptSegment s
                JOIN transcript t ON t.id = s.transcriptId AND t.supersededAt IS NULL
                WHERE \(Self.hasTextSQL)
                """) ?? 0
            let indexed = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM segmentEmbedding e
                JOIN transcriptSegment s ON s.id = e.segmentId
                JOIN transcript t ON t.id = s.transcriptId AND t.supersededAt IS NULL
                WHERE e.model = ? AND \(Self.hasTextSQL)
                """, arguments: [model]) ?? 0
            return SemanticIndexCoverage(indexed: indexed, total: total)
        }
    }

    static let hasTextSQL = """
        TRIM(COALESCE(s.editedText, s.vocabularyText, s.asrText), ' ' || char(9) || char(10) || char(13)) != ''
        """

    /// Drops every stored vector (the index is a rebuildable cache).
    public func clearSemanticIndex() throws {
        _ = try writer.write { db in try db.execute(sql: "DELETE FROM segmentEmbedding") }
    }
}

extension SearchService {
    /// Brute-force cosine search over stored vectors of `query.model`. `rank` is −similarity (lower = better).
    public func semanticSearch(_ query: SemanticQuery, scope: SearchScope = .allMeetings, limit: Int = 30,
                               minSimilarity: Float = SearchService.semanticFloor) throws -> [SearchHit] {
        try reader.read { db in
            var sql = """
                SELECT s.id AS segmentId, s.meetingId, m.title AS meetingTitle,
                       COALESCE(m.startedAt, m.createdAt) AS meetingDate,
                       s.startTime, s.endTime,
                       COALESCE(s.editedText, s.vocabularyText, s.asrText) AS text,
                       \(Self.speakerNameSQL) AS speakerName,
                       e.vector
                FROM segmentEmbedding e
                JOIN transcriptSegment s ON s.id = e.segmentId
                JOIN transcript t ON t.id = s.transcriptId AND t.supersededAt IS NULL
                JOIN meeting m ON m.id = s.meetingId
                LEFT JOIN participant p ON p.id = s.participantId
                LEFT JOIN meetingSpeaker ms ON ms.id = s.meetingSpeakerId
                WHERE e.model = ? AND \(AppDatabase.hasTextSQL)
                """
            var arguments: StatementArguments = [query.model]
            if case .meetings(let ids) = scope {
                guard !ids.isEmpty else { return [] }
                sql += " AND s.meetingId IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
                arguments += StatementArguments(ids)
            }
            let scored = try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row -> SearchHit? in
                let text: String = row["text"]
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let similarity = EmbeddingCodec.cosine(query.vector, EmbeddingCodec.decode(row["vector"]))
                guard similarity >= minSimilarity else { return nil }
                return SearchHit(segmentId: row["segmentId"], meetingId: row["meetingId"],
                                 meetingTitle: row["meetingTitle"], meetingDate: row["meetingDate"],
                                 startTime: row["startTime"], endTime: row["endTime"],
                                 speakerName: row["speakerName"], text: text, snippet: text,
                                 rank: Double(-similarity))
            }
            return Array(scored.sorted { $0.rank < $1.rank }.prefix(limit))
        }
    }

    /// multilingual-e5-small similarities are compressed (~0.75–0.9): off-topic questions
    /// peaked at 0.79–0.82 and the weakest relevant excerpt was 0.80 in the TD-25 measurement.
    public static let semanticFloor: Float = 0.80

    /// Semantic hits first (they found paraphrases keyword search missed), then keyword
    /// hits not already present so exact names and terms are never lost. Ranks are positions.
    public static func merge(semantic: [SearchHit], keyword: [SearchHit], limit: Int) -> [SearchHit] {
        let head = semantic.prefix(limit * 2 / 3)
        var seen = Set(head.map(\.segmentId))
        var merged = Array(head)
        for hit in keyword + semantic.dropFirst(head.count) where seen.insert(hit.segmentId).inserted {
            merged.append(hit)
        }
        return merged.prefix(limit).enumerated().map { i, hit in
            var hit = hit
            hit.rank = Double(i)
            return hit
        }
    }
}
