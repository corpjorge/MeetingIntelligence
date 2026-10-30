import CryptoKit
import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingSpeech

actor ScriptedASR: ASRProvider {
    nonisolated let descriptor = ASREngineDescriptor(id: "scripted-asr", displayName: "ASR de prueba",
                                                     modelIdentifier: "scripted", approximateDownloadBytes: 0)
    nonisolated let started: AsyncStream<String>
    private let startedContinuation: AsyncStream<String>.Continuation
    private let script: [String: [WordTiming]]
    private let blocking: Set<String>
    private(set) var preparations = 0

    init(script: [String: [WordTiming]], blocking: Set<String> = []) {
        self.script = script
        self.blocking = blocking
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    nonisolated func waitForStart(of name: String, timeout: Duration = .seconds(10)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await started in self.started where started == name { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    func isModelCached() async -> Bool { true }

    func prepare(progress: @escaping @Sendable (ModelPreparationPhase) -> Void) async throws {
        preparations += 1
    }

    func unload() async {}

    func transcribe(fileURL: URL, languageHint: String,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> ASRTranscription {
        let name = fileURL.lastPathComponent
        startedContinuation.yield(name)
        if blocking.contains(name) { try await Task.sleep(for: .seconds(60)) }
        let words = script[name] ?? []
        return ASRTranscription(text: words.map(\.word).joined(separator: " "), words: words, meanConfidence: 0.9,
                                audioDurationSeconds: words.last?.end ?? 0, processingSeconds: 0.01)
    }
}

struct FailingKeyProvider: BiometricKeyProvider {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Llavero no disponible" }
    }

    func key() throws -> SymmetricKey { throw Unavailable() }
    func destroyKey() throws {}
}

struct ProcessorFixture {
    struct MissingPath: Error {}

    let root: URL
    let paths: AppPaths
    let db: AppDatabase
    let meeting: Meeting
    let tracks: [AudioTrack]

    init(sources: [AudioSource] = [.remoteSystemAudio, .localMicrophone], createFiles: Bool = true,
         status: MeetingStatus = .recorded) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-proc-\(UUID().uuidString)")
        paths = AppPaths(root: root)
        db = try AppDatabase.inMemory()
        meeting = Meeting(title: "FIXTURE", startedAt: Date(), origin: .recording,
                          captureScope: .applicationProcesses, status: status)
        let dir = try paths.prepareMeetingDirectory(meeting.id)
        var tracks: [AudioTrack] = []
        for source in sources {
            let url = dir.appendingPathComponent("\(source.rawValue).wav")
            if createFiles { try Data("RIFF".utf8).write(to: url) }
            guard let relative = paths.relativePath(for: url) else { throw MissingPath() }
            tracks.append(AudioTrack(meetingId: meeting.id, source: source, relativePath: relative,
                                     sampleRate: 16_000, channelCount: 1, durationSeconds: 20))
        }
        self.tracks = tracks
        try db.insert(meeting: meeting, tracks: tracks)
    }

    func processor(_ asr: ScriptedASR, recognizer: SpeakerRecognitionService? = nil) -> MeetingProcessor {
        MeetingProcessor(database: db, paths: paths, asr: asr, diarizer: DiarizationService(), recognizer: recognizer)
    }

    static var options: ProcessingOptions {
        var options = ProcessingOptions()
        options.diarize = false
        return options
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func w(_ word: String, _ start: Double, _ end: Double) -> WordTiming {
    WordTiming(word: word, start: start, end: end, confidence: 0.9)
}

private let remoteFile = "\(AudioSource.remoteSystemAudio.rawValue).wav"
private let micFile = "\(AudioSource.localMicrophone.rawValue).wav"
private let remoteScript = [w("Hola", 0, 0.4), w("equipo.", 0.5, 1.0),
                            w("Revisemos", 3.0, 3.5), w("el", 3.6, 3.7), w("presupuesto.", 3.8, 4.4)]
private let micScript = [w("Listo,", 6.0, 6.4), w("empecemos.", 6.5, 7.1)]
private let script = [remoteFile: remoteScript, micFile: micScript]

@Suite("Procesamiento sin modelos: reprocesar con seguridad", .timeLimit(.minutes(1)))
struct MeetingProcessorTests {
    @Test func missingAudioFailsBeforeTouchingTheMeeting() async throws {
        let fixture = try ProcessorFixture(createFiles: false, status: .ready)
        defer { fixture.cleanUp() }
        let asr = ScriptedASR(script: script)
        await #expect(throws: MeetingProcessingError.self) {
            try await fixture.processor(asr).process(meetingId: fixture.meeting.id, options: ProcessorFixture.options) { _ in }
        }
        let detail = try #require(try fixture.db.meetingDetail(id: fixture.meeting.id))
        #expect(detail.meeting.status == .ready)
        #expect(detail.meeting.lastError == nil)
        #expect(detail.jobs.isEmpty)
        #expect(await asr.preparations == 0)
        let message = MeetingProcessingError.audioUnavailable([micFile]).localizedDescription
        #expect(message.contains(micFile) && message.contains("no se modificó"))
    }

    @Test func cancellingAReprocessKeepsThePreviousTranscript() async throws {
        let fixture = try ProcessorFixture()
        defer { fixture.cleanUp() }
        try await fixture.processor(ScriptedASR(script: script))
            .process(meetingId: fixture.meeting.id, options: ProcessorFixture.options) { _ in }
        let before = try #require(try fixture.db.meetingDetail(id: fixture.meeting.id))
        #expect(before.meeting.status == .ready)
        #expect(Set(before.segments.map(\.source)) == [.remoteSystemAudio, .localMicrophone])

        let changed = [remoteFile: [w("Otro", 0, 0.4), w("texto.", 0.5, 1.0)],
                       micFile: micScript]
        let asr = ScriptedASR(script: changed, blocking: [micFile])
        let processor = fixture.processor(asr)
        let meetingId = fixture.meeting.id
        let task = Task { try await processor.process(meetingId: meetingId, options: ProcessorFixture.options) { _ in } }
        #expect(await asr.waitForStart(of: micFile))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        let after = try #require(try fixture.db.meetingDetail(id: fixture.meeting.id))
        #expect(after.segments.map(\.id) == before.segments.map(\.id))
        #expect(after.segments.map(\.displayText) == before.segments.map(\.displayText))
        #expect(after.transcripts.filter { $0.supersededAt == nil }.map(\.id).sorted()
                == before.transcripts.filter { $0.supersededAt == nil }.map(\.id).sorted())
        #expect(after.meeting.status == .ready)
        #expect(after.meeting.lastError == "Procesamiento cancelado por el usuario.")
    }

    @Test func manualTextEditsAreCarriedOverWhenUnambiguous() async throws {
        let fixture = try ProcessorFixture()
        defer { fixture.cleanUp() }
        try await fixture.processor(ScriptedASR(script: script))
            .process(meetingId: fixture.meeting.id, options: ProcessorFixture.options) { _ in }
        let first = try #require(try fixture.db.meetingDetail(id: fixture.meeting.id))
        let edited = try #require(first.segments.first { $0.asrText == "Revisemos el presupuesto." })
        try fixture.db.editSegmentText(segmentId: edited.id, newText: "Revisemos el presupuesto de 2027.")

        let summary = try await fixture.processor(ScriptedASR(script: script))
            .process(meetingId: fixture.meeting.id, options: ProcessorFixture.options) { _ in }
        #expect(summary.carriedEdits == 1)
        #expect(summary.droppedEdits == 0)
        let second = try #require(try fixture.db.meetingDetail(id: fixture.meeting.id))
        let carried = try #require(second.segments.first { $0.asrText == "Revisemos el presupuesto." })
        #expect(carried.id != edited.id)
        #expect(carried.editedText == "Revisemos el presupuesto de 2027.")
        #expect(carried.asrText == "Revisemos el presupuesto.")
        #expect(second.segments.filter { $0.editedText != nil }.count == 1)
        let event = try #require(try fixture.db.corrections(meetingId: fixture.meeting.id)
            .first { $0.entityId == carried.id })
        #expect(event.entityType == "transcriptSegment" && event.field == "editedText")
        #expect(event.previousValue == nil && event.newValue == "Revisemos el presupuesto de 2027.")

        let moved = [remoteFile: [w("Hola", 0, 0.4), w("equipo.", 0.5, 1.0),
                                               w("Revisemos", 3.7, 4.1), w("el", 4.2, 4.3), w("presupuesto.", 4.4, 5.0)],
                     micFile: micScript]
        let third = try await fixture.processor(ScriptedASR(script: moved))
            .process(meetingId: fixture.meeting.id, options: ProcessorFixture.options) { _ in }
        #expect(third.carriedEdits == 0)
        #expect(third.droppedEdits == 1)
        let last = try #require(try fixture.db.meetingDetail(id: fixture.meeting.id))
        #expect(last.segments.allSatisfy { $0.editedText == nil })
    }

    @Test func unavailableKeychainKeepsSpeakersWithoutFingerprint() async throws {
        let fixture = try ProcessorFixture(sources: [.remoteSystemAudio])
        defer { fixture.cleanUp() }
        let words = [w("hola", 0, 0.5), w("qué", 0.6, 1.0), w("tal", 5, 5.5), w("bien", 5.6, 6)]
        let turns = [SpeakerTurn(clusterKey: "S1", start: 0, end: 1.2, quality: 1),
                     SpeakerTurn(clusterKey: "S2", start: 4.8, end: 6.2, quality: 1)]
        let diarization = DiarizationOutput(turns: turns, embeddings: ["S1": [0.6, 0.8], "S2": [0.8, 0.6]],
                                            processingSeconds: 0.1, modelIdentifier: "test-model")
        let transcription = ASRTranscription(text: "hola qué tal bien", words: words, meanConfidence: 0.9,
                                             audioDurationSeconds: 6, processingSeconds: 0.1)

        func build(_ keys: any BiometricKeyProvider) async throws -> MeetingProcessor.BuiltTrack {
            let recognizer = SpeakerRecognitionService(database: fixture.db, vault: BiometricVault(keyProvider: keys),
                                                       diarizer: DiarizationService())
            return try await fixture.processor(ScriptedASR(script: [:]), recognizer: recognizer).buildRecords(
                meetingId: fixture.meeting.id, track: fixture.tracks[0], transcription: transcription, words: words,
                turns: turns, diarization: diarization, remoteWords: [], vocabulary: VocabularyCorrector(terms: []),
                localUser: nil, options: ProcessingOptions())
        }

        let failed = try await build(FailingKeyProvider())
        #expect(failed.speakers.count == 2)
        #expect(failed.speakers.allSatisfy { $0.embeddingCiphertext == nil && $0.embeddingModel == nil })
        #expect(failed.unsealedEmbeddings == 2)
        #expect(failed.segments.count == 2 && failed.segments.allSatisfy { $0.attribution == .diarized })

        let keys = EphemeralBiometricKeyProvider()
        let sealed = try await build(keys)
        #expect(sealed.unsealedEmbeddings == 0)
        let cipher = try #require(sealed.speakers.first?.embeddingCiphertext)
        #expect(sealed.speakers.first?.embeddingModel == "test-model")
        #expect(try BiometricVault(keyProvider: keys).open(cipher) == [0.6, 0.8])
    }
}

@Suite("Traslado de correcciones al reprocesar")
struct EditCarryMatchTests {
    private func segment(_ text: String, _ start: Double, _ end: Double, edited: String? = nil) -> TranscriptSegment {
        TranscriptSegment(transcriptId: "t", meetingId: "m", trackId: "k", source: .remoteSystemAudio, orderIndex: 0,
                          startTime: start, endTime: end, asrText: text, editedText: edited)
    }

    private func pairs(_ previous: [TranscriptSegment], _ new: [TranscriptSegment]) -> [[Int]] {
        MeetingProcessor.matchEdits(previous: previous, new: new).map { [$0.previous, $0.new] }
    }

    @Test func sameNormalizedTextNearbyAndOverlappingMatches() {
        let previous = [segment("Hola, ¿qué tal?", 10.0, 11.0, edited: "Hola, ¿qué tal, Ana?")]
        #expect(pairs(previous, [segment("Otra cosa", 2, 3), segment("hola que tal", 10.3, 11.2)]) == [[0, 1]])
        #expect(pairs(previous, [segment("Hola, ¿qué tal?", 10.5, 11.0)]) == [[0, 0]])
    }

    @Test func differentTextIsNotMatched() {
        let previous = [segment("Hola, ¿qué tal?", 10.0, 11.0, edited: "x")]
        #expect(pairs(previous, [segment("Hola, ¿qué más?", 10.0, 11.0)]).isEmpty)
    }

    @Test func startShiftAboveHalfSecondOrNoOverlapIsNotMatched() {
        let previous = [segment("Sí.", 10.0, 10.8, edited: "Sí, claro.")]
        #expect(pairs(previous, [segment("Sí.", 10.6, 11.2)]).isEmpty)
        #expect(pairs([segment("Sí.", 10.0, 10.2, edited: "x")], [segment("Sí.", 10.3, 10.5)]).isEmpty)
    }

    @Test func ambiguousCandidatesAreNotMatched() {
        let previous = [segment("Sí.", 10.0, 10.6, edited: "Sí, claro.")]
        #expect(pairs(previous, [segment("Sí.", 9.8, 10.2), segment("Sí.", 10.2, 10.7)]).isEmpty)
    }

    @Test func matchesMustBeMutuallyOneToOne() {
        let previous = [segment("Sí.", 10.0, 10.6, edited: "a"), segment("Sí.", 10.4, 10.9, edited: "b")]
        #expect(pairs(previous, [segment("Sí.", 10.2, 10.7)]).isEmpty)
        let separate = [segment("Sí.", 10.0, 10.6, edited: "a"), segment("Sí.", 20.0, 20.6, edited: "b")]
        #expect(pairs(separate, [segment("Sí.", 20.1, 20.5), segment("Sí.", 10.1, 10.5)]) == [[0, 1], [1, 0]])
    }

    @Test func carriedEditsProduceAuditedCorrections() {
        let previous = [segment("Hola.", 1.0, 1.5, edited: "Hola, Ana."), segment("Chao.", 50, 51, edited: "Chao, Ana.")]
        var new = [segment("Hola.", 1.1, 1.6), segment("Adiós.", 50, 51)]
        let carried = MeetingProcessor.carryEdits(previous, into: &new, meetingId: "m")
        #expect(carried.dropped == 1)
        #expect(new[0].editedText == "Hola, Ana." && new[1].editedText == nil)
        #expect(new[0].asrText == "Hola.")
        let event = carried.corrections.first
        #expect(carried.corrections.count == 1)
        #expect(event?.entityType == "transcriptSegment" && event?.entityId == new[0].id)
        #expect(event?.field == "editedText" && event?.previousValue == nil && event?.newValue == "Hola, Ana.")
        #expect(event?.meetingId == "m")
    }
}
