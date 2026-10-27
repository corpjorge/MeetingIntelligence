import AppKit
import MeetingCore
import ScreenCaptureKit
import SwiftUI

/// UI verification aid: when `MI_SNAPSHOT_DIR` is set, the app visits every
/// screen (light and dark), saves its own window as PNG and quits. The window is
/// captured with ScreenCaptureKit's current-process content (no screen-recording
/// permission: only this app's windows), which renders vibrancy such as the sidebar;
/// `cacheDisplay` is the fallback.
/// Inactive in normal use.
enum SnapshotDriver {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["MI_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func runIfRequested(router: AppRouter, env: AppEnvironment) {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        env.settings.hasCompletedOnboarding = ProcessInfo.processInfo.environment["MI_SNAPSHOT_ONBOARDING"] == nil
        Task { @MainActor in
            // Frontmost, so the window is drawn active (traffic lights, sidebar selection).
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(2))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: appearance)
                let suffix = appearance == .aqua ? "light" : "dark"
                if ProcessInfo.processInfo.environment["MI_SNAPSHOT_ANALYSIS_ONLY"] == "1" {
                    if env.ai.statuses.isEmpty { await env.ai.refreshStatuses() }
                    captureAnalysisControls(suffix: suffix, in: dir, env: env)
                    continue
                }
                if ProcessInfo.processInfo.environment["MI_SNAPSHOT_COMMITMENTS_ONLY"] == "1" {
                    captureOpenCommitments(suffix: suffix, in: dir)
                    continue
                }
                if !env.settings.hasCompletedOnboarding {
                    await capture("00-onboarding-\(suffix)", in: dir, sheet: true)
                    continue
                }
                for section in AppRouter.Section.allCases {
                    router.meetingPath = []
                    router.section = section
                    try? await Task.sleep(for: .seconds(1.5))
                    await capture("\(section.rawValue)-\(suffix)", in: dir)
                }
                // Live-recording banners need a real capture; render the component standalone.
                captureComponent("recording-mute-reminder-\(suffix)", in: dir) {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        CallMuteReminderBanner(appName: "Microsoft Teams", onPauseMicrophone: {}, onDismiss: {})
                        CallMuteReminderBanner(appName: nil, onPauseMicrophone: {}, onDismiss: {})
                    }
                }
                captureUpdateStates(suffix: suffix, in: dir, env: env)
                captureOpenCommitments(suffix: suffix, in: dir)
                captureComponent("model-setup-banner-\(suffix)", in: dir) { ModelSetupBanner().environment(env) }
                captureComponent("ai-consent-sheet-\(suffix)", in: dir) {
                    RemoteConsentSheet(request: .init(provider: .codex, summary: "Se compartirán la pregunta y 13 extractos de transcripción de 1 reunión(es) (texto, hablante y marca de tiempo). No se comparte audio ni perfiles de voz.",
                                                      characterCount: 1_914, onConfirm: {}))
                        .environment(env)
                }
                // Provider cards (local detection only; the Intelligence screen runs it too).
                if env.ai.statuses.isEmpty { await env.ai.refreshStatuses() }
                captureWindowContent("intelligence-providers-\(suffix)", in: dir) { ProvidersPane().environment(env) }
                // MI_SNAPSHOT_MEETING picks a specific meeting id; default is the first ready one.
                let wanted = ProcessInfo.processInfo.environment["MI_SNAPSHOT_MEETING"]
                // The Settings scene is a separate window; render its pages standalone.
                // MI_SNAPSHOT_CHECK_MODELS=1 queries Hugging Face first so versions show their state.
                if ProcessInfo.processInfo.environment["MI_SNAPSHOT_CHECK_MODELS"] == "1", appearance == .aqua {
                    await env.modelUpdates.checkForUpdates()
                }
                captureWindowContent("settings-transcription-\(suffix)", in: dir) { TranscriptionSettings().environment(env) }
                captureWindowContent("settings-models-\(suffix)", in: dir) { ModelSettings().environment(env) }
                if let first = try? env.database.meetingRows().first(where: {
                    $0.meeting.status == .ready && (wanted == nil || $0.id == wanted)
                }) {
                    for tab in MeetingDetailTab.allCases {
                        router.openMeeting(first.id, tab: tab)
                        try? await Task.sleep(for: .seconds(1.5))
                        await capture("meeting-\(tab.rawValue)-\(suffix)", in: dir)
                    }
                    // Low-confidence rows are usually below the fold; render the first one standalone.
                    if let detail = try? env.database.meetingDetail(id: first.id),
                       let flagged = detail.segments.first(where: \.isLowConfidence) {
                        captureComponent("transcript-low-confidence-\(suffix)", in: dir) {
                            SegmentRow(segment: flagged, speakerName: detail.speakerName(for: flagged), colorIndex: nil,
                                       showSpeaker: true, isActive: false, isMatch: false, query: "", isEditing: false,
                                       onSeek: {}, onEdit: {}, onSave: { _ in }, onCancel: {}, onRevert: {})
                        }
                    }
                }
            }
            // The onboarding sheet would make AppKit ignore a plain terminate.
            AppUpdateController.terminateClosingSheets()
        }
    }

    @MainActor
    static func capture(_ name: String, in dir: URL, sheet: Bool = false) async {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
        guard let window = sheet ? (windows.compactMap(\.attachedSheet).first ?? windows.first) : windows.first(where: { $0.attachedSheet == nil }) ?? windows.first,
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        let file = dir.appendingPathComponent("\(name).png")
        if let image = await screenCapture(window),
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: file)
        } else {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: file) }
        }
        // Structural check that does not depend on offscreen rendering.
        var lines: [String] = []
        func walk(_ v: NSView, depth: Int) {
            if let table = v as? NSTableView {
                let rows = (0..<table.numberOfRows).compactMap { r -> String? in
                    guard let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) else { return nil }
                    return Self.texts(in: cell).joined(separator: " ")
                }
                lines.append("\(type(of: table)) rows=\(table.numberOfRows) frame=\(table.frame) visible=\(!table.isHiddenOrHasHiddenAncestor) window=\(table.window != nil): \(rows)")
            }
            for sub in v.subviews { walk(sub, depth: depth + 1) }
        }
        walk(window.contentView?.superview ?? view, depth: 0)
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("\(name).views.txt"), atomically: true, encoding: .utf8)
    }

    /// Renders one component offscreen at the recording view's reading width (current `NSApp.appearance`).
    @MainActor
    static func captureComponent(_ name: String, in dir: URL, width: CGFloat = DS.Layout.readingMaxWidth,
                                 @ViewBuilder _ content: () -> some View) {
        let host = NSHostingView(rootView: content()
            .padding(DS.Space.xl)
            .frame(width: width, alignment: .leading)
            .background(DS.Color.background))
        host.appearance = NSApp.appearance
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    @MainActor
    static func captureAnalysisControls(suffix: String, in dir: URL, env: AppEnvironment) {
        let model = MeetingDetailModel()
        let item = AnalysisItem(analysisId: "fixture", meetingId: "fixture", category: .actionItem, nature: .fact,
                                text: "Documentar las validaciones pendientes y compartir el resultado de las pruebas con el equipo.",
                                ownerName: "Equipo de desarrollo", dueText: "Antes del viernes",
                                evidenceQuote: "Compartimos el resultado antes de la próxima reunión.",
                                evidenceStartTime: 208, evidenceSpeakerName: "Hablante 1", evidenceStatus: .verified,
                                orderIndex: 0)
        for provider in [AIProviderKind.copilotCLI, .codex] {
            env.ai.selectedProvider = provider
            env.ai.selectModel(provider == .codex ? env.ai.modelChoices(for: provider).first ?? "" : "", for: provider)
            for (name, width) in [("wide", DS.Layout.contentMaxWidth), ("narrow", DS.Layout.singleColumnMaxWidth)] {
                captureComponent("analysis-models-copy-\(provider.rawValue)-\(name)-\(suffix)", in: dir, width: width) {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {
                        AnalysisRunBar(meetingId: "fixture", hasTranscript: true)
                        ItemsSection(category: .actionItem, items: [item], model: model, showsCompletion: true)
                    }
                    .environment(env)
                }
            }
        }
    }

    /// Pending-items sheet with long text, more than eight rows, and the empty state.
    @MainActor
    static func captureOpenCommitments(suffix: String, in dir: URL) {
        let model = DashboardModel()
        model.meetingTitles = ["fixture": "FIXTURE · Seguimiento del proyecto"]
        model.openItems = (0..<12).map { index in
            AnalysisItem(analysisId: "fixture", meetingId: "fixture", category: .commitment,
                         nature: index == 1 ? .interpretation : .fact,
                         text: index == 0
                            ? "Documentar las validaciones pendientes del servicio y compartir con el equipo el resultado de las pruebas antes de la próxima reunión de seguimiento."
                            : "FIXTURE · Revisar el compromiso \(index + 1) con el equipo.",
                         ownerName: "Equipo de desarrollo", dueText: "Antes del viernes",
                         evidenceQuote: index == 0 ? "Compartimos el resultado antes de la próxima reunión." : nil,
                         evidenceStatus: index == 0 ? .verified : .unconfirmed, orderIndex: index)
        }
        captureComponent("dashboard-open-commitments-\(suffix)", in: dir) {
            OpenCommitmentsView(model: model, onSetCompleted: { _, _ in }, onOpenMeeting: { _ in })
        }
        model.openItems = []
        captureComponent("dashboard-open-commitments-empty-\(suffix)", in: dir) {
            OpenCommitmentsView(model: model, onSetCompleted: { _, _ in }, onOpenMeeting: { _ in })
        }
    }

    /// App update banner and sheet in their main states, with a fixed fake release (no network).
    @MainActor
    static func captureUpdateStates(suffix: String, in dir: URL, env: AppEnvironment) {
        let notes = """
        ## Novedades
        - **Actualizaciones desde la app**: avisa cuando hay una versión nueva, la descarga y la instala.
        - La descarga se verifica con una firma Ed25519 antes de reemplazar nada.
        - Codex se ejecuta sin tu `config.toml` y sin poder ejecutar comandos.

        ## Instalación
        | Archivo | Uso |
        """
        let asset = AppRelease.Asset(name: "Meeting-Intelligence-9.9.9.zip",
                                     url: URL(string: "https://example.invalid/a.zip")!, size: 23_500_000)
        let release = AppRelease(version: AppVersion("9.9.9")!, versionString: "9.9.9", tag: "v9.9.9",
                                 title: "Meeting Intelligence 9.9.9", notes: notes,
                                 pageURL: URL(string: "https://github.com/corpjorge/MeetingIntelligence/releases")!,
                                 publishedAt: Date(timeIntervalSince1970: 1_792_670_400), isPrerelease: false,
                                 archive: asset, signature: asset)
        let fake = AppUpdateController(configuration: nil, settings: AppSettings(
            defaults: UserDefaults(suiteName: "dev.meetingintelligence.snapshot.updates") ?? .standard),
            bundleURL: Bundle.main.bundleURL)
        let states: [(String, AppUpdateController.Phase)] = [
            ("available", .available), ("downloading", .downloading(0.42)), ("ready", .ready),
            ("failed", .failed(AppUpdateError.invalidSignature.localizedDescription)),
        ]
        for (name, phase) in states {
            fake.showForSnapshot(release, phase: phase)
            captureComponent("update-banner-\(name)-\(suffix)", in: dir) { AppUpdateBannerContent(updates: fake) }
            captureComponent("update-sheet-\(name)-\(suffix)", in: dir) { AppUpdatePanel(updates: fake) }
        }
        fake.showForSnapshot(nil, phase: .upToDate)
        captureComponent("update-sheet-uptodate-\(suffix)", in: dir) { AppUpdatePanel(updates: fake) }
        captureWindowContent("settings-general-\(suffix)", in: dir) { GeneralSettings().environment(env) }
    }

    /// The composited window as the user sees it (this process's own window only).
    static func screenCapture(_ window: NSWindow) async -> CGImage? {
        guard let content = try? await SCShareableContent.currentProcess,
              let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Renders a full-height page (e.g. a settings Form) in an offscreen window.
    @MainActor
    static func captureWindowContent(_ name: String, in dir: URL, @ViewBuilder _ content: () -> some View) {
        let host = NSHostingView(rootView: content().frame(width: 720, height: 1500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 1500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApp.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    @MainActor
    static func texts(in view: NSView) -> [String] {
        var result: [String] = []
        if let label = view.accessibilityLabel(), !label.isEmpty { result.append(label) }
        if let field = view as? NSTextField { result.append(field.stringValue) }
        for sub in view.subviews { result += texts(in: sub) }
        return result
    }
}
