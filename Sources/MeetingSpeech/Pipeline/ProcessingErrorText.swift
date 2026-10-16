public import Foundation
@preconcurrency import FluidAudio

/// User-facing Spanish descriptions for errors raised inside the pipeline.
/// FluidAudio's own messages are English; our errors already describe themselves.
public enum ProcessingErrorText {
    public static func describe(_ error: any Error) -> String {
        switch error {
        case let error as OfflineDiarizationError: describe(error)
        case let error as ASRError: describe(error)
        default: error.localizedDescription
        }
    }

    static func describe(_ error: OfflineDiarizationError) -> String {
        switch error {
        case .modelNotLoaded(let name): "El modelo de diarización no está cargado (\(name))."
        case .invalidConfiguration(let detail): "La configuración de diarización no es válida: \(detail)"
        case .invalidBatchSize(let detail): "El tamaño de lote de diarización no es válido: \(detail)"
        case .processingFailed(let detail): "La diarización falló: \(detail)"
        case .noSpeechDetected: "No se detectó voz suficiente para diarizar el audio."
        case .exportFailed(let detail): "No se pudieron exportar los datos de diarización: \(detail)"
        }
    }

    static func describe(_ error: ASRError) -> String {
        switch error {
        case .notInitialized: "el modelo de transcripción no está inicializado"
        case .invalidAudioData: "el audio no es válido (se requieren al menos 300 ms a 16 kHz)"
        case .modelLoadFailed: "no se pudieron cargar los modelos Core ML de Parakeet"
        case .processingFailed(let detail): "error del modelo (\(detail))"
        case .modelCompilationFailed: "la compilación Core ML del modelo falló tras reintentar"
        case .unsupportedPlatform(let detail): "plataforma no compatible (\(detail))"
        case .streamingConversionFailed(let underlying): "falló la conversión de audio (\(underlying.localizedDescription))"
        case .fileAccessFailed(let url, _): "no se pudo leer el archivo \(url.lastPathComponent)"
        case .encoderInstantiationFailed(let detail): "no se pudo crear el codificador (\(detail))"
        }
    }
}
