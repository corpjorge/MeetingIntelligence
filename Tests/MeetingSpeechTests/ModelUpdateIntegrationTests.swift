import FluidAudio
import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingSpeech

/// Real Hugging Face round trip on a COPY of the cached CTC 110M model (the cache itself is
/// never touched). Needs network: runs only with `MI_NETWORK_TESTS=1` and the model cached.
@Suite("Integración: actualizar un modelo desde Hugging Face",
       .enabled(if: ProcessInfo.processInfo.environment["MI_NETWORK_TESTS"] == "1"
                && AcousticVocabularyBooster().isModelCached()))
struct ModelUpdateIntegrationTests {
    @Test func outdatedCopyIsRepairedAndStillLoads() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mi-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let real = AcousticVocabularyBooster().managedModel(inUse: true)
        var model = real
        model.directory = root.appendingPathComponent(real.directory.lastPathComponent)
        try fm.copyItem(at: real.directory, to: model.directory)
        try? fm.removeItem(at: model.directory.appendingPathComponent(ModelUpdatePlanner.revisionMarker))

        let installer = ModelInstaller()
        #expect(try await installer.check(model) == .upToDate(revision: try await HuggingFaceHub().latestRevision(repository: model.repository)))

        // Simulate an older revision: a changed root file, a changed file inside a model bundle,
        // and a leftover that the new revision no longer has.
        try? fm.removeItem(at: model.directory.appendingPathComponent(ModelUpdatePlanner.revisionMarker))
        try Data("{}".utf8).write(to: model.directory.appendingPathComponent("config.json"))
        try Data("x".utf8).write(to: model.directory.appendingPathComponent("MelSpectrogram.mlmodelc/metadata.json"))
        try Data("old".utf8).write(to: model.directory.appendingPathComponent("MelSpectrogram.mlmodelc/legacy.bin"))

        guard case .updateAvailable(let plan) = try await installer.check(model) else {
            Issue.record("expected an update"); return
        }
        #expect(Set(plan.changed.map(\.path)) == ["config.json", "MelSpectrogram.mlmodelc/metadata.json"])
        #expect(plan.obsolete == ["MelSpectrogram.mlmodelc/legacy.bin"])
        #expect(plan.downloadBytes < 1_000_000)

        let staging = try await installer.stage(model, plan: plan) { _, _ in }
        try installer.swapIn(model, staging: staging)
        _ = try await CtcModels.load(from: model.directory, variant: .ctc110m)
        installer.commit(model)
        #expect(!fm.fileExists(atPath: ModelInstaller.backupURL(for: model).path))
        #expect(!fm.fileExists(atPath: model.directory.appendingPathComponent("MelSpectrogram.mlmodelc/legacy.bin").path))
        #expect(try await installer.check(model) == .upToDate(revision: plan.revision))
    }
}
