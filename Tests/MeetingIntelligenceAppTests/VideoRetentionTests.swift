import Foundation
import MeetingCore
import Testing
@testable import MeetingIntelligenceApp

@Suite("App: conservación de video")
struct VideoRetentionTests {
    @Test func audioPolicyDoesNotDeleteVideoAndVideoPolicyKeepsAudioAndTranscript() throws {
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase.open(paths: paths)
        let meeting = try AppFixture.meeting(db)
        try db.updateMeeting(id: meeting.id) { $0.createdAt = Date().addingTimeInterval(-90 * 86_400) }
        let directory = try paths.prepareMeetingDirectory(meeting.id)
        let video = VideoAsset(meetingId: meeting.id, relativePath: "Recordings/\(meeting.id)/video.mov", windowTitle: "Test",
                               applicationName: "Test", width: 320, height: 180, state: .ready)
        try db.save(video: video)
        let audioURL = directory.appendingPathComponent("imported.wav")
        let videoURL = paths.resolve(relativePath: video.relativePath)
        try Data("fixture audio".utf8).write(to: audioURL)
        try Data("fixture video".utf8).write(to: videoURL)
        try AudioRetention(database: db, paths: paths).apply(days: 7)
        #expect(FileManager.default.fileExists(atPath: videoURL.path))
        try Data("fixture audio".utf8).write(to: audioURL)
        try VideoRetention(database: db, paths: paths).apply(days: 7)
        #expect(!FileManager.default.fileExists(atPath: videoURL.path))
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(try db.meetingDetail(id: meeting.id)?.segments.isEmpty == false)
    }
}
