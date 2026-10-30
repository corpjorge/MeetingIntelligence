public import Foundation
import GRDB

/// What deleting one meeting removes (shown before confirming).
public struct MeetingDeletionSummary: Sendable, Equatable {
    /// Audio and any other files under `Recordings/<meetingId>`.
    public var fileBytes: Int64
    /// Voice samples enrolled from this meeting (kept on the profile unless asked).
    public var voiceSamples: Int
    /// Chat messages deleted with it (its own thread + cross-meeting messages quoting it).
    public var chatMessages: Int

    public init(fileBytes: Int64, voiceSamples: Int, chatMessages: Int) {
        self.fileBytes = fileBytes
        self.voiceSamples = voiceSamples
        self.chatMessages = chatMessages
    }
}

public struct StorageCleanupReport: Sendable, Equatable {
    public var removedItems: Int
    public var freedBytes: Int64
}

public enum StorageMaintenance {
    /// Prefixes of the app's own temporary files (ASR copies, AI working dirs, enrollment clips).
    static let temporaryPrefixes = ["mi-asr-", "mi-ai-", "mi-enroll-"]

    public static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        var total: Int64 = 0
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        while let file = enumerator?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// `Recordings/<id>` folders whose meeting no longer exists (e.g. a crash between the
    /// database delete and the file delete).
    public static func removeOrphanedRecordings(database: AppDatabase, paths: AppPaths, now: Date = Date(),
                                                minimumAge: TimeInterval = 3600) throws -> StorageCleanupReport {
        let fm = FileManager.default
        var report = StorageCleanupReport(removedItems: 0, freedBytes: 0)
        guard let folders = try? fm.contentsOfDirectory(at: paths.recordingsDirectory,
                                                        includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return report
        }
        let known = Set(try database.reader.read { db in try String.fetchAll(db, sql: "SELECT id FROM meeting") })
        guard !known.isEmpty else { return report }
        for folder in folders where folder.hasDirectoryPath && !known.contains(folder.lastPathComponent) {
            guard let modified = latestModification(of: folder), now.timeIntervalSince(modified) >= minimumAge else { continue }
            let bytes = size(of: folder)
            try fm.removeItem(at: folder)
            report.removedItems += 1
            report.freedBytes += bytes
        }
        return report
    }

    static func latestModification(of url: URL) -> Date? {
        let key = URLResourceKey.contentModificationDateKey
        guard var latest = try? url.resourceValues(forKeys: [key]).contentModificationDate else { return nil }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [key])
        while let item = enumerator?.nextObject() as? URL {
            guard let modified = try? item.resourceValues(forKeys: [key]).contentModificationDate else { return nil }
            latest = max(latest, modified)
        }
        return latest
    }

    /// Leftover temporary files of this app older than `age` (normally removed right after use).
    public static func sweepTemporaryFiles(olderThan age: TimeInterval = 3600,
                                           in directory: URL = FileManager.default.temporaryDirectory,
                                           now: Date = Date()) -> StorageCleanupReport {
        let fm = FileManager.default
        var report = StorageCleanupReport(removedItems: 0, freedBytes: 0)
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items where temporaryPrefixes.contains(where: item.lastPathComponent.hasPrefix) {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            guard now.timeIntervalSince(modified) >= age else { continue }
            let bytes = size(of: item)
            if (try? fm.removeItem(at: item)) != nil {
                report.removedItems += 1
                report.freedBytes += bytes
            }
        }
        return report
    }
}

extension AppDatabase {
    public func deletionSummary(meetingId: String, paths: AppPaths) throws -> MeetingDeletionSummary {
        let (samples, chats) = try reader.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM voiceSample WHERE meetingId = ?", arguments: [meetingId]) ?? 0,
             try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT id) FROM chatMessage
                WHERE meetingId = ? OR id IN (SELECT chatMessageId FROM chatMessageSource WHERE meetingId = ?)
                """, arguments: [meetingId, meetingId]) ?? 0)
        }
        return MeetingDeletionSummary(fileBytes: StorageMaintenance.size(of: paths.meetingDirectory(meetingId)),
                                      voiceSamples: samples, chatMessages: chats)
    }

    /// Returns the database file to its live size: SQLite keeps deleted pages as free space
    /// (`auto_vacuum` is off), so the file only shrinks after `VACUUM`. The WAL is truncated too.
    public func compactStorage() throws {
        try writer.vacuum()
        if let pool = writer as? DatabasePool {
            try pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
        }
    }
}
