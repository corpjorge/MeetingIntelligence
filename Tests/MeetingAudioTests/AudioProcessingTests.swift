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
