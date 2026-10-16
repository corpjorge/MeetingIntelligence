public import Foundation
public import MeetingCore
import OSLog

public struct RecognitionReport: Sendable {
    public var accepted: Int
    public var suggested: Int
    public var unknown: Int
    public var calibration: SpeakerCalibration?

    public var summary: String {
        let mode = calibration == nil ? "sin calibrar (solo sugerencias)" : "calibrado"
        return "\(accepted) reconocidos, \(suggested) sugeridos, \(unknown) desconocidos — \(mode)"
    }
}

public enum EnrollmentError: LocalizedError, Sendable {
    case noSpeech
    case multipleSpeakers(Int)
    case tooShort(Double)
    case consentRequired

    public var errorDescription: String? {
        switch self {
        case .noSpeech: "No se detectó voz en la muestra."
        case .multipleSpeakers(let n):
            "La muestra contiene \(n) voces. Usa una grabación donde hable solo la persona que se registra."
        case .tooShort(let s):
            "La muestra tiene \(String(format: "%.1f", s)) s de voz; se necesitan al menos 8 s."
        case .consentRequired: "Se requiere el consentimiento explícito de la persona."
        }
    }
}

/// Persistent identification of consented participants by voice.
///
/// Embeddings are WeSpeaker vectors produced by the *same* offline diarization
/// pipeline for enrollment samples and meeting clusters, so they are directly
/// comparable. Everything biometric is sealed with `BiometricVault` and never
/// leaves this Mac (not exported, not exposed via MCP, never sent to AI providers).
public actor SpeakerRecognitionService {
    private let database: AppDatabase
    private let vault: BiometricVault
    private let diarizer: DiarizationService
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "speaker-recognition")
    public var minimumEnrollmentSpeechSeconds: Double = 8

    public init(database: AppDatabase, vault: BiometricVault, diarizer: DiarizationService) {
        self.database = database
        self.vault = vault
        self.diarizer = diarizer
    }

    public nonisolated func seal(_ embedding: [Float]) throws -> Data {
        try vault.seal(embedding)
    }

    // MARK: Enrollment

    /// Registers an authorized voice sample (single speaker) for a participant.
    @discardableResult
    public func enroll(participantId: String, audioURL: URL, consentStatement: String,
                       retentionDays: Int?) async throws -> VoiceSample {
        let consent = consentStatement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !consent.isEmpty else { throw EnrollmentError.consentRequired }
        let output = try await diarizer.diarize(fileURL: audioURL) { _ in }
        let speech = output.speechByCluster
        guard let dominant = speech.first, let embedding = output.embeddings[dominant.key] else {
            throw EnrollmentError.noSpeech
        }
        // Reject samples where a second voice has meaningful speech.
        let others = speech.dropFirst().filter { $0.seconds >= 2 }
        guard others.isEmpty else { throw EnrollmentError.multipleSpeakers(others.count + 1) }
        guard dominant.seconds >= minimumEnrollmentSpeechSeconds else { throw EnrollmentError.tooShort(dominant.seconds) }

        let profile = try database.createProfile(participantId: participantId, consentStatement: consent,
                                                 retentionDays: retentionDays)
        let sample = VoiceSample(profileId: profile.id, origin: .enrollment, durationSeconds: dominant.seconds,
                                 embeddingCiphertext: try vault.seal(embedding), embeddingModel: output.modelIdentifier)
        try database.add(sample: sample)
        logger.info("Enrolled voice sample (\(dominant.seconds, format: .fixed(precision: 1)) s)")
        return sample
    }

    /// Adds a meeting cluster's embedding to a participant's profile after the
    /// user has validated the identity. The profile must already exist with consent.
    @discardableResult
    public func addValidatedSample(meetingSpeakerId: String, participantId: String) throws -> VoiceSample {
        guard let profile = try database.profile(participantId: participantId), profile.status == .active else {
            throw EnrollmentError.consentRequired
        }
        guard let speaker = try database.meetingSpeakers(meetingId: try meetingId(of: meetingSpeakerId))
                .first(where: { $0.id == meetingSpeakerId }),
              let cipher = speaker.embeddingCiphertext, let model = speaker.embeddingModel else {
            throw AppDatabaseError.invalidOperation("Este hablante no tiene una huella de voz disponible.")
        }
        guard speaker.totalSpeechSeconds >= minimumEnrollmentSpeechSeconds else {
            throw EnrollmentError.tooShort(speaker.totalSpeechSeconds)
        }
        let sample = VoiceSample(profileId: profile.id, origin: .validatedMeetingSegment, meetingId: speaker.meetingId,
                                 durationSeconds: speaker.totalSpeechSeconds, embeddingCiphertext: cipher,
                                 embeddingModel: model)
        try database.add(sample: sample)
        return sample
    }

    private func meetingId(of speakerId: String) throws -> String {
        try database.reader.read { db in
            guard let id = try String.fetchOne(db, sql: "SELECT meetingId FROM meetingSpeaker WHERE id = ?", arguments: [speakerId]) else {
                throw AppDatabaseError.notFound("hablante \(speakerId)")
            }
            return id
        }
    }

    // MARK: Calibration & recognition

    public func enrolledVoices(model: String = DiarizationService.modelIdentifier) throws -> [EnrolledVoice] {
        try database.activeVoiceSamples(embeddingModel: model).map { entry in
            EnrolledVoice(participantId: entry.profile.participantId,
                          samples: entry.samples.compactMap { try? vault.open($0.embeddingCiphertext) })
        }.filter { !$0.samples.isEmpty }
    }

    public func calibration() throws -> SpeakerCalibration? {
        SpeakerCalibration.derive(from: try enrolledVoices())
    }

    /// Matches every diarized cluster of a meeting against enrolled voices and
    /// records the decision (with scores) for each one.
    public func recognize(meetingId: String) async throws -> RecognitionReport {
        try database.enforceProfileRetention()
        let voices = try enrolledVoices()
        let calibration = SpeakerCalibration.derive(from: voices)
        let matcher = SpeakerMatcher(calibration: calibration)
        var report = RecognitionReport(accepted: 0, suggested: 0, unknown: 0, calibration: calibration)
        guard !voices.isEmpty else { return report }

        let speakers = try database.meetingSpeakers(meetingId: meetingId).filter {
            $0.embeddingModel == DiarizationService.modelIdentifier && $0.embeddingCiphertext != nil
        }
        var queries: [(MeetingSpeaker, [Float])] = []
        for speaker in speakers {
            if let cipher = speaker.embeddingCiphertext, let embedding = try? vault.open(cipher) {
                queries.append((speaker, embedding))
            }
        }
        var decisions = queries.map { matcher.decide(query: $0.1, speechSeconds: $0.0.totalSpeechSeconds, voices: voices) }

        // Without calibration, keep a suggestion only when cluster and profile are
        // each other's best match in this meeting (relative, data-driven filter).
        if calibration == nil {
            for i in decisions.indices {
                guard let best = decisions[i].best else { continue }
                let bestClusterForProfile = decisions.indices.max {
                    (decisions[$0].best?.participantId == best.participantId ? decisions[$0].best!.similarity : -2)
                        < (decisions[$1].best?.participantId == best.participantId ? decisions[$1].best!.similarity : -2)
                }
                if bestClusterForProfile != i {
                    decisions[i].outcome = .unknown
                    decisions[i].reason = "Otro hablante de la reunión se parece más a este perfil."
                }
            }
        }

        for ((speaker, _), decision) in zip(queries, decisions) {
            // Never override a manual decision already made for this speaker.
            if speaker.participantId != nil, speaker.source != .localMicrophone { continue }
            if speaker.source == .localMicrophone, speaker.participantId != nil { continue }
            try database.applyRecognition(meetingSpeakerId: speaker.id, decision: decision)
            switch decision.outcome {
            case .accepted: report.accepted += 1
            case .suggested: report.suggested += 1
            case .unknown: report.unknown += 1
            }
        }
        return report
    }
}
