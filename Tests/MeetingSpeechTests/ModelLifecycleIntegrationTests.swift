import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingSpeech

final class FractionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func append(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}

@Suite("Integración: cancelación y ciclo de vida de los modelos",
       .enabled(if: IntegrationEnvironment.available), .serialized)
struct ModelLifecycleIntegrationTests {
    @Test func cancelledCallerDoesNotWaitForTheSharedPreparation() async throws {
        let provider = ParakeetUltraProvider()
        let phases = PhaseRecorder()
        let first = Task { try await provider.prepare { phases.append($0) } }
        let second = Task { try await provider.prepare { _ in } }
        try await Task.sleep(for: .milliseconds(20))
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        second.cancel()
        _ = try? await second.value
        #expect(clock.now - cancelledAt < .milliseconds(500))
        try await first.value
        #expect(phases.values.last == .ready)
        await provider.unload()
    }

    @Test func unloadWaitsForTheTranscriptionInProgress() async throws {
        let provider = ParakeetUltraProvider()
        try await provider.prepare { _ in }
        let url = IntegrationEnvironment.fixtures.appendingPathComponent("es_single_speaker.wav")
        let transcription = Task { try await provider.transcribe(fileURL: url, languageHint: "es-CO") { _ in } }
        try await Task.sleep(for: .milliseconds(100))
        await provider.unload()
        let result = try await transcription.value
        #expect(!result.words.isEmpty)
        await provider.unload()
    }

    @Test func longTrackAfterAShortOneStillReportsProgress() async throws {
        let provider = ParakeetUltraProvider()
        _ = try await provider.transcribe(
            fileURL: IntegrationEnvironment.fixtures.appendingPathComponent("es_isolated_word.wav"),
            languageHint: "es-CO") { _ in }
        let fractions = FractionRecorder()
        _ = try await provider.transcribe(
            fileURL: IntegrationEnvironment.fixtures.appendingPathComponent("es_single_speaker.wav"),
            languageHint: "es-CO") { fractions.append($0) }
        #expect(fractions.values.contains { $0 < 1 }, "\(fractions.values)")
        await provider.unload()
    }

    @Test func cancelledEnrollmentWritesNothing() async throws {
        let db = try AppDatabase.inMemory()
        let participant = Participant(displayName: "FIXTURE Ana")
        try db.save(participant: participant)
        let service = SpeakerRecognitionService(database: db,
                                                vault: BiometricVault(keyProvider: EphemeralBiometricKeyProvider()),
                                                diarizer: DiarizationService())
        let url = IntegrationEnvironment.fixtures.appendingPathComponent("es_single_speaker.wav")
        let cancelled = Task {
            try await service.enroll(participantId: participant.id, audioURL: url, consentStatement: "Consiento",
                                     retentionDays: nil)
        }
        cancelled.cancel()
        await #expect(throws: (any Error).self) { try await cancelled.value }
        #expect(try db.profile(participantId: participant.id) == nil)

        let sample = try await service.enroll(participantId: participant.id, audioURL: url,
                                              consentStatement: "Consiento", retentionDays: nil)
        let profile = try #require(try db.profile(participantId: participant.id))
        #expect(try db.samples(profileId: profile.id).map(\.id) == [sample.id])
    }
}
