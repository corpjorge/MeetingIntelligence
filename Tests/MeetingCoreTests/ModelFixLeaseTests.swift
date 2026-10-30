import Foundation
import Testing
@testable import MeetingCore

@Suite("Actualización de modelos: bloqueo entre procesos")
struct ModelFixLeaseTests {
    private func setUp() throws -> (root: URL, model: ManagedModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-test-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("cache/model")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: directory.appendingPathComponent("config.json"))
        return (root, ManagedModel(id: "m", displayName: "M", repository: "org/m", revision: .followsMain, directory: directory))
    }

    private func config(_ model: ManagedModel) throws -> String {
        try String(contentsOf: model.directory.appendingPathComponent("config.json"), encoding: .utf8)
    }

    private func isBusy(_ error: any Error) -> Bool {
        if case .busy = error as? ModelInstallError { return true }
        return false
    }

    @Test func onlyOneLeasePerModel() throws {
        let (root, model) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ModelInstaller()
        let first = try installer.beginUpdate(model)
        let error = #expect(throws: ModelInstallError.self) { try installer.beginUpdate(model) }
        #expect(error?.localizedDescription == "No se puede actualizar mientras otro proceso está actualizando este modelo.")
        first.release()
        first.release()
        try installer.beginUpdate(model).release()
        do {
            let scoped = try installer.beginUpdate(model)
            _ = scoped
        }
        try installer.beginUpdate(model).release()
        #expect(FileManager.default.fileExists(atPath: ModelInstaller.lockURL(for: model).path))
        #expect(ModelInventory.unusedFolders(in: model.directory.deletingLastPathComponent(), used: [model.directory]).isEmpty)
    }

    @Test func recoveryLeavesAnUpdateInProgressAlone() throws {
        let (root, model) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let staging = ModelInstaller.stagingURL(for: model), backup = ModelInstaller.backupURL(for: model)
        try fm.copyItem(at: model.directory, to: backup)
        try Data("v2".utf8).write(to: model.directory.appendingPathComponent("config.json"))
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let installer = ModelInstaller()

        let lease = try installer.beginUpdate(model)
        installer.recoverInterrupted(model)
        #expect(try config(model) == "v2")
        #expect(fm.fileExists(atPath: backup.path) && fm.fileExists(atPath: staging.path))

        lease.release()
        installer.recoverInterrupted(model)
        #expect(try config(model) == "v1")
        #expect(!fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: staging.path))
    }

    @Test func anotherProcessHoldingTheLockBlocksTheUpdate() async throws {
        let (root, model) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ModelInstaller()
        let holder = Process()
        let stdin = Pipe()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        holder.arguments = ["-k", ModelInstaller.lockURL(for: model).path, "/bin/cat"]
        holder.standardInput = stdin
        holder.standardOutput = FileHandle.nullDevice
        try holder.run()
        var blocked = false
        for _ in 0..<50 where !blocked {
            do {
                try installer.beginUpdate(model).release()
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                blocked = isBusy(error)
            }
        }
        try stdin.fileHandleForWriting.close()
        holder.waitUntilExit()
        #expect(blocked)
        try installer.beginUpdate(model).release()
    }
}
