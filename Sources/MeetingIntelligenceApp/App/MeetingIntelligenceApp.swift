import AppKit
import MeetingCore
import SwiftUI

@main
struct MeetingIntelligenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup(AppIdentity.displayName, id: "main") {
            RootView()
                .environment(environment)
                .environment(router)
                .frame(minWidth: 1000, minHeight: 640)
                .tint(DS.Color.accent)
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(router: router, environment: environment) }

        Settings {
            SettingsView()
                .environment(environment)
                .environment(router)
                .tint(DS.Color.accent)
        }

        MenuBarExtra(isInserted: .constant(true)) {
            MenuBarContent()
                .environment(environment)
                .environment(router)
        } label: {
            MenuBarLabel(recording: environment.recording)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM executables launch as background agents unless told otherwise.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Global navigation state.
@Observable
final class AppRouter {
    enum Section: String, Hashable, CaseIterable, Identifiable {
        case dashboard, meetings, recording, participants, intelligence

        var id: String { rawValue }
        var title: String {
            switch self {
            case .dashboard: "Inicio"
            case .meetings: "Reuniones"
            case .recording: "Grabar"
            case .participants: "Participantes"
            case .intelligence: "Inteligencia"
            }
        }
        var systemImage: String {
            switch self {
            case .dashboard: "square.grid.2x2"
            case .meetings: "rectangle.stack"
            case .recording: "record.circle"
            case .participants: "person.2"
            case .intelligence: "sparkles"
            }
        }
    }

    var section: Section = .dashboard
    var meetingPath: [String] = []
    var isImporting = false
    var pendingSearch: String?

    func openMeeting(_ id: String, tab: MeetingDetailTab? = nil) {
        section = .meetings
        meetingPath = [id]
        if let tab { requestedDetailTab = tab }
    }

    var requestedDetailTab: MeetingDetailTab?
}

struct AppCommands: Commands {
    let router: AppRouter
    let environment: AppEnvironment

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Nueva grabación") { router.section = .recording }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Importar audio…") { router.section = .meetings; router.isImporting = true }
                .keyboardShortcut("i", modifiers: .command)
        }
        CommandMenu("Grabación") {
            Button(environment.recording.state == .paused ? "Reanudar" : "Pausar") {
                if environment.recording.state == .paused { environment.recording.resume() } else { environment.recording.pause() }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!environment.recording.isActive)
            Button("Detener y guardar") { environment.recording.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!environment.recording.isActive)
        }
    }
}
