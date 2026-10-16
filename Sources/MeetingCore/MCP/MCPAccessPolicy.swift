public import Foundation

/// Authorization for the local MCP server, written by the app (Settings › MCP)
/// to `<library>/mcp-access.json` and read by the server on every request.
///
/// Disabled by default: no meeting data is exposed until the user enables it.
/// Audio files and biometric data are never exposed, regardless of settings.
public struct MCPAccessPolicy: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// nil = all meetings; otherwise only these meeting IDs.
    public var allowedMeetingIds: [String]?
    /// Include participant e-mail addresses in results.
    public var exposeEmails: Bool
    public var updatedAt: Date

    public init(enabled: Bool = false, allowedMeetingIds: [String]? = nil, exposeEmails: Bool = false,
                updatedAt: Date = Date()) {
        self.enabled = enabled
        self.allowedMeetingIds = allowedMeetingIds
        self.exposeEmails = exposeEmails
        self.updatedAt = updatedAt
    }

    public static func url(in paths: AppPaths) -> URL {
        paths.root.appendingPathComponent("mcp-access.json")
    }

    public static func load(from paths: AppPaths) -> MCPAccessPolicy {
        guard let data = try? Data(contentsOf: url(in: paths)) else { return MCPAccessPolicy() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(MCPAccessPolicy.self, from: data)) ?? MCPAccessPolicy()
    }

    public func save(to paths: AppPaths) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = Self.url(in: paths)
        try encoder.encode(self).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func allows(meetingId: String) -> Bool {
        enabled && (allowedMeetingIds?.contains(meetingId) ?? true)
    }
}
