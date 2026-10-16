import Foundation
public import MeetingCore
import OSLog

public struct ProcessingOptions: Sendable, Hashable {
    /// BCP-47 language of the meeting (Spanish by default; English terms are kept).
    public var language: String = "es-CO"
    /// Diarize remote / imported audio to separate speakers.
    public var diarize: Bool = true
    /// Diarize the microphone too, so other people speaking near the mic are
    /// never silently attributed to the local user.
    public var detectMultipleLocalSpeakers: Bool = true
    /// Flag microphone segments that repeat remote speech (speaker echo).
    public var flagEcho: Bool = true
    /// A local cluster needs at least this much non-echo speech to count as a
    /// separate person (shorter clusters are usually coughs/noise/echo residue).
    public var minimumLocalSpeakerSeconds: Double = 4

    public init() {}
}

public struct PipelineProgress: Sendable, Equatable {
    public var meetingId: String
    public var stage: ProcessingStage
    public var source: AudioSource?
    /// 0…1, or nil while the stage cannot report real progress.
    public var fraction: Double?
    public var message: String
}

public struct ProcessingSummary: Sendable {
    public struct TrackSummary: Sendable {
        public var source: AudioSource
        public var audioSeconds: Double
        public var asrSeconds: Double
        public var diarizationSeconds: Double?
        public var words: Int
        public var segments: Int
        public var speakers: Int
        public var echoSegments: Int
    }
    public var tracks: [TrackSummary]
    public var totalSeconds: Double
}

/// Runs the offline pipeline for one meeting:
/// Parakeet Ultra → diarization → word/speaker alignment → echo flagging →
/// speaker recognition → persistence. Each stage is recorded as a
/// `ProcessingJob` with real timings and memory.
public actor MeetingProcessor {
    private let database: AppDatabase
    private let paths: AppPaths
    private let asr: any ASRProvider
    private let diarizer: DiarizationService
    private let recognizer: SpeakerRecognitionService?
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "pipeline")

    public init(database: AppDatabase, paths: AppPaths, asr: any ASRProvider,
                diarizer: DiarizationService, recognizer: SpeakerRecognitionService?) {
        self.database = database
        self.paths = paths
        self.asr = asr
        self.diarizer = diarizer
        self.recognizer = recognizer
    }

    @discardableResult
    public func process(meetingId: String, options: ProcessingOptions = ProcessingOptions(),
                        progress: @escaping @Sendable (PipelineProgress) -> Void) async throws -> ProcessingSummary {
        guard let detail = try database.meetingDetail(id: meetingId) else {
            throw AppDatabaseError.notFound("reunión \(meetingId)")
        }
        let tracks = detail.tracks.sorted { Self.order($0.source) < Self.order($1.source) }
        guard !tracks.isEmpty else { throw AppDatabaseError.invalidOperation("La reunión no tiene pistas de audio.") }
        let previousStatus = detail.meeting.status
        let started = Date()
        try database.updateMeeting(id: meetingId) { $0.status = .processing; $0.lastError = nil }

        do {
            let summary = try await run(meetingId: meetingId, tracks: tracks, options: options, progress: progress)
            let duration = tracks.map { $0.durationSeconds + $0.timelineOffsetSeconds }.max() ?? 0
            try database.updateMeeting(id: meetingId) {
                $0.status = .ready
                $0.durationSeconds = max($0.durationSeconds, duration)
                $0.language = options.language
            }
            return ProcessingSummary(tracks: summary, totalSeconds: Date().timeIntervalSince(started))
        } catch is CancellationError {
            try? database.updateMeeting(id: meetingId) {
                $0.status = previousStatus == .processing ? .recorded : previousStatus
                $0.lastError = "Procesamiento cancelado por el usuario."
            }
            throw CancellationError()
        } catch {
            try? database.updateMeeting(id: meetingId) {
                $0.status = .failed
                $0.lastError = ProcessingErrorText.describe(error)
            }
            throw error
        }
    }

    private static func order(_ source: AudioSource) -> Int {
        switch source {
        case .remoteSystemAudio: 0
        case .imported: 1
        case .localMicrophone: 2
        }
    }

    // MARK: Stages

    private func run(meetingId: String, tracks: [AudioTrack], options: ProcessingOptions,
                     progress: @escaping @Sendable (PipelineProgress) -> Void) async throws -> [ProcessingSummary.TrackSummary] {
        // 1. Model preparation (download on first run, then load once per process).
        try await stage(.modelPreparation, meetingId: meetingId, track: nil, audioSeconds: nil) {
            progress(.init(meetingId: meetingId, stage: .modelPreparation, source: nil, fraction: nil,
                           message: "Preparando Parakeet Ultra"))
            try await asr.prepare { phase in
                let (fraction, text): (Double?, String) = switch phase {
                case .checking: (nil, "Verificando modelo Parakeet Ultra")
                case .downloading(let f): (f, "Descargando Parakeet Ultra")
                case .compiling(let name): (nil, "Compilando \(name) para el Neural Engine")
                case .loading: (nil, "Cargando Parakeet Ultra")
                case .ready: (1, "Parakeet Ultra listo")
                }
                progress(.init(meetingId: meetingId, stage: .modelPreparation, source: nil, fraction: fraction, message: text))
            }
            if options.diarize {
                progress(.init(meetingId: meetingId, stage: .modelPreparation, source: nil, fraction: nil,
                               message: "Preparando modelos de diarización"))
                try await diarizer.prepare()
            }
            return "ASR: \(asr.descriptor.modelIdentifier)"
        }

        let vocabulary = VocabularyCorrector(terms: (try? database.vocabulary()) ?? [])
        let localUser = try database.localUser()
        var summaries: [ProcessingSummary.TrackSummary] = []
        var remoteWords: [WordTiming] = []

        for track in tracks {
            try Task.checkCancellation()
            let url = paths.resolve(relativePath: track.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AppDatabaseError.notFound("archivo de audio \(track.relativePath)")
            }

            // 2. Transcription (final, Parakeet Ultra).
            var transcription: ASRTranscription?
            try await stage(.transcription, meetingId: meetingId, track: track, audioSeconds: track.durationSeconds) {
                progress(.init(meetingId: meetingId, stage: .transcription, source: track.source, fraction: 0,
                               message: "Transcribiendo \(Self.label(track.source))"))
                do {
                    transcription = try await asr.transcribe(fileURL: url, languageHint: options.language) { f in
                        progress(.init(meetingId: meetingId, stage: .transcription, source: track.source, fraction: f,
                                       message: "Transcribiendo \(Self.label(track.source))"))
                    }
                } catch ASRProviderError.emptyAudio {
                    transcription = ASRTranscription(text: "", words: [], meanConfidence: nil,
                                                     audioDurationSeconds: track.durationSeconds, processingSeconds: 0)
                }
                return "\(transcription?.words.count ?? 0) palabras"
            }
            guard let transcription else { continue }
            let words = transcription.words.map {
                WordTiming(word: $0.word, start: $0.start + track.timelineOffsetSeconds,
                           end: $0.end + track.timelineOffsetSeconds, confidence: $0.confidence)
            }
            if track.source == .remoteSystemAudio { remoteWords = words }

            // 3. Diarization (skipped for empty tracks).
            var diarization: DiarizationOutput?
            let shouldDiarize = options.diarize && !words.isEmpty
                && (track.source != .localMicrophone || options.detectMultipleLocalSpeakers)
            if shouldDiarize {
                try await stage(.diarization, meetingId: meetingId, track: track, audioSeconds: track.durationSeconds) {
                    progress(.init(meetingId: meetingId, stage: .diarization, source: track.source, fraction: 0,
                                   message: "Identificando intervenciones en \(Self.label(track.source))"))
                    diarization = try await diarizer.diarize(fileURL: url) { f in
                        progress(.init(meetingId: meetingId, stage: .diarization, source: track.source, fraction: f,
                                       message: "Identificando intervenciones en \(Self.label(track.source))"))
                    }
                    guard let diarization, diarization.speechDetected else {
                        return "Sin voz suficiente para diarizar; se conserva la transcripción"
                    }
                    return "\(Set(diarization.turns.map(\.clusterKey)).count) hablantes"
                }
            }
            let turns = (diarization?.turns ?? []).map {
                SpeakerTurn(clusterKey: $0.clusterKey, start: $0.start + track.timelineOffsetSeconds,
                            end: $0.end + track.timelineOffsetSeconds, quality: $0.quality)
            }

            // 4. Alignment, echo flagging, persistence.
            progress(.init(meetingId: meetingId, stage: .alignment, source: track.source, fraction: nil,
                           message: "Alineando hablantes y transcripción"))
            // Manual identities of the clusters about to be replaced (re-processing).
            let previousManual = try database.manualIdentities(meetingId: meetingId, source: track.source)
            var built = try buildRecords(meetingId: meetingId, track: track, transcription: transcription,
                                         words: words, turns: turns, diarization: diarization,
                                         remoteWords: track.source == .localMicrophone ? remoteWords : [],
                                         vocabulary: vocabulary, localUser: localUser, options: options)
            Self.reapplyManualIdentities(previousManual, to: &built)
            try database.storeProcessedTrack(transcript: built.transcript, segments: built.segments,
                                             speakers: built.speakers, assignments: built.assignments)

            summaries.append(.init(source: track.source, audioSeconds: track.durationSeconds,
                                   asrSeconds: transcription.processingSeconds,
                                   diarizationSeconds: diarization?.processingSeconds,
                                   words: words.count, segments: built.segments.count,
                                   speakers: built.speakers.count,
                                   echoSegments: built.segments.filter { $0.attribution == .probableEcho }.count))
        }

        // 5. Speaker recognition against consented voice profiles.
        if let recognizer {
            try await stage(.speakerRecognition, meetingId: meetingId, track: nil, audioSeconds: nil) {
                progress(.init(meetingId: meetingId, stage: .speakerRecognition, source: nil, fraction: nil,
                               message: "Reconociendo participantes registrados"))
                let report = try await recognizer.recognize(meetingId: meetingId)
                return report.summary
            }
        }
        return summaries
    }

    struct BuiltTrack {
        var transcript: Transcript
        var segments: [TranscriptSegment]
        var speakers: [MeetingSpeaker]
        var assignments: [SpeakerAssignment]
    }

    func buildRecords(meetingId: String, track: AudioTrack, transcription: ASRTranscription,
                      words: [WordTiming], turns: [SpeakerTurn], diarization: DiarizationOutput?,
                      remoteWords: [WordTiming], vocabulary: VocabularyCorrector,
                      localUser: Participant?, options: ProcessingOptions) throws -> BuiltTrack {
        let transcript = Transcript(
            meetingId: meetingId, trackId: track.id, engine: asr.descriptor.id,
            modelIdentifier: asr.descriptor.modelIdentifier, language: options.language, isFinal: true,
            audioDurationSeconds: transcription.audioDurationSeconds,
            processingSeconds: transcription.processingSeconds, meanConfidence: transcription.meanConfidence)

        let drafts = SegmentBuilder().segments(from: words)
        let aligned: [SpeakerAlignment.AlignedSegment] = turns.isEmpty
            ? drafts.map { .init(words: $0.words, clusterKey: nil, agreement: 0, overlapsOtherSpeaker: false) }
            : SpeakerAlignment().align(drafts, turns: turns)

        // Echo flags first: echo must not count as a separate local speaker.
        let detector = EchoDetector()
        let echoFlags = aligned.map { seg in
            track.source == .localMicrophone && options.flagEcho && !remoteWords.isEmpty
                && detector.isProbableEcho(micText: seg.text, micStart: seg.start, micEnd: seg.end, remoteWords: remoteWords)
        }

        // Clusters ordered by first appearance → "Hablante 1, 2, …".
        var speechByKey: [String: Double] = [:]
        var firstSeen: [String: Double] = [:]
        for (seg, isEcho) in zip(aligned, echoFlags) where !isEcho {
            guard let key = seg.clusterKey else { continue }
            speechByKey[key, default: 0] += seg.end - seg.start
            firstSeen[key] = min(firstSeen[key] ?? .infinity, seg.start)
        }
        let orderedKeys = firstSeen.sorted { $0.value < $1.value }.map(\.key)

        var speakers: [MeetingSpeaker] = []
        var speakerIDByKey: [String: String] = [:]
        var assignments: [SpeakerAssignment] = []
        for (index, key) in orderedKeys.enumerated() {
            let embedding = diarization?.embeddings[key]
            let speaker = MeetingSpeaker(
                meetingId: meetingId, source: track.source, clusterKey: key, ordinal: index + 1,
                totalSpeechSeconds: speechByKey[key] ?? 0,
                embeddingCiphertext: try embedding.flatMap { try recognizer?.seal($0) },
                embeddingModel: embedding == nil ? nil : diarization?.modelIdentifier)
            speakers.append(speaker)
            speakerIDByKey[key] = speaker.id
        }

        // Microphone: attribute to the local user only when exactly one real local speaker exists.
        var micIsSingleLocalSpeaker = false
        var localSpeakerID: String?
        if track.source == .localMicrophone {
            let substantial = speechByKey.filter { $0.value >= options.minimumLocalSpeakerSeconds }
            if turns.isEmpty || substantial.count <= 1 {
                micIsSingleLocalSpeaker = true
                if speakers.isEmpty {
                    let speaker = MeetingSpeaker(meetingId: meetingId, source: .localMicrophone, clusterKey: "local",
                                                 ordinal: 1, totalSpeechSeconds: words.last.map { $0.end - (words.first?.start ?? 0) } ?? 0)
                    speakers.append(speaker)
                }
                let dominant = substantial.max { $0.value < $1.value }?.key ?? orderedKeys.first
                localSpeakerID = dominant.flatMap { speakerIDByKey[$0] } ?? speakers.first?.id
                if let localUser, let localSpeakerID,
                   let i = speakers.firstIndex(where: { $0.id == localSpeakerID }) {
                    speakers[i].participantId = localUser.id
                    assignments.append(SpeakerAssignment(
                        meetingId: meetingId, meetingSpeakerId: localSpeakerID, participantId: localUser.id,
                        method: .localUserTrack, decision: .accepted,
                        note: diarization == nil ? "Pista de micrófono sin diarización (opción del usuario)."
                            : turns.isEmpty ? "La diarización no encontró voz suficiente; se asume el usuario local."
                            : "Un único hablante local detectado en el micrófono."))
                }
            }
        }

        var segments: [TranscriptSegment] = []
        for (index, (seg, isEcho)) in zip(aligned, echoFlags).enumerated() {
            let corrected = vocabulary.apply(to: seg.text)?.text
            var attribution: AttributionStatus
            var speakerID = seg.clusterKey.flatMap { speakerIDByKey[$0] }
            var participantID: String?
            var confidence: Double? = seg.clusterKey == nil ? nil : seg.agreement

            if isEcho {
                attribution = .probableEcho
            } else if track.source == .localMicrophone && micIsSingleLocalSpeaker {
                // Short non-dominant fragments on a single-speaker mic stay with the local speaker.
                speakerID = localSpeakerID
                participantID = localUser?.id
                attribution = .localUserTrack
                confidence = nil
            } else if seg.clusterKey == nil {
                attribution = turns.isEmpty ? .unattributed : .uncertain
            } else if seg.overlapsOtherSpeaker {
                attribution = .uncertain
            } else {
                attribution = .diarized
            }
            if track.source != .localMicrophone, attribution == .diarized || attribution == .uncertain {
                participantID = nil // identities come only from recognition or manual assignment
            }
            segments.append(TranscriptSegment(
                transcriptId: transcript.id, meetingId: meetingId, trackId: track.id, source: track.source,
                orderIndex: index, startTime: seg.start, endTime: seg.end, asrText: seg.text,
                vocabularyText: corrected, asrConfidence: seg.meanConfidence, words: seg.words,
                meetingSpeakerId: speakerID, participantId: participantID, speakerConfidence: confidence,
                attribution: attribution))
        }
        return BuiltTrack(transcript: transcript, segments: segments, speakers: speakers, assignments: assignments)
    }

    /// Re-applies manual identities to new clusters when the temporal evidence is
    /// unambiguous (`ManualIdentityRemapper`); each re-application is audited.
    static func reapplyManualIdentities(_ previous: [ManualIdentityRemapper.PreviousIdentity], to built: inout BuiltTrack) {
        guard !previous.isEmpty else { return }
        let clusters = Dictionary(grouping: built.segments.filter { $0.attribution != .probableEcho && $0.meetingSpeakerId != nil },
                                  by: { $0.meetingSpeakerId! })
            .mapValues { $0.map { ManualIdentityRemapper.Span(start: $0.startTime, end: $0.endTime) } }
        let matches = ManualIdentityRemapper().remap(previous: previous, newClusters: clusters)
        for (speakerId, match) in matches {
            guard let i = built.speakers.firstIndex(where: { $0.id == speakerId }) else { continue }
            // Never override an identity the pipeline already set (e.g. the local user on the mic).
            if built.speakers[i].participantId != nil { continue }
            built.speakers[i].participantId = match.participantId
            built.assignments.removeAll { $0.meetingSpeakerId == speakerId }
            built.assignments.append(SpeakerAssignment(
                meetingId: built.speakers[i].meetingId, meetingSpeakerId: speakerId, participantId: match.participantId,
                method: .manual, decision: .accepted, similarity: nil, margin: nil, threshold: nil,
                note: String(format: "Re-aplicada tras reprocesar (%.0f %% de la voz coincide con la asignación manual previa)",
                             match.share * 100)))
            for j in built.segments.indices where built.segments[j].meetingSpeakerId == speakerId
                && built.segments[j].attribution != .probableEcho {
                built.segments[j].participantId = match.participantId
                built.segments[j].attribution = .manual
                built.segments[j].speakerConfidence = nil
            }
        }
    }

    // MARK: Job bookkeeping

    private func stage(_ stage: ProcessingStage, meetingId: String, track: AudioTrack?, audioSeconds: Double?,
                       _ body: () async throws -> String?) async throws {
        var job = ProcessingJob(meetingId: meetingId, trackId: track?.id, stage: stage, audioSeconds: audioSeconds)
        try database.record(job: job)
        let started = Date()
        do {
            let detail = try await body()
            job.status = .succeeded
            job.detail = detail
        } catch is CancellationError {
            job.status = .cancelled
            job.errorMessage = "Cancelado"
            finish(&job, started: started)
            throw CancellationError()
        } catch {
            job.status = .failed
            job.errorMessage = ProcessingErrorText.describe(error)
            finish(&job, started: started)
            throw error
        }
        finish(&job, started: started)
    }

    private func finish(_ job: inout ProcessingJob, started: Date) {
        job.finishedAt = Date()
        job.wallSeconds = job.finishedAt!.timeIntervalSince(started)
        job.peakMemoryBytes = ProcessMemory.peakResidentBytes()
        _ = try? database.record(job: job)
        let stageName = job.stage.rawValue, status = job.status.rawValue, wall = job.wallSeconds ?? 0
        logger.info("Stage \(stageName, privacy: .public) \(status, privacy: .public) in \(wall, format: .fixed(precision: 2)) s")
    }

    static func label(_ source: AudioSource) -> String {
        switch source {
        case .localMicrophone: "micrófono local"
        case .remoteSystemAudio: "audio remoto"
        case .imported: "audio importado"
        }
    }
}

enum ProcessMemory {
    /// Peak resident set size of this process so far (bytes).
    static func peakResidentBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int64(usage.ru_maxrss) // bytes on macOS
    }
}
