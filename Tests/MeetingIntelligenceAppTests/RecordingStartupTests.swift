import Foundation
import MeetingAudio
import MeetingCore
import MeetingSpeech
import Testing
@testable import MeetingIntelligenceApp

private actor DelayedCaptureStart {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("App: inicio de captura cancelable")
struct RecordingStartupTests {
    @Test func physicalProbeRequiresTemporaryLibraryAndAcceptsMacOSAlias() {
        #expect(MicrophoneVerificationDriver.isTemporaryLibrary("/private/tmp/mi-test/library"))
        #expect(MicrophoneVerificationDriver.isTemporaryLibrary("/tmp/mi-test/library"))
        #expect(!MicrophoneVerificationDriver.isTemporaryLibrary("/Users/example/Library"))
        #expect(!MicrophoneVerificationDriver.isTemporaryLibrary("/tmp/../Users/example"))
    }

    @Test(arguments: [false, true])
    func delayedNativeStartAllowsCancellationAndCannotLaterBecomeRecording(timeout: Bool) async throws {
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase.open(paths: paths)
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let settings = AppSettings(defaults: defaults.defaults)
        settings.liveTranscription = false
        let delayed = DelayedCaptureStart()
        let recording = RecordingController(importer: MeetingImportService(database: db, paths: paths), paths: paths,
                                             settings: settings, asr: ParakeetUltraProvider(),
                                             startCapture: { _ in await delayed.wait() },
                                             startupLimit: timeout ? .milliseconds(30) : .seconds(15))
        let start = Task { await recording.start(title: "FIXTURE", target: .none, captureMicrophone: false) }
        for _ in 0..<200 {
            if await delayed.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await delayed.entered)
        #expect(recording.state == .starting)
        #expect(recording.activityLabel == "Preparando grabación…")
        if timeout {
            for _ in 0..<200 {
                if recording.cancellingStart { break }
                try await Task.sleep(for: .milliseconds(5))
            }
        } else { recording.stop() }
        #expect(recording.cancellingStart)
        #expect(recording.activityLabel == "Cancelando inicio…")
        await delayed.release()
        await start.value
        if timeout { guard case .failed = recording.state else { Issue.record("Timed out capture was not marked failed"); return } }
        else { #expect(recording.state == .idle) }
        #expect(!recording.isActive)
        #expect(recording.meeting == nil)
        #expect(try db.meetingRows().isEmpty)
    }
}
