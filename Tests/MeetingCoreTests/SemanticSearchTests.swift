import Foundation
import GRDB
import Testing
@testable import MeetingCore

@Suite("Búsqueda semántica: índice y fusión")
struct SemanticSearchTests {
    let model = "test-model"

    /// Deterministic stand-in vectors (the real engine is tested in MeetingSemanticTests).
    private func vector(_ x: Float, _ y: Float) -> [Float] { [x, y, 0] }

    @Test func codecRoundTripAndCosine() {
        let v: [Float] = [0.25, -1, 3.5]
        #expect(EmbeddingCodec.decode(EmbeddingCodec.encode(v)) == v)
        #expect(abs(EmbeddingCodec.cosine([1, 0], [1, 0]) - 1) < 1e-6)
        #expect(abs(EmbeddingCodec.cosine([1, 0], [0, 1])) < 1e-6)
        #expect(EmbeddingCodec.cosine([1], [1, 0]) == 0)
    }

    @Test func pendingCoverageEditsAndCascade() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let db = try AppDatabase.open(paths: paths)
        let (meeting, _, _, segments) = try Fixture.meeting(db, texts: [("se me cayó el internet", 0, 2), ("aprobamos el costo", 3, 5)])

        let pending = try db.segmentsNeedingEmbedding(model: model, limit: 10)
        #expect(pending.count == 2)
        try db.storeEmbeddings(pending.map { ($0, vector(1, 0)) }, model: model)
        #expect(try db.segmentsNeedingEmbedding(model: model, limit: 10).isEmpty)
        #expect(try db.semanticIndexCoverage(model: model) == SemanticIndexCoverage(indexed: 2, total: 2))
        // Another model's vectors do not count.
        #expect(try db.segmentsNeedingEmbedding(model: "other", limit: 10).count == 2)

        // An edit makes that one segment stale.
        try db.editSegmentText(segmentId: segments[0].id, newText: "se me cayó la conexión")
        #expect(try db.segmentsNeedingEmbedding(model: model, limit: 10).map(\.segmentId) == [segments[0].id])

        try db.deleteMeeting(id: meeting.id, paths: paths)
        let left = try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM segmentEmbedding") }
        #expect(left == 0)
    }

    @Test func searchRespectsModelScopeAndFloor() throws {
        let db = try AppDatabase.inMemory()
        let (a, _, _, sa) = try Fixture.meeting(db, title: "FIXTURE · A", texts: [("se me cayó el internet", 0, 2)])
        let (_, _, _, sb) = try Fixture.meeting(db, title: "FIXTURE · B", texts: [("la factura llegó duplicada", 0, 2)])
        let pending = try db.segmentsNeedingEmbedding(model: model, limit: 10)
        let vectors: [String: [Float]] = [sa[0].id: vector(1, 0.1), sb[0].id: vector(0.1, 1)]
        try db.storeEmbeddings(pending.map { ($0, vectors[$0.segmentId]!) }, model: model)

        let search = SearchService(reader: db.reader)
        let query = SemanticQuery(vector: vector(1, 0), model: model)
        let hits = try search.semanticSearch(query, minSimilarity: 0.5)
        #expect(hits.map(\.segmentId) == [sa[0].id])
        #expect(try search.semanticSearch(query, minSimilarity: 0).map(\.segmentId) == [sa[0].id, sb[0].id])
        #expect(try search.semanticSearch(query, scope: .meetings(["none"]), minSimilarity: 0).isEmpty)
        #expect(try search.semanticSearch(SemanticQuery(vector: vector(1, 0), model: "other")).isEmpty)
        _ = a
    }

    @Test func mergeKeepsSemanticFirstAndNeverDropsKeywordHits() {
        func hit(_ id: String) -> SearchHit {
            SearchHit(segmentId: id, meetingId: "m", meetingTitle: "t", meetingDate: Date(timeIntervalSince1970: 0),
                      startTime: 0, endTime: 1, speakerName: "s", text: id, snippet: id, rank: 0)
        }
        let semantic = (1...9).map { hit("s\($0)") }
        let keyword = [hit("k1"), hit("s2"), hit("k2")]
        let merged = SearchService.merge(semantic: semantic, keyword: keyword, limit: 9)
        // Two thirds semantic, then keyword-only hits, then the remaining semantic ones.
        #expect(merged.map(\.segmentId) == ["s1", "s2", "s3", "s4", "s5", "s6", "k1", "k2", "s7"])
        #expect(merged.map(\.rank) == (0..<9).map(Double.init))
    }
}
