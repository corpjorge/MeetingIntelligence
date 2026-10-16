public import Foundation
public import MeetingCore

/// Identity and provenance of an ASR engine.
public struct ASREngineDescriptor: Sendable, Hashable {
    /// Stable engine id persisted with transcripts (e.g. `parakeet-ultra`).
    public var id: String
    public var displayName: String
    /// Exact model + library provenance.
    public var modelIdentifier: String
    /// Approximate on-disk size of the model bundle (for the setup UI).
    public var approximateDownloadBytes: Int64
}

public enum ModelPreparationPhase: Sendable, Equatable {
    case checking
    case downloading(fraction: Double)
    case compiling(String)
    case loading
    case ready
}

/// Result of one ASR pass over one file.
public struct ASRTranscription: Sendable {
    public var text: String
    /// Word timings on the file's own timeline (seconds).
    public var words: [WordTiming]
    public var meanConfidence: Double?
    public var audioDurationSeconds: Double
    public var processingSeconds: Double
}

/// Contract implemented by every speech-to-text engine. The primary engine is
/// Parakeet Ultra; others can be added without touching the pipeline.
public protocol ASRProvider: Sendable {
    var descriptor: ASREngineDescriptor { get }

    /// True when the model files are already on disk (no network needed).
    func isModelCached() async -> Bool

    /// Downloads (first run only) and loads the model. Idempotent; concurrent
    /// callers share one preparation.
    func prepare(progress: @escaping @Sendable (ModelPreparationPhase) -> Void) async throws

    /// Final (non-provisional) transcription of an audio file. Honors task cancellation.
    func transcribe(fileURL: URL, languageHint: String,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> ASRTranscription

    /// Releases loaded models (memory pressure / settings change).
    func unload() async
}

public enum ASRProviderError: LocalizedError, Sendable {
    case modelUnavailable(String)
    case emptyAudio
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let detail):
            "El modelo Parakeet Ultra no está disponible: \(detail). No se usará otro modelo en su lugar."
        case .emptyAudio:
            "El audio es demasiado corto o está vacío."
        case .failed(let detail):
            "La transcripción falló: \(detail)"
        }
    }
}
