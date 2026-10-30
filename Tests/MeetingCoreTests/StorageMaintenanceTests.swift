import Foundation
import GRDB
import Testing
@testable import MeetingCore

@Suite("Borrado y espacio en disco")
struct StorageMaintenanceTests {
    private func library() throws -> (AppDatabase, AppPaths, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-test-\(UUID().uuidString)")
        let paths = AppPaths(root: root)
        return (try AppDatabase.open(paths: paths), paths, root)
    }

    private func sample(_ db: AppDatabase, meetingId: String) throws {
        let participant = Participant(displayName: "FIXTURE · Persona")
        try db.save(participant: participant)
        let profile = try db.createProfile(participantId: participant.id, consentStatement: "fixture", retentionDays: nil)
        try db.add(sample: VoiceSample(profileId: profile.id, origin: .validatedMeetingSegment, meetingId: meetingId,
                                       startTime: 0, endTime: 3, durationSeconds: 3,
                                       embeddingCiphertext: Data([1, 2, 3]), embeddingModel: "fixture"))
    }

    @Test(arguments: [false, true])
    func deletionSummaryAndVoiceSamples(includeVoiceSamples: Bool) throws {
        let (db, paths, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let (meeting, _, _, _) = try Fixture.meeting(db, texts: [("hola", 0, 1)])
        let dir = try paths.prepareMeetingDirectory(meeting.id)
        try Data(count: 64_000).write(to: dir.appendingPathComponent("imported.wav"))
        try sample(db, meetingId: meeting.id)
        try db.appendChatMessage(ChatHistoryMessage(question: "hola", answer: nil, scopeMeetingIds: nil),
                                 thread: .meeting(meeting.id))

        let summary = try db.deletionSummary(meetingId: meeting.id, paths: paths)
        #expect(summary.fileBytes >= 64_000)
        #expect(summary.voiceSamples == 1)
        #expect(summary.chatMessages == 1)

        try db.deleteMeeting(id: meeting.id, paths: paths, includeVoiceSamples: includeVoiceSamples)
        let samples = try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM voiceSample") }
        #expect(samples == (includeVoiceSamples ? 0 : 1))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func compactionReturnsFreedPagesToDisk() throws {
        let (db, paths, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "texto de una reunión larga ", count: 40)
        let (meeting, _, _, _) = try Fixture.meeting(db, texts: (0..<400).map { (text, Double($0), Double($0) + 1) })
        try db.compactStorage()
        let before = StorageMaintenance.size(of: paths.databaseURL)
        try db.deleteMeeting(id: meeting.id, paths: paths)
        let free = try db.reader.read { try Int.fetchOne($0, sql: "PRAGMA freelist_count") ?? 0 }
        #expect(free > 0) // SQLite keeps deleted pages until VACUUM
        try db.compactStorage()
        #expect(try db.reader.read { try Int.fetchOne($0, sql: "PRAGMA freelist_count") } == 0)
        #expect(StorageMaintenance.size(of: paths.databaseURL) < before / 2)
    }

    @Test func orphanedFoldersAndOldTemporaryFilesAreRemoved() throws {
        let (db, paths, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let (meeting, _, _, _) = try Fixture.meeting(db, texts: [("hola", 0, 1)])
        let kept = try paths.prepareMeetingDirectory(meeting.id)
        let orphan = try paths.prepareMeetingDirectory("ORPHAN")
        try Data(count: 1000).write(to: orphan.appendingPathComponent("a.wav"))
        let report = try StorageMaintenance.removeOrphanedRecordings(database: db, paths: paths,
                                                                     now: Date().addingTimeInterval(2 * 3600))
        #expect(report.removedItems == 1 && report.freedBytes > 0)
        #expect(FileManager.default.fileExists(atPath: kept.path) && !FileManager.default.fileExists(atPath: orphan.path))

        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for name in ["mi-asr-old.wav", "mi-asr-new.wav", "other.wav"] {
            try Data(count: 10).write(to: tmp.appendingPathComponent(name))
        }
        let old = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: tmp.appendingPathComponent("mi-asr-old.wav").path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: tmp.appendingPathComponent("other.wav").path)
        let swept = StorageMaintenance.sweepTemporaryFiles(in: tmp)
        #expect(swept.removedItems == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path).sorted() == ["mi-asr-new.wav", "other.wav"])
    }
}
