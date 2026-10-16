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

    private let asr: ParakeetUltraProvider
    private let diarizer: DiarizationService

    init(asr: ParakeetUltraProvider, diarizer: DiarizationService) {
        self.asr = asr
        self.diarizer = diarizer
    }

    var asrDescriptor: ASREngineDescriptor { asr.descriptor }
    var asrCacheDirectory: URL { asr.cacheDirectory }
    var diarizerCacheDirectory: URL { diarizer.cacheDirectory }

    func refresh() async {
        if case .preparing = asrStatus {} else {
            asrStatus = await asr.isModelCached() ? .ready : .notDownloaded
        }
        if case .preparing = diarizationStatus {} else {
            diarizationStatus = await diarizer.isModelCached() ? .ready : .notDownloaded
        }
    }

    /// Downloads (first run) and loads both models. Shows real download progress.
    func prepareAll() async {
        asrStatus = .preparing("Verificando", nil)
        do {
            try await asr.prepare { [weak self] phase in
                Task { @MainActor in
                    switch phase {
                    case .checking: self?.asrStatus = .preparing("Verificando", nil)
                    case .downloading(let f): self?.asrStatus = .preparing("Descargando", f)
                    case .compiling(let name): self?.asrStatus = .preparing("Compilando \(name)", nil)
                    case .loading: self?.asrStatus = .preparing("Cargando en el Neural Engine", nil)
                    case .ready: self?.asrStatus = .ready
                    }
                }
            }
            asrStatus = .ready
        } catch {
            asrStatus = .failed(error.localizedDescription)
        }
        diarizationStatus = .preparing("Descargando y compilando", nil)
        do {
            try await diarizer.prepare()
            diarizationStatus = .ready
        } catch {
            diarizationStatus = .failed(error.localizedDescription)
        }
    }

    var allReady: Bool { asrStatus == .ready && diarizationStatus == .ready }
}
