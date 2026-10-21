public import Foundation
import GRDB

/// Which conversation a chat message belongs to.
public enum ChatThread: Sendable, Hashable {
    /// The chat tab of one meeting; deleted with the meeting.
    case meeting(String)
    /// The cross-meeting chat ("Inteligencia").
    case library
}

/// One persisted question with its answer (nil answer = the search failed).
public struct ChatHistoryMessage: Sendable, Identifiable, Hashable {
    public var id: String
    public var question: String
    public var answer: MeetingChatService.Answer?
    /// Meetings the question was restricted to; nil = all meetings.
    public var scopeMeetingIds: [String]?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, question: String, answer: MeetingChatService.Answer?,
                scopeMeetingIds: [String]?, createdAt: Date = Date()) {
        self.id = id
        self.question = question
        self.answer = answer
        self.scopeMeetingIds = scopeMeetingIds
        self.createdAt = createdAt
    }
}

/// Row of `chatMessage`. Answers are stored as JSON snapshots: citations keep the
/// excerpt text as it was when the question was asked.
struct ChatMessageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chatMessage"
    var id: String
    var thread: String
    var meetingId: String?
    var question: String
    var answerJSON: Data?
    var scopeJSON: Data?
    var createdAt: Date
}

/// Meetings cited by a message; deleting one of them deletes the message (trigger in v3).
struct ChatMessageSourceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chatMessageSource"
    var chatMessageId: String
    var meetingId: String
}
