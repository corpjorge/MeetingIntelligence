import Foundation
import Testing
@testable import MeetingCore

@Suite("Utilidades")
struct UtilityTests {
    @Test func timecodes() {
        #expect(Timecode.hms(872.9) == "00:14:32")
        #expect(Timecode.compact(65) == "1:05")
        #expect(Timecode.compact(3725) == "1:02:05")
        #expect(Timecode.srt(75.2) == "00:01:15,200")
        #expect(Timecode.humanDuration(3900) == "1 h 05 min")
    }

    @Test func comparableNormalization() {
        #expect(TextNormalization.comparable("¡Validación  del RESPONSE!") == "validacion del response")
        #expect(TextNormalization.searchTerms(from: "¿Qué dijo Katty sobre viabilidad inicial?") == ["katty", "viabilidad", "inicial"])
    }

    @Test func vocabularyCorrectionWholeWordsOnly() throws {
        let corrector = VocabularyCorrector(terms: [
            VocabularyTerm(canonical: "Katty", variants: ["Cati", "Katy"]),
            VocabularyTerm(canonical: "endpoint", variants: ["en point"]),
            VocabularyTerm(canonical: "Kubernetes", variants: ["cubernetes", "kubernete"]),
        ])
        let result = try #require(corrector.apply(to: "cati dijo que el en point de cubernetes falla; Catira no aplica"))
        #expect(result.text == "Katty dijo que el endpoint de Kubernetes falla; Catira no aplica")
        #expect(result.replacements.count == 3)
        #expect(corrector.apply(to: "nada que corregir") == nil)
        // Canonical already correct → untouched.
        #expect(corrector.apply(to: "Katty y Kubernetes") == nil)
    }

    @Test func lowConfidenceFlagClearsOnceReviewed() {
        func segment(_ confidence: Double?) -> TranscriptSegment {
            TranscriptSegment(transcriptId: "t", meetingId: "m", trackId: "k", source: .localMicrophone, orderIndex: 0,
                              startTime: 0, endTime: 1, asrText: "Wie er ist da?", asrConfidence: confidence)
        }
        #expect(segment(0.52).isLowConfidence)
        #expect(!segment(0.7).isLowConfidence)
        #expect(!segment(0.91).isLowConfidence)
        #expect(!segment(nil).isLowConfidence)
        var edited = segment(0.52)
        edited.editedText = "¿Ya está?"
        #expect(!edited.isLowConfidence)
    }
}

@Suite("Cifrado biométrico")
struct BiometricVaultTests {
    @Test func roundTripAndTamperDetection() throws {
        let keys = EphemeralBiometricKeyProvider()
        let vault = BiometricVault(keyProvider: keys)
        let embedding: [Float] = (0..<256).map { Float($0) / 255 }
        let sealed = try vault.seal(embedding)
        #expect(sealed.count > embedding.count * 4) // nonce + tag overhead
        // Ciphertext must not contain the raw float bytes.
        let raw = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        #expect(sealed.range(of: raw.prefix(64)) == nil)
        #expect(try vault.open(sealed) == embedding)

        var tampered = sealed
        tampered[tampered.count / 2] ^= 0xFF
        #expect(throws: (any Error).self) { try vault.open(tampered) }
    }

    @Test func destroyingKeyRevokesAccess() throws {
        let keys = EphemeralBiometricKeyProvider()
        let vault = BiometricVault(keyProvider: keys)
        let sealed = try vault.seal([0.1, 0.2, 0.3])
        try keys.destroyKey()
        #expect(throws: (any Error).self) { try vault.open(sealed) }
    }
}
