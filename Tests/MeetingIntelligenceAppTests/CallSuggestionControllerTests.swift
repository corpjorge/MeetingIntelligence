import AppKit
import Foundation
import MeetingAudio
import MeetingCore
import MeetingSpeech
import Testing
@testable import MeetingIntelligenceApp

/// Call detection only produces suggestions; recording never starts or stops by itself.
@Suite("App: sugerencias de llamada")
struct CallSuggestionControllerTests {
    private static let zoom = AudioAppSelector(groupKey: "us.zoom.xos", bundleIdentifier: "us.zoom.xos", name: "zoom.us")

    private static func activity(_ app: AudioAppSelector = zoom) -> AppAudioActivity {
        AppAudioActivity(app: app, kind: .conferencing, isolation: .exact, bundlePath: nil,
                         usingInput: true, usingOutput: true)
    }

    private func makeController(_ suite: IsolatedDefaults, _ paths: AppPaths) throws
        -> (CallSuggestionController, AppSettings, RecordingController) {
        let db = try AppDatabase.inMemory()
        let settings = AppSettings(defaults: suite.defaults)
        settings.systemNotifications = false
        let recording = RecordingController(importer: MeetingImportService(database: db, paths: paths), paths: paths,
                                            settings: settings, asr: ParakeetUltraProvider())
        return (CallSuggestionController(settings: settings, recording: recording), settings, recording)
    }

    @Test func callStartSuggestsRecordingOnlyWhenEnabled() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (calls, settings, recording) = try makeController(suite, paths)

        calls.handle(.callStarted(Self.activity()))
        calls.handle(.callStarted(Self.activity())) // same app again → listed once
        #expect(calls.activeCalls.map(\.id) == ["us.zoom.xos"])
        #expect(calls.startSuggestion?.id == "us.zoom.xos")
        #expect(!recording.isActive) // a suggestion never starts anything

        calls.dismissStart()
        #expect(calls.startSuggestion == nil)

        settings.suggestRecording = false
        calls.handle(.callStarted(Self.activity()))
        #expect(calls.startSuggestion == nil)
        #expect(calls.activeCalls.count == 1)
    }

    @Test func callEndClearsSuggestionAndOnlyOffersStopWhileRecordingThatApp() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (calls, _, _) = try makeController(suite, paths)

        calls.handle(.callStarted(Self.activity()))
        calls.handle(.callEnded(Self.zoom, .microphoneReleased))
        #expect(calls.activeCalls.isEmpty)
        #expect(calls.startSuggestion == nil)
        #expect(calls.endSuggestion == nil) // nothing is being recorded
    }

    @Test func ignoredAppsArePersistedAndDismissTheirSuggestion() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (calls, settings, _) = try makeController(suite, paths)

        calls.handle(.callStarted(Self.activity()))
        calls.ignoreApp("us.zoom.xos")
        calls.ignoreApp("us.zoom.xos")
        #expect(calls.startSuggestion == nil)
        #expect(settings.ignoredCallApps == ["us.zoom.xos"])
        #expect(AppSettings(defaults: suite.defaults).ignoredCallApps == ["us.zoom.xos"])

        calls.unignoreApp("us.zoom.xos")
        #expect(settings.ignoredCallApps.isEmpty)
    }

    @Test func acceptingHandsTheAppToTheUserFlow() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = NSApplication.shared // acceptStart() brings the app forward
        let (calls, _, recording) = try makeController(suite, paths)
        var accepted: AudioAppSelector?
        calls.onAcceptStart = { accepted = $0 }

        calls.handle(.callStarted(Self.activity()))
        calls.acceptStart()
        #expect(accepted == Self.zoom)
        #expect(calls.startSuggestion == nil)
        #expect(!recording.isActive) // the recording view still needs the user's explicit start
    }
}
