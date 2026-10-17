import AVFoundation
import Foundation
import Testing
@testable import MeetingAudio
@testable import MeetingCore

private func tempURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mi-audio-\(UUID().uuidString)-\(name)")
}

private func sine(frequency: Double, sampleRate: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
    (0..<Int(sampleRate * seconds)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

@Suite("Escritura WAV")
struct WAVWriterTests {
    @Test func writesReadableWAVWithSilencePadding() throws {
        let url = tempURL("a.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try CrashSafeWAVWriter(url: url, sampleRate: 16_000)
        try writer.append(sine(frequency: 440, sampleRate: 16_000, seconds: 1))
        try writer.appendSilence(frames: 8_000)
        try writer.close()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == 24_000)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func crashLeavesRecoverableFile() throws {
        let url = tempURL("crash.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let writer = try CrashSafeWAVWriter(url: url, sampleRate: 16_000, flushIntervalSeconds: 0.5)
            try writer.append(sine(frequency: 300, sampleRate: 16_000, seconds: 1.75))
        }
        // A crash between periodic flushes leaves stale RIFF/data sizes behind.
        // Emulate the worst case (sizes never written) after the writer is gone.
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Data([36, 0, 0, 0]))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Data([0, 0, 0, 0]))
        try handle.close()
        #expect((try? AVAudioFile(forReading: url))?.length ?? 0 == 0)

        let recovered = try WAVRepair.repairHeader(at: url)
        #expect(abs(recovered - 1.75) < 0.001)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 28_000)
    }
}

@Suite("Alineación temporal")
struct TimelineAlignerTests {
    @Test func padsLateStartAndGaps() {
        var aligner = TimelineAligner(sampleRate: 16_000)
        // Source starts 0.5 s after the timeline origin → pad 8000 frames.
        #expect(aligner.plan(startSeconds: 0.5, frameCount: 1600) == .init(padFrames: 8000, dropFrames: 0))
        // Contiguous buffer within jitter tolerance → no correction.
        #expect(aligner.plan(startSeconds: 0.6 + 0.01, frameCount: 1600) == .init(padFrames: 0, dropFrames: 0))
        // Device switch: next buffer arrives 1 s later than expected → pad the gap.
        let expected = Double(aligner.framesWritten) / 16_000
        let plan = aligner.plan(startSeconds: expected + 1.0, frameCount: 1600)
        #expect(plan.padFrames == 16_000)
        #expect(aligner.totalPaddedFrames == 24_000)
    }

    @Test func dropsFramesWhenClockRunsAhead() {
        var aligner = TimelineAligner(sampleRate: 16_000)
        _ = aligner.plan(startSeconds: 0, frameCount: 16_000)
        // Buffer claims to start 0.1 s earlier than what we already wrote (drift).
        let plan = aligner.plan(startSeconds: 0.9, frameCount: 3200)
        #expect(plan.dropFrames == 1600)
        #expect(aligner.framesWritten == 16_000 + 1600)
    }

    @Test func unknownTimestampsAppendContiguously() {
        var aligner = TimelineAligner(sampleRate: 16_000)
        #expect(aligner.plan(startSeconds: nil, frameCount: 100) == .init(padFrames: 0, dropFrames: 0))
        #expect(aligner.framesWritten == 100)
    }

    @Test func clockExcludesPausedTime() throws {
        let clock = CaptureClock(originHostSeconds: HostClock.nowSeconds() - 10)
        let before = try #require(clock.timelineSeconds(forHostSeconds: HostClock.nowSeconds()))
        #expect(abs(before - 10) < 0.1)
        clock.pause()
        #expect(clock.timelineSeconds(forHostSeconds: HostClock.nowSeconds()) == nil)
        Thread.sleep(forTimeInterval: 0.2)
        clock.resume()
        let after = try #require(clock.timelineSeconds(forHostSeconds: HostClock.nowSeconds()))
        #expect(after < before + 0.15) // the 0.2 s pause is not on the timeline
    }
}

@Suite("Conversión de formato")
struct ConversionTests {
    @Test func resamples48kTo16kPreservingDurationAndPitch() throws {
        let resampler = try MonoResampler(inputRate: 48_000, outputRate: 16_000)
        let input = sine(frequency: 1000, sampleRate: 48_000, seconds: 2)
        var output: [Float] = []
        // Feed in realistic 10 ms device buffers to exercise streaming state.
        for start in stride(from: 0, to: input.count, by: 480) {
            output += try resampler.process(Array(input[start..<min(start + 480, input.count)]))
        }
        #expect(abs(output.count - 32_000) < 200)
        // Zero crossings ≈ 2 per cycle → 1 kHz over the steady-state middle second.
        let middle = Array(output[8_000..<24_000])
        let crossings = zip(middle, middle.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        #expect(abs(crossings - 2_000) < 20)
        let level = LevelMeter.measure(middle)
        #expect(abs(level.rmsDB - (-9.03)) < 0.5) // 0.5 amplitude sine → −9.03 dBFS RMS
    }

    @Test func downmixAveragesChannels() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        for i in 0..<4 {
            buffer.floatChannelData![0][i] = 1
            buffer.floatChannelData![1][i] = 0
        }
        #expect(Downmix.mono(buffer) == [0.5, 0.5, 0.5, 0.5])
    }

    @Test func silenceMeasuresAsFloor() {
        #expect(LevelMeter.measure([Float](repeating: 0, count: 100)) == .silence)
    }
}

@Suite("Detección de Teams")
struct TeamsProcessTests {
    private func process(_ bundle: String?, _ path: String?) -> AudioProcessInfo {
        AudioProcessInfo(objectID: 1, pid: 1, bundleID: bundle, executablePath: path, isRunningOutput: true)
    }

    @Test func matchesTeamsBundlesAndEmbeddedWebViewHelpers() {
        #expect(AudioProcessCatalog.isTeams(process("com.microsoft.teams2", nil)))
        #expect(AudioProcessCatalog.isTeams(process("com.microsoft.teams2.modulehost", nil)))
        // WebView2 helper inside the Teams bundle (real layout observed on macOS 27).
        #expect(AudioProcessCatalog.isTeams(process(
            "com.microsoft.edgewebview2.helper.renderer",
            "/Applications/Microsoft Teams.app/Contents/Helpers/Microsoft Teams WebView.app/Contents/Frameworks/Microsoft Edge Framework.framework/Versions/154/Helpers/Microsoft Teams WebView Helper (Renderer).app/Contents/MacOS/x")))
    }

    @Test func rejectsOtherMicrosoftApps() {
        // Outlook also embeds WebView2: same bundle ID, different host app.
        #expect(!AudioProcessCatalog.isTeams(process(
            "com.microsoft.edgewebview2.helper",
            "/Applications/Microsoft Outlook.app/Contents/Frameworks/x/Helper.app/Contents/MacOS/x")))
        #expect(!AudioProcessCatalog.isTeams(process("com.spotify.client", "/Applications/Spotify.app/Contents/MacOS/Spotify")))
    }

    @Test func liveCatalogIsQueryable() {
        // Smoke test against the real HAL: must not crash; content depends on the machine.
        let all = AudioProcessCatalog.allProcesses()
        let teams = AudioProcessCatalog.teamsProcesses(in: all)
        #expect(teams.count <= all.count)
    }
}

@Suite("Compactación de silencio antes del ASR")
struct SilenceCompactorTests {
    private let dead: Float = 0
    private let sound: Float = 0.1

    /// RMS per 80 ms frame from (value, frames) runs.
    private func frames(_ runs: [(Float, Int)]) -> [Float] { runs.flatMap { Array(repeating: $0.0, count: $0.1) } }

    @Test func collapsesLeadingInteriorAndTrailingDeadRuns() throws {
        let f = SilenceCompactor.frameSamples
        // 40 dead | 10 sound | 20 dead | 10 sound | 30 dead
        let rms = frames([(dead, 40), (sound, 10), (dead, 20), (sound, 10), (dead, 30)])
        let plan = try #require(SilenceCompactor.plan(frameRMS: rms, sampleCount: 110 * f))
        // 3 dead frames survive next to every side of sound.
        #expect(plan.spans == [
            .init(originalStart: 37 * f, compactedStart: 0, length: 16 * f),
            .init(originalStart: 67 * f, compactedStart: 16 * f, length: 16 * f),
        ])
        #expect(plan.compactedSampleCount == 32 * f)
        #expect(abs(plan.removedSeconds - Double(78 * f) / 16_000) < 1e-9)
    }

    @Test func leavesShortPausesAndSoundOnlyFilesUntouched() {
        let f = SilenceCompactor.frameSamples
        // A 12-frame (0.96 s) pause between words is not a dead run.
        #expect(SilenceCompactor.plan(frameRMS: frames([(sound, 10), (dead, 12), (sound, 10)]), sampleCount: 32 * f) == nil)
        #expect(SilenceCompactor.plan(frameRMS: frames([(sound, 50)]), sampleCount: 50 * f) == nil)
        // All silence: nothing to anchor on, the file is used as is.
        #expect(SilenceCompactor.plan(frameRMS: frames([(dead, 200)]), sampleCount: 200 * f) == nil)
        // Quiet but real sound (−60 dBFS) is above the dead floor.
        #expect(SilenceCompactor.plan(frameRMS: frames([(sound, 5), (0.001, 40), (sound, 5)]), sampleCount: 50 * f) == nil)
    }

    @Test func handlesPartialLastFrame() throws {
        let f = SilenceCompactor.frameSamples
        let total = 30 * f + 100   // 31 frames, the last one partial
        let plan = try #require(SilenceCompactor.plan(frameRMS: frames([(sound, 10), (dead, 21)]), sampleCount: total))
        #expect(plan.spans == [.init(originalStart: 0, compactedStart: 0, length: 13 * f)])
        #expect(plan.originalSampleCount == total)
    }

    @Test func mapsTimesBackAcrossRemovedGaps() throws {
        let f = SilenceCompactor.frameSamples
        let plan = try #require(SilenceCompactor.plan(
            frameRMS: frames([(dead, 40), (sound, 10), (dead, 20), (sound, 10)]), sampleCount: 80 * f))
        let frame = 0.08
        // First kept span starts at original frame 37.
        #expect(abs(plan.originalTime(0) - 37 * frame) < 1e-9)
        #expect(abs(plan.originalTime(5 * frame) - 42 * frame) < 1e-9)
        // Junction (compacted frame 16 = original 53 | 67): a time on it belongs to the next span.
        #expect(abs(plan.originalTime(16 * frame) - 67 * frame) < 1e-9)
        // A token ending at the junction ends before the removed gap…
        let word = plan.originalInterval(start: 14 * frame, end: 16 * frame)
        #expect(abs(word.start - 51 * frame) < 1e-9 && abs(word.end - 53 * frame) < 1e-9)
        // …and one whose duration crosses it is clipped instead of stretching over the gap.
        let crossing = plan.originalInterval(start: 15 * frame, end: 19 * frame)
        #expect(abs(crossing.start - 52 * frame) < 1e-9 && abs(crossing.end - 53 * frame) < 1e-9)
        let after = plan.originalInterval(start: 16 * frame, end: 18 * frame)
        #expect(abs(after.start - 67 * frame) < 1e-9 && abs(after.end - 69 * frame) < 1e-9)
        #expect(plan.originalInterval(start: 20 * frame, end: 19 * frame).end >= plan.originalInterval(start: 20 * frame, end: 19 * frame).start)
    }

    @Test func writesKeptSamplesUnchangedAndSkipsFilesWithoutDeadRuns() throws {
        let source = tempURL("source.wav"), destination = tempURL("compacted.wav")
        defer { [source, destination].forEach { try? FileManager.default.removeItem(at: $0) } }
        let writer = try CrashSafeWAVWriter(url: source, sampleRate: 16_000)
        try writer.appendSilence(frames: 48_000)                                    // 3 s paused mic
        try writer.append(sine(frequency: 220, sampleRate: 16_000, seconds: 1, amplitude: 0.01))  // −43 dBFS
        try writer.appendSilence(frames: 64_000)                                    // 4 s
        try writer.close()

        let plan = try #require(try SilenceCompactor.compact(source, to: destination))
        let original = try readAll(source), compacted = try readAll(destination)
        #expect(compacted.count == plan.compactedSampleCount)
        #expect(compacted.count < original.count / 3)
        for span in plan.spans {
            #expect(Array(compacted[span.compactedStart..<span.compactedStart + span.length])
                == Array(original[span.originalStart..<span.originalStart + span.length]))
        }
        // The tone starts ~3 s into the original file and 0.24 s into the compacted one.
        #expect(abs(plan.originalTime(0.24) - 3.0) < 0.081)

        let continuous = tempURL("continuous.wav"), unused = tempURL("unused.wav")
        defer { [continuous, unused].forEach { try? FileManager.default.removeItem(at: $0) } }
        let w2 = try CrashSafeWAVWriter(url: continuous, sampleRate: 16_000)
        try w2.append(sine(frequency: 300, sampleRate: 16_000, seconds: 3))
        try w2.close()
        #expect(try SilenceCompactor.compact(continuous, to: unused) == nil)
        #expect(!FileManager.default.fileExists(atPath: unused.path))
    }

    private func readAll(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
