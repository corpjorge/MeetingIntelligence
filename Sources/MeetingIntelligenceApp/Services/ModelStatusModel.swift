import Foundation
import MeetingSpeech

/// Setup state of the local models shown in onboarding, dashboard and settings.
@Observable
final class ModelStatusModel {
    enum Status: Equatable {
        case unknown
        case notDownloaded
        case preparing(String, Double?)
        case ready
        case failed(String)
    }

    private(set) var asrStatus: Status = .unknown
    private(set) var diarizationStatus: Status = .unknown
    private var isPreparing = false

    /// Model operations; replaceable in tests.
    struct Backend {
        var asrCached: () async -> Bool
        var prepareASR: (@escaping @Sendable (ModelPreparationPhase) -> Void) async throws -> Void
        var diarizerCached: () async -> Bool
        var prepareDiarizer: () async throws -> Void
    }

    let asrDescriptor: ASREngineDescriptor
    let asrCacheDirectory: URL
    let diarizerCacheDirectory: URL
    private let backend: Backend

    convenience init(asr: ParakeetUltraProvider, diarizer: DiarizationService) {
        self.init(asrDescriptor: asr.descriptor, asrCacheDirectory: asr.cacheDirectory,
                  diarizerCacheDirectory: diarizer.cacheDirectory,
                  backend: Backend(asrCached: { await asr.isModelCached() },
                                   prepareASR: { try await asr.prepare(progress: $0) },
                                   diarizerCached: { await diarizer.isModelCached() },
                                   prepareDiarizer: { try await diarizer.prepare() }))
    }

    init(asrDescriptor: ASREngineDescriptor, asrCacheDirectory: URL, diarizerCacheDirectory: URL, backend: Backend) {
        self.asrDescriptor = asrDescriptor
        self.asrCacheDirectory = asrCacheDirectory
        self.diarizerCacheDirectory = diarizerCacheDirectory
        self.backend = backend
    }

    /// Reads the caches. Also picks up models downloaded outside `prepareAll` (processing or live
    /// transcription load them on first use); a failure is kept until the model is actually cached.
    func refresh() async {
        guard !isPreparing else { return }
        let asrCached = await backend.asrCached()
        let diarizerCached = await backend.diarizerCached()
        guard !isPreparing else { return }
        asrStatus = Self.cachedStatus(asrCached, previous: asrStatus)
        diarizationStatus = Self.cachedStatus(diarizerCached, previous: diarizationStatus)
    }

    private static func cachedStatus(_ cached: Bool, previous: Status) -> Status {
        if cached { return .ready }
        if case .failed = previous { return previous }
        return .notDownloaded
    }

    /// Downloads (first run) and loads both models. Shows real download progress.
    func prepareAll() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        asrStatus = .preparing("Verificando", nil)
        diarizationStatus = diarizationStatus == .ready ? .ready : .notDownloaded
        do {
            try await backend.prepareASR { [weak self] phase in
                Task { @MainActor in self?.apply(phase) }
            }
            asrStatus = .ready
        } catch {
            asrStatus = .failed(ProcessingErrorText.describe(error))
        }
        diarizationStatus = .preparing("Descargando y compilando", nil)
        do {
            try await backend.prepareDiarizer()
            diarizationStatus = .ready
        } catch {
            diarizationStatus = .failed(ProcessingErrorText.describe(error))
        }
    }

    /// Progress callbacks hop to the main actor in separate tasks; one arriving after the model is
    /// ready (or after `prepareAll` returned) must not bring back "preparing".
    private func apply(_ phase: ModelPreparationPhase) {
        guard isPreparing, asrStatus != .ready else { return }
        switch phase {
        case .checking: asrStatus = .preparing("Verificando", nil)
        case .downloading(let f): asrStatus = .preparing("Descargando", f)
        case .compiling(let name): asrStatus = .preparing("Compilando \(name)", nil)
        case .loading: asrStatus = .preparing("Cargando en el Neural Engine", nil)
        case .ready: asrStatus = .ready
        }
    }

    var allReady: Bool { asrStatus == .ready && diarizationStatus == .ready }

    /// The model the setup banner reports: the one being prepared, else the one that failed.
    var preparingStep: (model: String, text: String, fraction: Double?)? {
        if case .preparing(let text, let fraction) = asrStatus { return ("Parakeet Ultra", text, fraction) }
        if case .preparing(let text, let fraction) = diarizationStatus { return ("Diarización", text, fraction) }
        return nil
    }

    var failure: (model: String, message: String)? {
        if case .failed(let message) = asrStatus { return ("Parakeet Ultra", message) }
        if case .failed(let message) = diarizationStatus { return ("La diarización", message) }
        return nil
    }
}
