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

    @Test func endSuggestionNeverOutlivesItsRecording() async throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = NSApplication.shared
        let db = try AppDatabase.open(paths: paths)
        let settings = AppSettings(defaults: suite.defaults)
        settings.systemNotifications = false
        settings.liveTranscription = false
        let recording = RecordingController(importer: MeetingImportService(database: db, paths: paths), paths: paths,
                                            settings: settings, asr: ParakeetUltraProvider(), startCapture: { _ in })
        let calls = CallSuggestionController(settings: settings, recording: recording)

        calls.handle(.callStarted(Self.activity()))
        #expect(calls.startSuggestion != nil)
        await recording.start(title: "FIXTURE 1", target: .application(Self.zoom), captureMicrophone: false)
        #expect(recording.state == .recording)
        let first = try #require(recording.meeting?.id)
        try await waitUntil { calls.startSuggestion == nil }

        calls.handle(.callEnded(Self.zoom, .microphoneReleased))
        #expect(calls.endSuggestion == Self.zoom)
        recording.stop()
        try await waitUntil { !recording.isActive }
        try await waitUntil { calls.endSuggestion == nil }

        await recording.start(title: "FIXTURE 2", target: .application(Self.zoom), captureMicrophone: false)
        let second = try #require(recording.meeting?.id)
        #expect(second != first)
        #expect(calls.endSuggestion == nil)

        calls.handleNotification(.stop(app: Self.zoom.groupKey, meeting: first))
        calls.handleNotification(.stop(app: Self.zoom.groupKey, meeting: nil))
        calls.stopRecordingFromSuggestion()
        #expect(recording.state == .recording)

        calls.handle(.callEnded(Self.zoom, .appClosed))
        #expect(calls.endSuggestion == Self.zoom)
        calls.handleNotification(.stop(app: Self.zoom.groupKey, meeting: second))
        #expect(calls.endSuggestion == nil)
        try await waitUntil { !recording.isActive }
        #expect(try db.meeting(id: second)?.status == .recorded)
    }

    @Test func notificationActionsCarryTheRecordingTheyWereMadeFor() {
        #expect(NotificationBridge.Action(identifier: "STOP", app: "a", meeting: "m") == .stop(app: "a", meeting: "m"))
        #expect(NotificationBridge.Action(identifier: "KEEP", app: "a", meeting: nil) == .keep(app: "a", meeting: nil))
        #expect(NotificationBridge.Action(identifier: "RECORD", app: "a", meeting: nil) == .record)
        #expect(NotificationBridge.Action(identifier: "IGNORE", app: "a", meeting: nil) == .ignore("a"))
        #expect(NotificationBridge.Action(identifier: "com.apple.UNNotificationDefaultActionIdentifier", app: "a",
                                          meeting: nil) == .open)
    }
}
