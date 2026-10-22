import CryptoKit
import Foundation
import Testing
@testable import MeetingCore

/// A repository served from a local folder (no network).
struct FolderSource: ModelRepositorySource {
    let folder: URL
    let revision: String

    func latestRevision(repository: String) async throws -> String { revision }

    func files(repository: String, revision: String) async throws -> [RemoteModelFile] {
        try ModelUpdatePlanner.localFiles(in: folder, ignoring: []).keys.sorted().map { path in
            let url = folder.appendingPathComponent(path)
            let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            return RemoteModelFile(path: path, size: size, sha256: path.hasSuffix(".bin") ? try ContentHash.sha256(of: url) : nil,
                                   gitOid: try ContentHash.gitBlobId(of: url))
        }
    }

    func download(repository: String, revision: String, path: String, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: folder.appendingPathComponent(path), to: destination)
        progress(Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
    }
}

@Suite("Actualización de modelos")
struct ModelUpdateTests {
    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func setUp() throws -> (root: URL, remote: URL, model: ManagedModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-test-\(UUID().uuidString)")
        let remote = root.appendingPathComponent("remote"), local = root.appendingPathComponent("cache/model")
        try write("v2", "config.json", in: remote)
        try write("weights-v2", "Encoder.mlmodelc/weights/weight.bin", in: remote)
        try write("other variant", "Encoder-int8.mlmodelc/weight.bin", in: remote) // never downloaded
        try write("onnx copy", "onnx/model.onnx", in: remote)                       // not used by the library
        try write("{}", "onnx/config.json", in: remote)
        try write("{}", "onnx/config.json", in: local)
        try write("v1", "config.json", in: local)
        try write("weights-v1", "Encoder.mlmodelc/weights/weight.bin", in: local)
        try write("legacy", "Encoder.mlmodelc/old.bin", in: local)
        try write("fluid", ".fluidaudio-revision", in: local)
        let model = ManagedModel(id: "m", displayName: "M", repository: "org/m", revision: .followsMain, directory: local)
        return (root, remote, model)
    }

    @Test func gitBlobIdMatchesGit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mi-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello\n".utf8).write(to: url)
        #expect(try ContentHash.gitBlobId(of: url) == "ce013625030ba8dba906f756967f9e9ca394464a") // git hash-object
    }

    @Test func planComparesOnlyDownloadedEntriesAndFindsLeftovers() async throws {
        let (root, remote, model) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ModelInstaller(source: FolderSource(folder: remote, revision: "abc"))
        guard case .updateAvailable(let plan) = try await installer.check(model) else { Issue.record("no update"); return }
        #expect(plan.changed.map(\.path) == ["Encoder.mlmodelc/weights/weight.bin", "config.json"])
        #expect(plan.obsolete == ["Encoder.mlmodelc/old.bin"])

        let staging = try await installer.stage(model, plan: plan) { _, _ in }
        // The live model is untouched until the swap.
        #expect(try String(contentsOf: model.directory.appendingPathComponent("config.json"), encoding: .utf8) == "v1")
        try installer.swapIn(model, staging: staging)
        installer.commit(model)
        #expect(try String(contentsOf: model.directory.appendingPathComponent("config.json"), encoding: .utf8) == "v2")
        #expect(!FileManager.default.fileExists(atPath: model.directory.appendingPathComponent("Encoder.mlmodelc/old.bin").path))
        // FluidAudio's own marker is kept; ours records the verified revision.
        #expect(FileManager.default.fileExists(atPath: model.directory.appendingPathComponent(".fluidaudio-revision").path))
        #expect(try await installer.check(model) == .upToDate(revision: "abc"))
    }

    @Test func failedVerificationRollsBackAndInterruptedUpdateIsUndone() async throws {
        let (root, remote, model) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ModelInstaller(source: FolderSource(folder: remote, revision: "abc"))
        guard case .updateAvailable(let plan) = try await installer.check(model) else { Issue.record("no update"); return }
        try installer.swapIn(model, staging: try await installer.stage(model, plan: plan) { _, _ in })
        try installer.rollback(model) // e.g. the new files did not load
        #expect(try String(contentsOf: model.directory.appendingPathComponent("config.json"), encoding: .utf8) == "v1")

        // A crash between swap and commit: the next start restores the verified files.
        try installer.swapIn(model, staging: try await installer.stage(model, plan: plan) { _, _ in })
        installer.recoverInterrupted(model)
        #expect(try String(contentsOf: model.directory.appendingPathComponent("config.json"), encoding: .utf8) == "v1")
        #expect(!FileManager.default.fileExists(atPath: ModelInstaller.stagingURL(for: model).path))
    }

    @Test func pinnedAndMissingModels() async throws {
        let (root, remote, model) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ModelInstaller(source: FolderSource(folder: remote, revision: "abc"))
        var pinned = model
        pinned.revision = .pinned("df26")
        #expect(try await installer.check(pinned) == .pinned(revision: "df26"))
        var missing = model
        missing.directory = root.appendingPathComponent("none")
        #expect(try await installer.check(missing) == .notInstalled)
        let unused = ModelInventory.unusedFolders(in: root, used: [root.appendingPathComponent("remote")])
        #expect(unused.map(\.url.lastPathComponent) == ["cache"])
    }

    @Test func treePagination() {
        let response = HTTPURLResponse(url: URL(string: "https://huggingface.co")!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Link": "<https://huggingface.co/api/x?cursor=2>; rel=\"next\""])!
        #expect(HuggingFaceHub.nextPage(response)?.absoluteString == "https://huggingface.co/api/x?cursor=2")
    }
}
