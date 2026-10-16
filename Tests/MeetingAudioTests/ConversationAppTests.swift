import AVFoundation
import Foundation
import Testing
@testable import MeetingAudio
@testable import MeetingCore

private func process(_ id: UInt32, pid: Int32, bundle: String?, path: String?, input: Bool = false, output: Bool = false) -> AudioProcessInfo {
    AudioProcessInfo(objectID: id, pid: pid, bundleID: bundle, executablePath: path, isRunningOutput: output, isRunningInput: input)
}

private func names(_ path: String) -> (id: String?, name: String) {
    switch path {
    case "/Applications/Microsoft Teams.app": ("com.microsoft.teams2", "Microsoft Teams")
    case "/Applications/zoom.us.app": ("us.zoom.xos", "zoom.us")
    case "/Applications/Google Chrome.app": ("com.google.Chrome", "Google Chrome")
    case "/Applications/Acme Call.app": ("com.acme.call", "Acme Call")
    default: (nil, (path as NSString).lastPathComponent)
    }
}

@Suite("Apps de conversación")
struct ConversationAppResolverTests {
    @Test func groupsHelpersUnderTheirAppAndKeepsAnyApp() {
        let apps = AudioApplicationResolver.group([
            // Real layouts observed on macOS 27 (Teams WebView2 helper, Zoom helpers, Chrome audio service).
            process(1, pid: 10, bundle: "com.microsoft.teams2", path: "/Applications/Microsoft Teams.app/Contents/MacOS/MSTeams"),
            process(2, pid: 11, bundle: "com.microsoft.edgewebview2.helper.renderer",
                    path: "/Applications/Microsoft Teams.app/Contents/Helpers/Microsoft Teams WebView.app/Contents/Frameworks/X.framework/Helpers/H.app/Contents/MacOS/H",
                    input: true, output: true),
            process(3, pid: 20, bundle: "us.zoom.xos", path: "/Applications/zoom.us.app/Contents/MacOS/zoom.us", output: true),
            process(4, pid: 21, bundle: "us.zoom.CptHost", path: "/Applications/zoom.us.app/Contents/Frameworks/CptHost.app/Contents/MacOS/CptHost"),
            process(5, pid: 30, bundle: "com.google.Chrome.helper",
                    path: "/Applications/Google Chrome.app/Contents/Frameworks/G.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/G"),
            process(6, pid: 40, bundle: "com.apple.WebKit.GPU",
                    path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"),
            process(7, pid: 50, bundle: "com.acme.call", path: "/Applications/Acme Call.app/Contents/MacOS/Acme", input: true, output: true),
            process(8, pid: 99, bundle: "dev.meetingintelligence.app", path: "/Apps/Meeting Intelligence.app/Contents/MacOS/MI"),
        ], excludingBundlePath: "/Apps/Meeting Intelligence.app", excludingPID: 0, bundleInfo: names)

        let byName = Dictionary(uniqueKeysWithValues: apps.map { ($0.name, $0) })
        #expect(byName["Microsoft Teams"]?.processes.map(\.objectID) == [1, 2])
        #expect(byName["Microsoft Teams"]?.kind == .conferencing)
        #expect(byName["Microsoft Teams"]?.isUsingInput == true)
        #expect(byName["zoom.us"]?.processes.count == 2)
        #expect(byName["Google Chrome"]?.isolation == .shared)
        #expect(byName["Safari / WebKit"]?.isolation == .shared)
        // Unknown app: still listed and capturable.
        #expect(byName["Acme Call"]?.kind == .other)
        #expect(byName["Acme Call"]?.isolation == .exact)
        // This app is never a source.
        #expect(!apps.contains { $0.bundleIdentifier == "dev.meetingintelligence.app" })
        // Apps in a call (input + output) are listed first.
        #expect(apps.first.map { $0.isUsingInput && $0.isUsingOutput } == true)
    }

    @Test func outermostBundle() {
        #expect(AudioApplicationResolver.outermostAppBundle(of: "/Applications/A.app/Contents/Helpers/B.app/Contents/MacOS/b")
                == "/Applications/A.app")
        #expect(AudioApplicationResolver.outermostAppBundle(of: "/usr/libexec/avconferenced") == nil)
    }

    @Test func liveResolverRuns() {
        // Real HAL: must not crash; never includes this test process.
        let apps = AudioApplicationResolver.currentApplications()
        #expect(!apps.flatMap(\.processes).contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
    }
}

@Suite("Detección de llamadas")
struct CallDetectorTests {
    private func activity(_ key: String, input: Bool, output: Bool, kind: ConversationAppKind = .conferencing,
                          bundle: String? = nil) -> AppAudioActivity {
        AppAudioActivity(app: AudioAppSelector(groupKey: key, bundleIdentifier: bundle ?? key, name: key), kind: kind,
                         isolation: .exact, bundlePath: nil, usingInput: input, usingOutput: output)
    }

    @Test func startsAfterDebounceAndEndsAfterMicRelease() {
        var detector = CallDetector()
        #expect(detector.update([activity("zoom", input: true, output: true)], now: 0).isEmpty)
        #expect(detector.update([activity("zoom", input: true, output: true)], now: 2).isEmpty)
        let started = detector.update([activity("zoom", input: true, output: true)], now: 3.1)
        #expect(started.count == 1)
        if case .callStarted(let a) = started.first { #expect(a.app.groupKey == "zoom") } else { Issue.record("sin inicio") }
        #expect(detector.activeCalls.map(\.app.groupKey) == ["zoom"])
        // Mic released: no end before 25 s.
        #expect(detector.update([activity("zoom", input: false, output: true)], now: 10).isEmpty)
        #expect(detector.update([activity("zoom", input: false, output: false)], now: 30).isEmpty)
        #expect(detector.update([activity("zoom", input: false, output: false)], now: 35.1) == [.callEnded(
            AudioAppSelector(groupKey: "zoom", bundleIdentifier: "zoom", name: "zoom"), .microphoneReleased)])
        #expect(detector.activeCalls.isEmpty)
    }

    @Test func shortMicTestOrInputOnlyDoesNotStartACall() {
        var detector = CallDetector()
        _ = detector.update([activity("teams", input: true, output: true)], now: 0)
        #expect(detector.update([activity("teams", input: false, output: true)], now: 2).isEmpty) // device test
        #expect(detector.update([activity("teams", input: true, output: true)], now: 2.5).isEmpty)
        #expect(detector.update([activity("teams", input: true, output: true)], now: 5).isEmpty) // debounce restarted
        // Dictation-like: mic only, no playback → never a call.
        var dictation = CallDetector()
        _ = dictation.update([activity("notes", input: true, output: false)], now: 0)
        #expect(dictation.update([activity("notes", input: true, output: false)], now: 60).isEmpty)
    }

    @Test func briefRouteChangeDoesNotEndTheCall() {
        var detector = CallDetector()
        _ = detector.update([activity("teams", input: true, output: true)], now: 0)
        _ = detector.update([activity("teams", input: true, output: true)], now: 3)
        // AirPods connected: mic released for 4 s, then reopened.
        #expect(detector.update([activity("teams", input: false, output: true)], now: 20).isEmpty)
        #expect(detector.update([activity("teams", input: true, output: true)], now: 24).isEmpty)
        #expect(detector.update([activity("teams", input: true, output: true)], now: 60).isEmpty)
        #expect(detector.activeCalls.count == 1)
    }

    @Test func appClosingEndsTheCall() {
        var detector = CallDetector()
        _ = detector.update([activity("meet", input: true, output: true, kind: .browser)], now: 0)
        _ = detector.update([activity("meet", input: true, output: true, kind: .browser)], now: 3)
        #expect(detector.update([], now: 10).isEmpty)
        let ended = detector.update([], now: 13.5)
        #expect(ended.count == 1)
        if case .callEnded(_, let reason) = ended.first { #expect(reason == .appClosed) }
    }

    @Test func ignoredAndSystemProcessesNeverTrigger() {
        var detector = CallDetector()
        detector.ignoredAppIDs = ["discord"]
        let snapshot = [activity("discord", input: true, output: true),
                        activity("com.apple.siri", input: true, output: true, kind: .system)]
        _ = detector.update(snapshot, now: 0)
        #expect(detector.update(snapshot, now: 10).isEmpty)
        // FaceTime is a known system conversation app → eligible.
        let facetime = [activity("facetime", input: true, output: true, kind: .system, bundle: "com.apple.avconferenced")]
        _ = detector.update(facetime, now: 20)
        #expect(detector.update(facetime, now: 24).count == 1)
    }
}

@Suite("Pausa del micrófono")
struct MicrophonePauseTests {
    @Test func pauseWritesSilenceAndKeepsTimeline() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mi-pause-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = CaptureClock()
        let recorder = try TrackRecorder(source: .localMicrophone, url: url, outputSampleRate: 16_000, clock: clock,
                                         onLevel: { _, _ in }, onWarning: { _ in })
        let tone = (0..<16_000).map { Float(sin(Double($0) * 0.2)) * 0.5 }
        recorder.ingest(tone, sampleRate: 16_000, hostTime: nil)           // 0–1 s voice
        recorder.setMuted(true, atTimelineSeconds: 1)
        recorder.ingest(tone, sampleRate: 16_000, hostTime: nil)           // 1–2 s paused
        recorder.setMuted(false, atTimelineSeconds: 2)
        recorder.ingest(tone, sampleRate: 16_000, hostTime: nil)           // 2–3 s voice
        let stats = recorder.finish(atTimelineSeconds: 3)
        #expect(stats.pauses == [PauseInterval(start: 1, end: 2)])

        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        #expect(abs(samples.count - 48_000) < 200)                        // timeline preserved
        #expect(samples[20_000..<30_000].allSatisfy { $0 == 0 })           // paused span is silence
        #expect(samples[34_000..<44_000].contains { abs($0) > 0.1 })       // voice after resume
    }
}
