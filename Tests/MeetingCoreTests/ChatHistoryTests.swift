import Foundation
import GRDB
import Testing
@testable import MeetingCore

@Suite("Historial del chat")
struct ChatHistoryTests {
    private func ask(_ db: AppDatabase, _ question: String, scope: SearchScope) throws -> MeetingChatService.Answer {
        let chat = MeetingChatService(database: db)
        let retrieval = try chat.retrieve(question: question, scope: scope, model: nil, timeout: 10)
        return chat.localAnswer(question: question, retrieval: retrieval)
    }

    @Test func threadsPersistAndStaySeparate() throws {
        let db = try AppDatabase.inMemory()
        let (a, _, _, _) = try Fixture.meeting(db, title: "FIXTURE · A", texts: [("el presupuesto de enero quedó aprobado", 0, 3)])
        let answer = try ask(db, "presupuesto", scope: .meetings([a.id]))
        #expect(answer.excerpts.count == 1)

        try db.appendChatMessage(ChatHistoryMessage(question: "presupuesto", answer: answer, scopeMeetingIds: [a.id]),
                                 thread: .meeting(a.id))
        try db.appendChatMessage(ChatHistoryMessage(question: "sin resultado", answer: nil, scopeMeetingIds: nil),
                                 thread: .library)

        let meetingThread = try db.chatHistory(.meeting(a.id))
        #expect(meetingThread.map(\.question) == ["presupuesto"])
        #expect(meetingThread.first?.answer == answer)
        #expect(meetingThread.first?.scopeMeetingIds == [a.id])
        let library = try db.chatHistory(.library)
        #expect(library.map(\.question) == ["sin resultado"])
        #expect(library.first?.answer == nil)

        try db.clearChatHistory(.library)
        #expect(try db.chatHistory(.library).isEmpty)
        #expect(try db.chatHistory(.meeting(a.id)).count == 1)
    }

    @Test func deletingAMeetingRemovesMessagesThatQuoteIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let db = try AppDatabase.open(paths: paths)
        let (a, _, _, _) = try Fixture.meeting(db, title: "FIXTURE · A", texts: [("la latencia del API subió", 0, 2)])
        let (b, _, _, _) = try Fixture.meeting(db, title: "FIXTURE · B", texts: [("revisamos la factura duplicada", 0, 2)])

        try db.appendChatMessage(ChatHistoryMessage(question: "latencia", answer: try ask(db, "latencia", scope: .allMeetings),
                                                    scopeMeetingIds: nil), thread: .library)
        try db.appendChatMessage(ChatHistoryMessage(question: "factura", answer: try ask(db, "factura", scope: .allMeetings),
                                                    scopeMeetingIds: nil), thread: .library)
        try db.appendChatMessage(ChatHistoryMessage(question: "latencia", answer: try ask(db, "latencia", scope: .meetings([a.id])),
                                                    scopeMeetingIds: [a.id]), thread: .meeting(a.id))

        try db.deleteMeeting(id: a.id, paths: paths)
        // Only the library message quoting B survives; A's own thread is gone too.
        #expect(try db.chatHistory(.library).map(\.question) == ["factura"])
        #expect(try db.chatHistory(.meeting(a.id)).isEmpty)
        let orphanLinks = try db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chatMessageSource WHERE meetingId = ?", arguments: [a.id])
        }
        #expect(orphanLinks == 0)
        _ = b
    }
}
