import CryptoKit
public import Foundation

/// A model the app downloads from Hugging Face and can update in place (TD-27).
public struct ManagedModel: Sendable, Identifiable, Hashable {
    public enum Revision: Sendable, Hashable {
        /// The library downloads the repository's `main`; newer commits are updates.
        case followsMain
        /// The library pins this commit; it only changes with a library upgrade.
        case pinned(String)
    }

    public var id: String
    public var displayName: String
    public var repository: String
    public var revision: Revision
    public var directory: URL
    /// Local entries that belong to the downloader, not to the model (never compared or removed).
    public var ignoredEntries: Set<String>
    /// Nil when the app uses the model; otherwise why it is idle (it can then be deleted).
    public var unusedReason: String?

    public init(id: String, displayName: String, repository: String, revision: Revision, directory: URL,
                ignoredEntries: Set<String> = [], unusedReason: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.repository = repository
        self.revision = revision
        self.directory = directory
        self.ignoredEntries = ignoredEntries.union([ModelUpdatePlanner.revisionMarker])
        self.unusedReason = unusedReason
    }

    public var isInstalled: Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.contains { !$0.hasPrefix(".") && !ignoredEntries.contains($0) }
    }
}

/// One file of a repository revision, as listed by the Hugging Face API.
public struct RemoteModelFile: Sendable, Hashable, Codable {
    public var path: String
    public var size: Int64
    /// SHA-256 of the content for LFS files (large weights).
    public var sha256: String?
    /// Git blob id (SHA-1 of `blob <size>\0<content>`) for every file.
    public var gitOid: String

    public init(path: String, size: Int64, sha256: String?, gitOid: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.gitOid = gitOid
    }
}

/// Files to download and local files to drop to reach `revision`.
public struct ModelUpdatePlan: Sendable, Equatable {
    public var revision: String
    public var changed: [RemoteModelFile]
    public var obsolete: [String]
    public var downloadBytes: Int64 { changed.reduce(0) { $0 + $1.size } }
    public var isEmpty: Bool { changed.isEmpty && obsolete.isEmpty }
}

public enum ModelUpdateState: Sendable, Equatable {
    case notInstalled
    case upToDate(revision: String)
    case updateAvailable(ModelUpdatePlan)
    /// Fixed by the library version; updates arrive with a library upgrade.
    case pinned(revision: String)
}

public enum ModelUpdatePlanner {
    /// Our own marker of the verified revision. FluidAudio's `.fluidaudio-revision` is left alone:
    /// writing it for a `main` cache would make FluidAudio treat the cache as stale.
    public static let revisionMarker = ".mi-revision"

    /// Libraries download a subset of each repository (one variant, no ONNX/PyTorch copies),
    /// so a remote file counts only if it exists locally, or if it belongs to a Core ML bundle
    /// (`.mlmodelc`/`.mlpackage`) present locally, whose files must all match.
    /// `hash` is called only when sizes match (SHA-256 for LFS files, git blob id otherwise).
    public static func plan(localFiles: [String: Int64], remote: [RemoteModelFile], revision: String,
                            hash: (String, RemoteModelFile) throws -> Bool) rethrows -> ModelUpdatePlan {
        func topLevel(_ path: String) -> String { String(path.split(separator: "/").first ?? "") }
        let bundles = Set(localFiles.keys.map(topLevel).filter { $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage") })
        let scoped = remote.filter { localFiles[$0.path] != nil || bundles.contains(topLevel($0.path)) }
        let scopedTopLevel = Set(remote.map { topLevel($0.path) })
        var changed: [RemoteModelFile] = []
        for file in scoped {
            guard let size = localFiles[file.path], size == file.size, try hash(file.path, file) else {
                changed.append(file)
                continue
            }
        }
        // Local files the revision no longer has (only within entries the repository still publishes
        // or inside bundles, so a library's own extra files are not touched).
        let remotePaths = Set(remote.map(\.path))
        let obsolete = localFiles.keys.filter { !remotePaths.contains($0) && scopedTopLevel.contains(topLevel($0)) }.sorted()
        return ModelUpdatePlan(revision: revision, changed: changed.sorted { $0.path < $1.path }, obsolete: obsolete)
    }

    /// Regular files under `directory` (relative paths → size), skipping ignored and hidden entries.
    public static func localFiles(in directory: URL, ignoring ignored: Set<String>) -> [String: Int64] {
        let fm = FileManager.default
        let base = directory.standardizedFileURL.path + "/"
        var files: [String: Int64] = [:]
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return files
        }
        while let url = enumerator.nextObject() as? URL {
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: base, with: "")
            let first = String(relative.split(separator: "/").first ?? "")
            if ignored.contains(first) || first.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { files[relative] = Int64(values?.fileSize ?? 0) }
        }
        return files
    }

    /// True when the local file has the published content.
    public static func matches(_ url: URL, _ remote: RemoteModelFile) throws -> Bool {
        if let sha256 = remote.sha256 { return try ContentHash.sha256(of: url) == sha256 }
        return try ContentHash.gitBlobId(of: url) == remote.gitOid
    }

    public static func storedRevision(in directory: URL) -> String? {
        (try? String(contentsOf: directory.appendingPathComponent(revisionMarker), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func storeRevision(_ revision: String, in directory: URL) throws {
        try Data((revision + "\n").utf8).write(to: directory.appendingPathComponent(revisionMarker), options: .atomic)
    }
}

/// Streaming hashes (weights are hundreds of MB).
public enum ContentHash {
    static let chunk = 4 << 20

    public static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        try stream(url) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func gitBlobId(of url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        try stream(url) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func stream(_ url: URL, _ body: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: chunk), !data.isEmpty { body(data) }
    }
}
