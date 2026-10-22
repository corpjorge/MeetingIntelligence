public import Foundation

/// One published version of the app that can be installed by the updater.
public struct AppRelease: Sendable, Hashable, Identifiable {
    public struct Asset: Sendable, Hashable {
        public var name: String
        public var url: URL
        public var size: Int64

        public init(name: String, url: URL, size: Int64) {
            self.name = name
            self.url = url
            self.size = size
        }
    }

    public var version: AppVersion
    /// Version exactly as written in the tag (without the leading "v"); it is part of the signed message.
    public var versionString: String
    public var tag: String
    public var title: String
    public var notes: String
    public var pageURL: URL
    public var publishedAt: Date?
    public var isPrerelease: Bool
    /// The app as a ZIP (`<name>-<version>.zip`) and its Ed25519 signature (`….zip.sig`).
    public var archive: Asset
    public var signature: Asset

    public var id: String { tag }

    public init(version: AppVersion, versionString: String, tag: String, title: String, notes: String, pageURL: URL,
                publishedAt: Date?, isPrerelease: Bool, archive: Asset, signature: Asset) {
        self.version = version
        self.versionString = versionString
        self.tag = tag
        self.title = title
        self.notes = notes
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.archive = archive
        self.signature = signature
    }

    /// The "Novedades" section of the notes as plain text (headings and tables removed).
    public var highlights: String { ReleaseNotes.highlights(notes) }
}

/// GitHub's `GET /repos/{owner}/{repo}/releases` (not `/latest`, which skips pre-releases).
public enum GitHubReleases {
    public static func releases(from data: Data) throws -> [AppRelease] {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
            var size: Int64
        }
        struct Release: Decodable {
            var tag_name: String
            var name: String?
            var body: String?
            var html_url: URL
            var draft: Bool
            var prerelease: Bool
            var published_at: Date?
            var assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Release].self, from: data).compactMap { release in
            guard !release.draft else { return nil }
            let versionString = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            guard let version = AppVersion(versionString),
                  let zip = release.assets.first(where: { $0.name.hasSuffix("-\(versionString).zip") }),
                  let sig = release.assets.first(where: { $0.name == zip.name + ".sig" }),
                  isAllowedDownload(zip.browser_download_url), isAllowedDownload(sig.browser_download_url)
            else { return nil }
            return AppRelease(version: version, versionString: versionString, tag: release.tag_name,
                              title: release.name ?? release.tag_name, notes: release.body ?? "",
                              pageURL: release.html_url, publishedAt: release.published_at,
                              isPrerelease: release.prerelease,
                              archive: .init(name: zip.name, url: zip.browser_download_url, size: zip.size),
                              signature: .init(name: sig.name, url: sig.browser_download_url, size: sig.size))
        }
    }

    /// HTTPS, or HTTP to this Mac (end-to-end tests with a loopback server).
    static func isAllowedDownload(_ url: URL) -> Bool {
        url.scheme == "https" || (url.scheme == "http" && AppUpdateConfiguration.isLoopback(url))
    }

    /// The newest installable release, if it is newer than `current`.
    public static func newest(_ releases: [AppRelease], newerThan current: AppVersion) -> AppRelease? {
        releases.filter { $0.version > current }.max { $0.version < $1.version }
    }
}

enum ReleaseNotes {
    static let maxLength = 1_500

    static func highlights(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        let isHeading = { (line: Substring) in line.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        var selected = lines[...]
        if let start = lines.firstIndex(where: { isHeading($0) && $0.localizedCaseInsensitiveContains("novedades") }) {
            let rest = lines[lines.index(after: start)...]
            selected = rest[..<(rest.firstIndex(where: isHeading) ?? rest.endIndex)]
        }
        // Markdown soft breaks: a line that continues a paragraph or a list item joins the previous one.
        var output: [String] = []
        var continues = false
        for line in selected {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { continues = false; continue }
            if trimmed.isEmpty {
                if output.last?.isEmpty == false { output.append("") }
                continues = false
            } else if trimmed.hasPrefix("#") {
                output.append(trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                continues = false
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                output.append("• " + trimmed.dropFirst(2))
                continues = true
            } else if continues, let last = output.indices.last {
                output[last] += " " + trimmed
            } else {
                output.append(trimmed)
                continues = true
            }
        }
        let text = output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > maxLength ? String(text.prefix(maxLength)) + "…" : text
    }
}
