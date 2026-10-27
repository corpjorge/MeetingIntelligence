import AVFoundation
import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingSpeech

/// End-to-end tests with the real Parakeet Ultra and diarization models on
/// SYNTHETIC fixtures (see Fixtures/synthetic/README.md).
///
/// They run only when the models are already cached (they never download in
/// CI) and the fixtures exist: `scripts/generate-fixtures.sh` + one app/CLI run.
enum IntegrationEnvironment {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/synthetic")

    static var available: Bool {
        FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("es_two_speakers.wav").path)
            && AsrCacheProbe.ultraCached && AsrCacheProbe.diarizerCached
    }
}

enum AsrCacheProbe {
    static var ultraCached: Bool {
        let dir = ParakeetUltraProvider().cacheDirectory
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".mlmodelc") }
    }
    static var diarizerCached: Bool {
        let dir = DiarizationService().cacheDirectory
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".mlmodelc") }
    }
}

@Suite("Integración: Ultra + diarización", .enabled(if: IntegrationEnvironment.available), .serialized)
struct PipelineIntegrationTests {
    @Test func importTranscribeDiarizeAndPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let db = try AppDatabase.open(paths: paths)
        try db.save(term: VocabularyTerm(canonical: "QA", variants: ["Cuba"]))

        let meeting = try await MeetingImportService(database: db, paths: paths)
            .importAudio(at: IntegrationEnvironment.fixtures.appendingPathComponent("es_two_speakers.wav"),
                         title: "FIXTURE")
        let diarizer = DiarizationService()
        let processor = MeetingProcessor(
            database: db, paths: paths, asr: ParakeetUltraProvider(), diarizer: diarizer,
            recognizer: SpeakerRecognitionService(database: db, vault: BiometricVault(keyProvider: EphemeralBiometricKeyProvider()),
                                                  diarizer: diarizer))
        let summary = try await processor.process(meetingId: meeting.id) { _ in }
        let detail = try #require(try db.meetingDetail(id: meeting.id))

        #expect(detail.meeting.status == .ready)
        #expect(summary.tracks.first?.speakers == 2)
        #expect(detail.speakers.count == 2)
        // Speakers alternate A B A B in the fixture.
        let labels = detail.segments.map { detail.speakerName(for: $0) }
        #expect(labels.count >= 4)
        #expect(Set(labels).count == 2)
        // No identity was invented.
        #expect(detail.segments.allSatisfy { $0.participantId == nil })
        // Timestamps are monotonic and inside the audio.
        #expect(zip(detail.segments, detail.segments.dropFirst()).allSatisfy { $0.startTime <= $1.startTime })
        #expect((detail.segments.last?.endTime ?? 0) <= detail.tracks[0].durationSeconds + 0.5)
        // Every stage was recorded with timings.
        #expect(detail.jobs.contains { $0.stage == .transcription && $0.status == .succeeded && ($0.wallSeconds ?? 0) > 0 })

        // WER against the reference (synthetic speech → optimistic bound).
        let reference = try String(contentsOf: IntegrationEnvironment.fixtures.appendingPathComponent("es_two_speakers.txt"), encoding: .utf8)
        let hypothesis = detail.segments.map(\.displayText).joined(separator: " ")
        let wer = Metrics.wordErrorRate(reference: reference, hypothesis: hypothesis)
        #expect(wer.wer < 0.15, "WER \(wer.wer)")
        // Custom vocabulary applied without losing the raw ASR text.
        if let fixed = detail.segments.first(where: { $0.asrText.contains("Cuba") }) {
            #expect(fixed.vocabularyText?.contains("QA") == true)
        }
    }

    @Test func silenceProducesNoText() async throws {
        let asr = ParakeetUltraProvider()
        let result = try await asr.transcribe(
            fileURL: IntegrationEnvironment.fixtures.appendingPathComponent("silence.wav"), languageHint: "es-CO") { _ in }
        #expect(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.words.isEmpty)
    }

    /// Regression (real Teams call): a microphone track with a 1–2 s reply has words
    /// but nothing the diarizer can embed (`noSpeechDetected`). That must not fail
    /// the meeting: the reply stays with the local user, the remote track is diarized.
    @Test func shortMicrophoneReplyDoesNotFailTheMeeting() async throws {
        let shortReply = IntegrationEnvironment.fixtures.appendingPathComponent("es_short_reply.wav")
        try #require(FileManager.default.fileExists(atPath: shortReply.path), "scripts/generate-fixtures.sh")
        let diarizer = DiarizationService()
        let direct = try await diarizer.diarize(fileURL: shortReply) { _ in }
        #expect(!direct.speechDetected)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let db = try AppDatabase.open(paths: paths)
        let me = try db.setLocalUserName("FIXTURE Yo")
        let meeting = Meeting(title: "FIXTURE · llamada", startedAt: Date(), origin: .recording,
                              captureScope: .applicationProcesses, status: .recorded)
        let dir = try paths.prepareMeetingDirectory(meeting.id)
        var tracks: [AudioTrack] = []
        for (source, fixture) in [(AudioSource.remoteSystemAudio, "es_single_speaker.wav"),
                                  (.localMicrophone, "es_short_reply.wav")] {
            let dest = dir.appendingPathComponent("\(source.rawValue).wav")
            try FileManager.default.copyItem(at: IntegrationEnvironment.fixtures.appendingPathComponent(fixture), to: dest)
            let file = try AVAudioFile(forReading: dest)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            tracks.append(AudioTrack(meetingId: meeting.id, source: source,
                                     relativePath: try #require(paths.relativePath(for: dest)),
                                     sampleRate: 16_000, channelCount: 1, durationSeconds: seconds))
        }
        try db.insert(meeting: meeting, tracks: tracks)

        let processor = MeetingProcessor(database: db, paths: paths, asr: ParakeetUltraProvider(), diarizer: diarizer,
                                         recognizer: nil)
        try await processor.process(meetingId: meeting.id) { _ in }

        let detail = try #require(try db.meetingDetail(id: meeting.id))
        #expect(detail.meeting.status == .ready)
        #expect(detail.meeting.lastError == nil)
        let micTrack = try #require(tracks.first { $0.source == .localMicrophone })
        let micDiarization = try #require(detail.jobs.last { $0.stage == .diarization && $0.trackId == micTrack.id })
        #expect(micDiarization.status == .succeeded)
        #expect(micDiarization.detail?.contains("Sin voz suficiente") == true)
        let micSegments = detail.segments.filter { $0.source == .localMicrophone }
        #expect(!micSegments.isEmpty)
        let reference = try String(contentsOf: shortReply.deletingPathExtension().appendingPathExtension("txt"),
                                   encoding: .utf8)
        #expect(Metrics.wordErrorRate(reference: reference, hypothesis: micSegments.map(\.asrText).joined(separator: " ")).wer == 0)
        #expect(micSegments.allSatisfy { $0.startTime >= 7.5 && $0.endTime <= 10 })
        #expect(micSegments.allSatisfy { $0.attribution == .localUserTrack && $0.participantId == me.id })
        #expect(detail.segments.contains { $0.source == .remoteSystemAudio && $0.attribution == .diarized })
        let audit = try db.assignments(meetingId: meeting.id)
        #expect(audit.contains { $0.method == .localUserTrack && ($0.note ?? "").contains("no encontró voz suficiente") })
    }

    /// Regression (seen in a real Teams call): a short utterance isolated in
    /// digital silence drifted to another language when decoded as is ("Hello, como
    /// está?", "Valeu, né?"). Dead silence is collapsed before ASR (TD-22) and the
    /// timings must still land on the file's own timeline.
    @Test(arguments: ["es_isolated_greeting", "es_isolated_word"])
    func isolatedShortUtteranceStaysInSpanish(fixture: String) async throws {
        let url = IntegrationEnvironment.fixtures.appendingPathComponent("\(fixture).wav")
        try #require(FileManager.default.fileExists(atPath: url.path), "scripts/generate-fixtures.sh")
        let result = try await ParakeetUltraProvider().transcribe(fileURL: url, languageHint: "es-CO") { _ in }
        let reference = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        #expect(Metrics.wordErrorRate(reference: reference, hypothesis: result.text).wer == 0, "\(result.text)")

        // The utterance starts after 3.5 s of silence in the original file.
        let file = try AVAudioFile(forReading: url)
        #expect(abs(result.audioDurationSeconds - Double(file.length) / 16_000) < 0.01)
        let first = try #require(result.words.first)
        #expect(first.start > 3.0 && first.start < 4.1, "start \(first.start)")
        #expect(result.words.allSatisfy { $0.end >= $0.start && $0.end - $0.start < 1.5 && $0.end < 6 })
    }

    @Test func spanishWithEnglishTermsIsAccurate() async throws {
        let asr = ParakeetUltraProvider()
        let url = IntegrationEnvironment.fixtures.appendingPathComponent("es_single_speaker.wav")
        let result = try await asr.transcribe(fileURL: url, languageHint: "es-CO") { _ in }
        let reference = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        let wer = Metrics.wordErrorRate(reference: reference, hypothesis: result.text)
        #expect(wer.wer < 0.08, "WER \(wer.wer): \(result.text)")
        for term in ["endpoint", "pull", "request", "kubernetes", "backend", "api"] {
            #expect(TextNormalization.tokens(result.text).contains(term), "falta \(term)")
        }
        // Word timings are monotonic and within the file.
        #expect(zip(result.words, result.words.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect((result.words.last?.end ?? 0) <= result.audioDurationSeconds + 0.1)
    }

    @Test func isolatedMicrophoneReplyUsesRemoteContextWithoutCopyingItsWords() async throws {
        let provider = ParakeetUltraProvider()
        let remoteURL = IntegrationEnvironment.fixtures.appendingPathComponent("es_single_speaker.wav")
        let replyURL = IntegrationEnvironment.fixtures.appendingPathComponent("es_context_reply.wav")
        try #require(FileManager.default.fileExists(atPath: replyURL.path), "scripts/generate-fixtures.sh")
        let remote = try await provider.transcribe(fileURL: remoteURL, languageHint: "es-CO") { _ in }
        let reference = try String(contentsOf: replyURL.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        let result = try await provider.transcribe(
            fileURL: replyURL, languageHint: "es-CO", timelineOffsetSeconds: remote.audioDurationSeconds + 1,
            contextTracks: [ASRContextTrack(fileURL: remoteURL, tokens: remote.tokens, timelineOffsetSeconds: 0)]) { _ in }
        #expect(Metrics.wordErrorRate(reference: reference, hypothesis: result.text).wer == 0, "\(result.text)")
        #expect(!result.words.isEmpty)
        #expect(result.words.allSatisfy { $0.start >= 0 && $0.end <= result.audioDurationSeconds + 0.3 })
    }
}

@Suite("Integración: transcripción provisional en vivo", .enabled(if: IntegrationEnvironment.available))
struct LiveTranscriptionTests {
    @Test func slidingWindowUltraProducesProvisionalText() async throws {
        let url = IntegrationEnvironment.fixtures.appendingPathComponent("es_single_speaker.wav")
        let file = try AVAudioFile(forReading: url)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))

        let live = try await ParakeetUltraProvider().makeLiveTranscriber(sources: [.remoteSystemAudio], languageHint: "es-CO")
        let updates = live.updates
        let collector = Task { () -> Int in
            var count = 0
            for await _ in updates { count += 1 }
            return count
        }
        // 100 ms blocks, as delivered by the recorder.
        for start in stride(from: 0, to: samples.count, by: 1600) {
            live.feed(Array(samples[start..<min(start + 1600, samples.count)]), source: .remoteSystemAudio)
        }
        let final = await live.finish()[.remoteSystemAudio] ?? ""
        await live.stop() // finishes the update stream
        let received = await collector.value

        let reference = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        let wer = Metrics.wordErrorRate(reference: reference, hypothesis: final)
        #expect(!final.isEmpty)
        #expect(wer.wer < 0.35, "WER provisional \(wer.wer): \(final)")
        #expect(received > 0)
    }
}

@Suite("Integración: reprocesar conserva identidades manuales", .enabled(if: IntegrationEnvironment.available))
struct ReprocessIdentityTests {
    @Test func manualIdentitySurvivesReprocessing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let db = try AppDatabase.open(paths: paths)
        let meeting = try await MeetingImportService(database: db, paths: paths)
            .importAudio(at: IntegrationEnvironment.fixtures.appendingPathComponent("es_two_speakers.wav"), title: "FIXTURE")
        let diarizer = DiarizationService()
        let processor = MeetingProcessor(database: db, paths: paths, asr: ParakeetUltraProvider(), diarizer: diarizer,
                                         recognizer: nil)
        try await processor.process(meetingId: meeting.id) { _ in }

        // Name the speaker of the first turn manually.
        let before = try #require(try db.meetingDetail(id: meeting.id))
        let firstSpeaker = try #require(before.segments.first?.meetingSpeakerId)
        let katty = Participant(displayName: "FIXTURE Katty")
        try db.save(participant: katty)
        try db.assignSpeaker(meetingSpeakerId: firstSpeaker, participantId: katty.id)
        let kattyTexts = Set(try #require(try db.meetingDetail(id: meeting.id)).segments
            .filter { $0.participantId == katty.id }.map(\.startTime))
        #expect(kattyTexts.count == 2) // turns 1 and 3 in the fixture

        // Re-process: clusters are replaced, the manual identity must be re-applied.
        try await processor.process(meetingId: meeting.id) { _ in }
        let after = try #require(try db.meetingDetail(id: meeting.id))
        let kattyAfter = after.segments.filter { $0.participantId == katty.id }
        #expect(Set(kattyAfter.map(\.startTime)) == kattyTexts)
        #expect(kattyAfter.allSatisfy { $0.attribution == .manual })
        // The other speaker stays unknown — nothing invented.
        #expect(after.segments.filter { $0.participantId == nil }.count == 2)
        let audit = try db.assignments(meetingId: meeting.id)
        #expect(audit.contains { $0.method == .manual && ($0.note ?? "").contains("Re-aplicada tras reprocesar") })
    }
}
