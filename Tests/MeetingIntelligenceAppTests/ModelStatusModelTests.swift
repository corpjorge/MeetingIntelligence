import Foundation
import MeetingSpeech
import Testing
@testable import MeetingIntelligenceApp

/// First-run model setup: the banner must end on "ready", never back on "Descargar".
@Suite("App: estado de los modelos")
@MainActor
struct ModelStatusModelTests {
    final class Fake: @unchecked Sendable {
        var asrCached = false
        var diarizerCached = false
        var diarizerStarted = false
        var releaseDiarizer: CheckedContinuation<Void, Never>?
        var lateProgress: (@Sendable (ModelPreparationPhase) -> Void)?
    }

    private func model(_ fake: Fake) -> ModelStatusModel {
        let asr = ParakeetUltraProvider()
        return ModelStatusModel(asrDescriptor: asr.descriptor, asrCacheDirectory: asr.cacheDirectory,
                                diarizerCacheDirectory: FileManager.default.temporaryDirectory,
                                backend: .init(
            asrCached: { fake.asrCached },
            prepareASR: { progress in
                progress(.checking)
                progress(.downloading(fraction: 0.5))
                progress(.ready)
                fake.lateProgress = progress
                fake.asrCached = true
            },
            diarizerCached: { fake.diarizerCached },
            prepareDiarizer: {
                await withCheckedContinuation { fake.releaseDiarizer = $0; fake.diarizerStarted = true }
                fake.diarizerCached = true
            }))
    }

    @Test func firstDownloadEndsReadyAndIgnoresLateProgress() async throws {
        let fake = Fake()
        let models = model(fake)
        await models.refresh()
        #expect(models.asrStatus == .notDownloaded && models.diarizationStatus == .notDownloaded)

        let prepare = Task { await models.prepareAll() }
        try await waitUntil { fake.diarizerStarted }
        // Parakeet is ready but diarization is still preparing: the banner reports it, not "Descargar".
        #expect(models.asrStatus == .ready)
        #expect(models.preparingStep?.model == "Diarización")
        #expect(!models.allReady)

        // A progress callback that lands after Parakeet finished must not bring back "preparing".
        fake.lateProgress?(.downloading(fraction: 0.9))
        try await Task.sleep(for: .milliseconds(50))
        #expect(models.asrStatus == .ready)

        fake.releaseDiarizer?.resume()
        await prepare.value
        fake.lateProgress?(.loading)
        try await Task.sleep(for: .milliseconds(50))
        #expect(models.allReady)
        #expect(models.preparingStep == nil && models.failure == nil)
    }

    @Test func refreshPicksUpModelsLoadedByProcessing() async {
        let fake = Fake()
        let models = model(fake)
        await models.refresh()
        #expect(!models.allReady)
        fake.asrCached = true
        fake.diarizerCached = true
        await models.refresh()
        #expect(models.allReady)
    }
}
