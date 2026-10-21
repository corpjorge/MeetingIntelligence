public import Foundation

/// File-system layout of the local library.
///
/// ```
/// <root>/
///   Library.sqlite            SQLite database (WAL)
///   Recordings/<meetingId>/   Audio tracks for one meeting
///   Imports/                  Staging area for imported files
///   Exports/                  Default export destination
///   Logs/                     Processing logs (no transcript text, no secrets)
///   Models/                   Text-embedding model (opt-in semantic search)
/// ```
///
/// The root defaults to `~/Library/Application Support/MeetingIntelligence` and
/// can be overridden with `MEETING_INTELLIGENCE_HOME` (tests, CLI, MCP server).
public struct AppPaths: Sendable, Hashable {
    public let root: URL

    public static let environmentOverrideKey = "MEETING_INTELLIGENCE_HOME"

    public init(root: URL) {
        self.root = root
    }

    public static func resolveDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let override = environment[environmentOverrideKey], !override.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: base.appendingPathComponent(AppIdentity.storageFolderName, isDirectory: true))
    }

    public var databaseURL: URL { root.appendingPathComponent("Library.sqlite") }
    public var recordingsDirectory: URL { root.appendingPathComponent("Recordings", isDirectory: true) }
    public var importsDirectory: URL { root.appendingPathComponent("Imports", isDirectory: true) }
    public var exportsDirectory: URL { root.appendingPathComponent("Exports", isDirectory: true) }
    public var logsDirectory: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    /// Models this app downloads itself (FluidAudio keeps its own cache).
    public var modelsDirectory: URL { root.appendingPathComponent("Models", isDirectory: true) }

    public func meetingDirectory(_ meetingID: String) -> URL {
        recordingsDirectory.appendingPathComponent(meetingID, isDirectory: true)
    }

    /// Resolves a path stored in the database (always relative to `root`).
    public func resolve(relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// Converts an absolute URL inside the library into the relative form stored in the database.
    public func relativePath(for url: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// Creates the directory tree with owner-only permissions (0700).
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, recordingsDirectory, importsDirectory, exportsDirectory, logsDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    @discardableResult
    public func prepareMeetingDirectory(_ meetingID: String) throws -> URL {
        let dir = meetingDirectory(meetingID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }
}
