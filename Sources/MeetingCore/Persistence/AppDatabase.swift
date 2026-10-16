public import Foundation
public import GRDB
import OSLog

/// Owner of the SQLite library. All reads/writes go through `writer`/`reader`.
///
/// Uses a WAL `DatabasePool` so the MCP server and the CLI can read
/// concurrently while the app writes.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public var reader: any DatabaseReader { writer }

    static let logger = Logger(subsystem: "dev.meetingintelligence", category: "database")

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (creating if needed) the on-disk library.
    public static func open(paths: AppPaths) throws -> AppDatabase {
        try paths.prepare()
        let pool = try DatabasePool(path: paths.databaseURL.path, configuration: makeConfiguration(readOnly: false))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.databaseURL.path)
        return try AppDatabase(pool)
    }

    /// Read-only access for helper processes (MCP server). Never migrates.
    public static func openReadOnly(paths: AppPaths) throws -> any DatabaseReader {
        guard FileManager.default.fileExists(atPath: paths.databaseURL.path) else {
            throw AppDatabaseError.libraryNotFound(paths.databaseURL.path)
        }
        return try DatabasePool(path: paths.databaseURL.path, configuration: makeConfiguration(readOnly: true))
    }

    /// Empty in-memory database for tests.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: makeConfiguration(readOnly: false)))
    }

    static func makeConfiguration(readOnly: Bool) -> Configuration {
        var config = Configuration()
        config.readonly = readOnly
        config.foreignKeysEnabled = true
        config.label = readOnly ? "MeetingIntelligence.readonly" : "MeetingIntelligence"
        config.prepareDatabase { db in
            // Deleted content is overwritten on disk (privacy: deleted meetings/profiles).
            if !db.configuration.readonly {
                try db.execute(sql: "PRAGMA secure_delete = ON")
            }
        }
        return config
    }
}

public enum AppDatabaseError: LocalizedError, Sendable {
    case libraryNotFound(String)
    case notFound(String)
    case invalidOperation(String)

    public var errorDescription: String? {
        switch self {
        case .libraryNotFound(let path): "No existe una biblioteca en \(path). Abre la aplicación al menos una vez."
        case .notFound(let what): "No se encontró: \(what)."
        case .invalidOperation(let message): message
        }
    }
}
