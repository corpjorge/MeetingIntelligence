import AppKit
import MeetingCore
import SwiftUI

/// UI verification aid: when `MI_SNAPSHOT_DIR` is set, the app visits every
/// screen (light and dark), renders its own window to PNG with
/// `cacheDisplay` (no screen-recording permission involved) and quits.
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
            try? await Task.sleep(for: .seconds(2))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: appearance)
                let suffix = appearance == .aqua ? "light" : "dark"
                if !env.settings.hasCompletedOnboarding {
                    capture("00-onboarding-\(suffix)", in: dir, sheet: true)
                    continue
                }
                for section in AppRouter.Section.allCases {
                    router.meetingPath = []
                    router.section = section
                    try? await Task.sleep(for: .seconds(1.5))
                    capture("\(section.rawValue)-\(suffix)", in: dir)
                }
                // Live-recording banners need a real capture; render the component standalone.
                captureComponent("recording-mute-reminder-\(suffix)", in: dir) {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        CallMuteReminderBanner(appName: "Microsoft Teams", onPauseMicrophone: {}, onDismiss: {})
                        CallMuteReminderBanner(appName: nil, onPauseMicrophone: {}, onDismiss: {})
                    }
                }
                // MI_SNAPSHOT_MEETING picks a specific meeting id; default is the first ready one.
                let wanted = ProcessInfo.processInfo.environment["MI_SNAPSHOT_MEETING"]
                // The Settings scene is a separate window; render its pages standalone.
                captureWindowContent("settings-transcription-\(suffix)", in: dir) { TranscriptionSettings().environment(env) }
                captureWindowContent("settings-models-\(suffix)", in: dir) { ModelSettings().environment(env) }
                if let first = try? env.database.meetingRows().first(where: {
                    $0.meeting.status == .ready && (wanted == nil || $0.id == wanted)
                }) {
                    for tab in MeetingDetailTab.allCases {
                        router.openMeeting(first.id, tab: tab)
                        try? await Task.sleep(for: .seconds(1.5))
                        capture("meeting-\(tab.rawValue)-\(suffix)", in: dir)
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
            NSApp.terminate(nil)
        }
    }

    @MainActor
    static func capture(_ name: String, in dir: URL, sheet: Bool = false) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
        guard let window = sheet ? (windows.compactMap(\.attachedSheet).first ?? windows.first) : windows.first(where: { $0.attachedSheet == nil }) ?? windows.first,
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
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
    static func captureComponent(_ name: String, in dir: URL, @ViewBuilder _ content: () -> some View) {
        let host = NSHostingView(rootView: content()
            .padding(DS.Space.xl)
            .frame(width: DS.Layout.readingMaxWidth, alignment: .leading)
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

    /// Renders a full-height page (e.g. a settings Form) in an offscreen window.
    @MainActor
    static func captureWindowContent(_ name: String, in dir: URL, @ViewBuilder _ content: () -> some View) {
        let host = NSHostingView(rootView: content().frame(width: 720, height: 1100))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 1100),
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
