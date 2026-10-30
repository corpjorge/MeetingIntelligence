import AppKit
import Foundation
import MeetingAudio
import Observation
import OSLog
import UserNotifications

/// Turns `CallMonitor` events into *suggestions*. It never starts or stops a
/// recording: the user decides from the in-app banner, the menu bar or a
/// notification.
@Observable
final class CallSuggestionController {
    /// Every app currently registered as an audio client (for the source picker).
    private(set) var audioApps: [AppAudioActivity] = []
    private(set) var activeCalls: [AppAudioActivity] = []
    /// "<App> está en una llamada — ¿Grabar?"
    private(set) var startSuggestion: AppAudioActivity?
    /// "Parece que la llamada de <App> terminó — ¿Detener?"
    private(set) var endSuggestion: AudioAppSelector?
    private var endSuggestionMeetingId: String?
    private var trackedMeetingId: String?

    private let monitor = CallMonitor()
    private let settings: AppSettings
    private let recording: RecordingController
    private let notifications = NotificationBridge()
    private var tasks: [Task<Void, Never>] = []
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "call-suggestions")
    var onAcceptStart: ((AudioAppSelector) -> Void)?

    init(settings: AppSettings, recording: RecordingController) {
        self.settings = settings
        self.recording = recording
        trackRecording()
    }

    func start(requestNotifications: Bool = true) {
        guard tasks.isEmpty else { return }
        monitor.start(ignoredAppIDs: Set(settings.ignoredCallApps))
        let snapshots = monitor.snapshots
        let events = monitor.events
        tasks.append(Task { [weak self] in
            for await snapshot in snapshots { self?.audioApps = snapshot }
        })
        tasks.append(Task { [weak self] in
            for await event in events { self?.handle(event) }
        })
        notifications.onAction = { [weak self] action in self?.handleNotification(action) }
        if requestNotifications, settings.systemNotifications { notifications.requestAuthorization() }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        settings.systemNotifications = enabled
        if enabled { notifications.requestAuthorization() }
    }

    // MARK: Events

    func handle(_ event: CallEvent) {
        switch event {
        case .callStarted(let activity):
            activeCalls.removeAll { $0.id == activity.id }
            activeCalls.append(activity)
            guard settings.suggestRecording, !recording.isActive else { return }
            startSuggestion = activity
            if settings.systemNotifications {
                notifications.post(id: "call-start-\(activity.id)", title: "\(activity.app.name) está en una llamada",
                                   body: "¿Grabar y transcribir esta conversación? Nada se graba sin tu confirmación.",
                                   category: NotificationBridge.startCategory, userInfo: ["app": activity.id])
            }
        case .callEnded(let app, let reason):
            activeCalls.removeAll { $0.id == app.groupKey }
            if startSuggestion?.id == app.groupKey { startSuggestion = nil }
            notifications.remove(id: "call-start-\(app.groupKey)")
            guard settings.suggestStop, recording.isActive, recording.recordingApp?.groupKey == app.groupKey,
                  let meetingId = recording.meeting?.id else { return }
            clearEndSuggestion()
            endSuggestion = app
            endSuggestionMeetingId = meetingId
            if settings.systemNotifications {
                let detail = reason == .appClosed ? "\(app.name) se cerró." : "\(app.name) dejó de usar el micrófono."
                notifications.post(id: Self.endNotificationId(app.groupKey), title: "Parece que la llamada terminó",
                                   body: "\(detail) ¿Detener y guardar la grabación?",
                                   category: NotificationBridge.endCategory,
                                   userInfo: ["app": app.groupKey, "meeting": meetingId])
            }
        }
    }

    // MARK: User decisions

    func acceptStart() {
        guard let suggestion = startSuggestion else { return }
        startSuggestion = nil
        notifications.remove(id: "call-start-\(suggestion.id)")
        NSApp.activate()
        onAcceptStart?(suggestion.app)
    }

    func dismissStart() {
        if let id = startSuggestion?.id { notifications.remove(id: "call-start-\(id)") }
        startSuggestion = nil
    }

    func ignoreApp(_ groupKey: String) {
        if !settings.ignoredCallApps.contains(groupKey) { settings.ignoredCallApps.append(groupKey) }
        monitor.setIgnoredApps(Set(settings.ignoredCallApps))
        if startSuggestion?.id == groupKey { dismissStart() }
    }

    func unignoreApp(_ groupKey: String) {
        settings.ignoredCallApps.removeAll { $0 == groupKey }
        monitor.setIgnoredApps(Set(settings.ignoredCallApps))
    }

    func stopRecordingFromSuggestion() {
        guard let app = endSuggestion, let meetingId = endSuggestionMeetingId else { return }
        clearEndSuggestion()
        stopIfCurrent(app: app.groupKey, meetingId: meetingId)
    }

    func keepRecording() {
        clearEndSuggestion()
    }

    func handleNotification(_ action: NotificationBridge.Action) {
        switch action {
        case .record: acceptStart()
        case .ignore(let id): ignoreApp(id)
        case .stop(let app, let meetingId):
            if endSuggestionMeetingId == meetingId { clearEndSuggestion() }
            guard let meetingId, stopIfCurrent(app: app, meetingId: meetingId) else {
                notifications.remove(id: Self.endNotificationId(app))
                NSApp.activate()
                return
            }
        case .keep(let app, let meetingId):
            if endSuggestionMeetingId == meetingId { clearEndSuggestion() }
            notifications.remove(id: Self.endNotificationId(app))
        case .open: NSApp.activate()
        }
    }

    @discardableResult
    private func stopIfCurrent(app: String, meetingId: String) -> Bool {
        guard recording.isActive, recording.meeting?.id == meetingId, recording.recordingApp?.groupKey == app else {
            logger.notice("Ignored a stop suggestion for a recording that is no longer active")
            return false
        }
        recording.stop()
        return true
    }

    private func clearEndSuggestion() {
        if let app = endSuggestion { notifications.remove(id: Self.endNotificationId(app.groupKey)) }
        endSuggestion = nil
        endSuggestionMeetingId = nil
    }

    private func trackRecording() {
        let current = withObservationTracking {
            recording.isActive ? recording.meeting?.id : nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackRecording() }
        }
        recordingChanged(to: current)
    }

    private func recordingChanged(to meetingId: String?) {
        defer { trackedMeetingId = meetingId }
        if endSuggestion != nil, endSuggestionMeetingId != meetingId { clearEndSuggestion() }
        if meetingId != nil, trackedMeetingId != meetingId { dismissStart() }
    }

    private static func endNotificationId(_ groupKey: String) -> String { "call-end-\(groupKey)" }
}

/// Wraps UNUserNotificationCenter (delegate callbacks arrive off the main actor).
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    nonisolated enum Action: Sendable, Equatable {
        case record
        case ignore(String)
        case stop(app: String, meeting: String?)
        case keep(app: String, meeting: String?)
        case open

        init(identifier: String, app: String, meeting: String?) {
            self = switch identifier {
            case "RECORD": .record
            case "IGNORE": .ignore(app)
            case "STOP": .stop(app: app, meeting: meeting)
            case "KEEP": .keep(app: app, meeting: meeting)
            default: .open
            }
        }
    }

    static let startCategory = "CALL_START"
    static let endCategory = "CALL_END"
    var onAction: (@MainActor (Action) -> Void)?
    private var configured = false

    private var center: UNUserNotificationCenter? {
        // Notifications require a real app bundle (not available to bare executables/tests).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard let center else { return }
        if !configured {
            configured = true
            center.delegate = self
            let record = UNNotificationAction(identifier: "RECORD", title: "Grabar", options: [.foreground])
            let ignore = UNNotificationAction(identifier: "IGNORE", title: "Ignorar esta app", options: [])
            let stop = UNNotificationAction(identifier: "STOP", title: "Detener y guardar", options: [.foreground])
            let keep = UNNotificationAction(identifier: "KEEP", title: "Seguir grabando", options: [])
            center.setNotificationCategories([
                UNNotificationCategory(identifier: Self.startCategory, actions: [record, ignore], intentIdentifiers: []),
                UNNotificationCategory(identifier: Self.endCategory, actions: [stop, keep], intentIdentifiers: []),
            ])
        }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(id: String, title: String, body: String, category: String, userInfo: [String: String]) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = userInfo
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func remove(id: String) {
        center?.removePendingNotificationRequests(withIdentifiers: [id])
        center?.removeDeliveredNotifications(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let action = Action(identifier: response.actionIdentifier, app: userInfo["app"] as? String ?? "",
                            meeting: userInfo["meeting"] as? String)
        Task { @MainActor [weak self] in self?.onAction?(action) }
        completionHandler()
    }
}
