public import Foundation
import GRDB

extension AppDatabase {
    // MARK: Chat history

    /// Messages of one thread, oldest first.
    public func chatHistory(_ thread: ChatThread) throws -> [ChatHistoryMessage] {
        let decoder = JSONDecoder()
        return try reader.read { db in
            try Self.chatRequest(thread).order(Column("createdAt"), Column("rowid")).fetchAll(db).map { row in
                ChatHistoryMessage(
                    id: row.id, question: row.question,
                    answer: row.answerJSON.flatMap { try? decoder.decode(MeetingChatService.Answer.self, from: $0) },
                    scopeMeetingIds: row.scopeJSON.flatMap { try? decoder.decode([String].self, from: $0) },
                    createdAt: row.createdAt)
            }
        }
    }

    /// Stores a finished question. Cited meetings are linked so deleting any of them removes the message.
    @discardableResult
    public func appendChatMessage(_ message: ChatHistoryMessage, thread: ChatThread) throws -> Bool {
        let encoder = JSONEncoder()
        let (key, meetingId) = Self.columns(thread)
        let record = ChatMessageRecord(
            id: message.id, thread: key, meetingId: meetingId, question: message.question,
            answerJSON: try message.answer.map { try encoder.encode($0) },
            scopeJSON: try message.scopeMeetingIds.map { try encoder.encode($0) },
            createdAt: message.createdAt)
        let cited = Set((message.answer?.excerpts ?? []).map(\.meetingId) + (message.answer?.citations ?? []).map(\.meetingId))
        let required = cited.union(meetingId.map { [$0] } ?? [])
        return try writer.write { db in
            for id in required where try !Meeting.exists(db, key: id) {
                return false
            }
            try record.insert(db)
            for id in cited {
                try ChatMessageSourceRecord(chatMessageId: record.id, meetingId: id).insert(db)
            }
            return true
        }
    }

    public func clearChatHistory(_ thread: ChatThread) throws {
        _ = try writer.write { db in try Self.chatRequest(thread).deleteAll(db) }
    }

    private static func columns(_ thread: ChatThread) -> (thread: String, meetingId: String?) {
        switch thread {
        case .meeting(let id): ("meeting", id)
        case .library: ("library", nil)
        }
    }

    private static func chatRequest(_ thread: ChatThread) -> QueryInterfaceRequest<ChatMessageRecord> {
        let (key, meetingId) = columns(thread)
        let request = ChatMessageRecord.filter(Column("thread") == key)
        return meetingId.map { request.filter(Column("meetingId") == $0) } ?? request
    }
}
