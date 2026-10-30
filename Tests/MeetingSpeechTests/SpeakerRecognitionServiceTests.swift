import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingSpeech

@Suite("Muestras de voz validadas en una reunión")
struct ValidatedSampleTests {
    @Test func minimumSpeechCountsOnlyTheClusterOwnVoice() async throws {
        let db = try AppDatabase.inMemory()
        let vault = BiometricVault(keyProvider: EphemeralBiometricKeyProvider())
        let service = SpeakerRecognitionService(database: db, vault: vault, diarizer: DiarizationService())
        let meeting = Meeting(title: "FIXTURE", origin: .imported, captureScope: .importedFile, status: .ready)
        let track = AudioTrack(meetingId: meeting.id, source: .imported, relativePath: "fixture.wav",
                               sampleRate: 16_000, channelCount: 1, durationSeconds: 60)
        try db.insert(meeting: meeting, tracks: [track])
        let transcript = Transcript(meetingId: meeting.id, trackId: track.id, engine: "test", modelIdentifier: "test",
                                    language: "es-CO", isFinal: true, audioDurationSeconds: 60, processingSeconds: 1,
                                    meanConfidence: nil)
        func speaker(_ key: String, _ ordinal: Int, seconds: Double) throws -> MeetingSpeaker {
            MeetingSpeaker(meetingId: meeting.id, source: .imported, clusterKey: key, ordinal: ordinal,
                           totalSpeechSeconds: seconds, embeddingCiphertext: try vault.seal([0.6, 0.8]),
                           embeddingModel: DiarizationService.modelIdentifier)
        }
        func segment(_ speaker: MeetingSpeaker, _ start: Double, _ end: Double,
                     attribution: AttributionStatus = .diarized) -> TranscriptSegment {
            TranscriptSegment(transcriptId: transcript.id, meetingId: meeting.id, trackId: track.id, source: .imported,
                              orderIndex: Int(start), startTime: start, endTime: end, asrText: "texto",
                              meetingSpeakerId: speaker.id, attribution: attribution)
        }
        let a = try speaker("S1", 1, seconds: 5), b = try speaker("S2", 2, seconds: 6), c = try speaker("S3", 3, seconds: 9)
        try db.storeProcessedTrack(transcript: transcript,
                                   segments: [segment(a, 0, 5), segment(a, 20, 30, attribution: .probableEcho),
                                              segment(b, 10, 16), segment(c, 40, 49)],
                                   speakers: [a, b, c], assignments: [])
        let participant = Participant(displayName: "FIXTURE Ana")
        try db.save(participant: participant)
        try db.createProfile(participantId: participant.id, consentStatement: "Consiento", retentionDays: nil)
        try db.mergeSpeakers(b.id, into: a.id)
        let merged = try #require(try db.meetingSpeakers(meetingId: meeting.id).first { $0.id == a.id })
        #expect(merged.totalSpeechSeconds >= 8)

        let error = await #expect(throws: EnrollmentError.self) {
            try await service.addValidatedSample(meetingSpeakerId: a.id, participantId: participant.id)
        }
        guard case .tooShort(let seconds)? = error else {
            Issue.record("se esperaba tooShort")
            return
        }
        #expect(abs(seconds - 5) < 1e-9)

        let sample = try await service.addValidatedSample(meetingSpeakerId: c.id, participantId: participant.id)
        #expect(abs(sample.durationSeconds - 9) < 1e-9)
        #expect(sample.meetingId == meeting.id)
    }
}
