import FluidAudio
import Testing
@testable import MeetingSpeech

@Suite("Mensajes de error del pipeline")
struct ProcessingErrorTextTests {
    @Test func fluidAudioErrorsAreShownInSpanish() {
        #expect(ProcessingErrorText.describe(OfflineDiarizationError.noSpeechDetected)
            == "No se detectó voz suficiente para diarizar el audio.")
        #expect(ProcessingErrorText.describe(OfflineDiarizationError.processingFailed("x")) == "La diarización falló: x")
        #expect(ProcessingErrorText.describe(ASRError.modelLoadFailed) == "no se pudieron cargar los modelos Core ML de Parakeet")
        // Our own errors keep their (already Spanish) description.
        #expect(ProcessingErrorText.describe(ASRProviderError.emptyAudio) == "El audio es demasiado corto o está vacío.")
    }
}
