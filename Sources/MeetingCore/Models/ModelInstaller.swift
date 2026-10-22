public import Foundation
import os

/// Where model files come from (Hugging Face in the app; a local folder in tests).
public protocol ModelRepositorySource: Sendable {
    func latestRevision(repository: String) async throws -> String
    func files(repository: String, revision: String) async throws -> [RemoteModelFile]
    /// Downloads one file to `destination` (replacing it), reporting bytes written.
    func download(repository: String, revision: String, path: String, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws
}

public enum ModelInstallError: LocalizedError, Sendable {
    case busy(String)
    case verificationFailed(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .busy(let what): "No se puede actualizar mientras \(what)."
        case .verificationFailed(let path): "El archivo descargado no coincide con el publicado: \(path)."
        case .network(let message): "No se pudo consultar Hugging Face: \(message)"
        }
    }
}

/// Checks and applies model updates without ever leaving a half-updated model in place:
/// the new revision is assembled in a staging copy, swapped in, verified by loading it,
/// and the previous files are kept until the caller commits (or rolls back).
public struct ModelInstaller: Sendable {
    let source: any ModelRepositorySource

    public init(source: any ModelRepositorySource = HuggingFaceHub()) {
        self.source = source
    }

    public func check(_ model: ManagedModel) async throws -> ModelUpdateState {
        guard model.isInstalled else { return .notInstalled }
        if case .pinned(let revision) = model.revision { return .pinned(revision: revision) }
        let latest = try await source.latestRevision(repository: model.repository)
        if ModelUpdatePlanner.storedRevision(in: model.directory) == latest { return .upToDate(revision: latest) }
        let remote = try await source.files(repository: model.repository, revision: latest)
        let directory = model.directory
        let plan = try ModelUpdatePlanner.plan(
            localFiles: ModelUpdatePlanner.localFiles(in: directory, ignoring: model.ignoredEntries),
            remote: remote, revision: latest
        ) { path, file in try ModelUpdatePlanner.matches(directory.appendingPathComponent(path), file) }
        guard !plan.isEmpty else {
            try ModelUpdatePlanner.storeRevision(latest, in: directory)
            return .upToDate(revision: latest)
        }
        return .updateAvailable(plan)
    }

    public static func stagingURL(for model: ManagedModel) -> URL {
        model.directory.deletingLastPathComponent().appendingPathComponent(".\(model.directory.lastPathComponent).mi-staging")
    }

    public static func backupURL(for model: ManagedModel) -> URL {
        model.directory.deletingLastPathComponent().appendingPathComponent(".\(model.directory.lastPathComponent).mi-backup")
    }

    /// Builds the new revision next to the current one (an APFS clone of it plus the changed files).
    public func stage(_ model: ManagedModel, plan: ModelUpdatePlan,
                      progress: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void) async throws -> URL {
        let fm = FileManager.default
        let staging = Self.stagingURL(for: model)
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: model.directory, to: staging)
        do {
            for path in plan.obsolete { try? fm.removeItem(at: staging.appendingPathComponent(path)) }
            let total = plan.downloadBytes
            let done = OSAllocatedUnfairLock(initialState: Int64(0))
            for file in plan.changed {
                try Task.checkCancellation()
                let destination = staging.appendingPathComponent(file.path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let before = done.withLock { $0 }
                try await source.download(repository: model.repository, revision: plan.revision, path: file.path,
                                          to: destination) { written in progress(before + written, total) }
                guard try ModelUpdatePlanner.matches(destination, file) else {
                    throw ModelInstallError.verificationFailed(file.path)
                }
                done.withLock { $0 = before + file.size }
                progress(before + file.size, total)
            }
            try ModelUpdatePlanner.storeRevision(plan.revision, in: staging)
            return staging
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Puts the staged revision in place; the old files move to the backup location.
    public func swapIn(_ model: ManagedModel, staging: URL) throws {
        let fm = FileManager.default
        let backup = Self.backupURL(for: model)
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: model.directory, to: backup)
        do {
            try fm.moveItem(at: staging, to: model.directory)
        } catch {
            try? fm.moveItem(at: backup, to: model.directory)
            throw error
        }
    }

    /// The new revision loaded fine: the previous files are deleted.
    public func commit(_ model: ManagedModel) {
        try? FileManager.default.removeItem(at: Self.backupURL(for: model))
    }

    /// The new revision did not load: the previous files come back.
    public func rollback(_ model: ManagedModel) throws {
        let fm = FileManager.default
        let backup = Self.backupURL(for: model)
        guard fm.fileExists(atPath: backup.path) else { return }
        try? fm.removeItem(at: model.directory)
        try fm.moveItem(at: backup, to: model.directory)
    }

    /// After a crash mid-update: an unverified swap is undone and staging copies are dropped.
    public func recoverInterrupted(_ model: ManagedModel) {
        try? rollback(model)
        try? FileManager.default.removeItem(at: Self.stagingURL(for: model))
    }
}

/// Folders in a model cache that no managed model uses (another FluidAudio-based app may).
public struct UnusedModelFolder: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public var url: URL
    public var bytes: Int64
}

public enum ModelInventory {
    public static func unusedFolders(in root: URL, used: Set<URL>) -> [UnusedModelFolder] {
        let usedPaths = Set(used.map { $0.standardizedFileURL.path })
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
            .filter { !usedPaths.contains($0.standardizedFileURL.path) }
            .map { UnusedModelFolder(url: $0, bytes: StorageMaintenance.size(of: $0)) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }
}
