public import CoreAudio
import Foundation
import MeetingCore

/// How a conversation app's audio can be isolated.
public enum CaptureIsolation: String, Sendable, Codable {
    /// The app's own processes carry only its audio (Teams, Zoom, Webex…).
    case exact
    /// The audio process is shared (browser audio service = every tab; WebKit GPU
    /// process; system conferencing daemon). Capture may include unrelated audio.
    case shared
}

public enum ConversationAppKind: String, Sendable, Codable {
    case conferencing
    case browser
    case system
    case other
}

/// Known apps — used only to *describe* audio apps (name, kind, isolation).
/// It never restricts capture: any app that plays audio can be recorded.
public struct ConversationAppCatalog: Sendable {
    public struct Entry: Sendable {
        public let name: String
        public let bundlePrefixes: [String]
        public let kind: ConversationAppKind
        public let isolation: CaptureIsolation
    }

    /// Bundle IDs verified on the development Mac (16-oct-2026): Teams, Zoom, Chrome,
    /// Edge, Safari/WebKit GPU. The rest come from the vendors' published bundles and
    /// are only cosmetic if wrong (unknown apps still work as "other").
    public static let entries: [Entry] = [
        Entry(name: "Microsoft Teams", bundlePrefixes: ["com.microsoft.teams"], kind: .conferencing, isolation: .exact),
        Entry(name: "Zoom", bundlePrefixes: ["us.zoom."], kind: .conferencing, isolation: .exact),
        Entry(name: "Webex", bundlePrefixes: ["com.cisco.webex", "Cisco-Systems.Spark", "com.webex."], kind: .conferencing, isolation: .exact),
        Entry(name: "Slack", bundlePrefixes: ["com.tinyspeck.slackmacgap"], kind: .conferencing, isolation: .exact),
        Entry(name: "Discord", bundlePrefixes: ["com.hnc.Discord"], kind: .conferencing, isolation: .exact),
        Entry(name: "WhatsApp", bundlePrefixes: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"], kind: .conferencing, isolation: .exact),
        Entry(name: "Skype", bundlePrefixes: ["com.skype."], kind: .conferencing, isolation: .exact),
        Entry(name: "GoTo Meeting", bundlePrefixes: ["com.logmein."], kind: .conferencing, isolation: .exact),
        Entry(name: "RingCentral", bundlePrefixes: ["com.ringcentral."], kind: .conferencing, isolation: .exact),
        Entry(name: "Amazon Chime", bundlePrefixes: ["com.amazon.Amazon-Chime"], kind: .conferencing, isolation: .exact),
        Entry(name: "Telegram", bundlePrefixes: ["ru.keepcoder.Telegram", "org.telegram."], kind: .conferencing, isolation: .exact),
        Entry(name: "Signal", bundlePrefixes: ["org.whispersystems.signal-desktop"], kind: .conferencing, isolation: .exact),
        Entry(name: "FaceTime", bundlePrefixes: ["com.apple.FaceTime", "com.apple.avconferenced"], kind: .system, isolation: .shared),
        Entry(name: "Google Chrome", bundlePrefixes: ["com.google.Chrome"], kind: .browser, isolation: .shared),
        Entry(name: "Microsoft Edge", bundlePrefixes: ["com.microsoft.edgemac"], kind: .browser, isolation: .shared),
        Entry(name: "Arc", bundlePrefixes: ["company.thebrowser."], kind: .browser, isolation: .shared),
        Entry(name: "Brave", bundlePrefixes: ["com.brave.Browser"], kind: .browser, isolation: .shared),
        Entry(name: "Firefox", bundlePrefixes: ["org.mozilla.firefox"], kind: .browser, isolation: .shared),
        Entry(name: "Opera", bundlePrefixes: ["com.operasoftware."], kind: .browser, isolation: .shared),
        Entry(name: "Safari / WebKit", bundlePrefixes: ["com.apple.Safari", "com.apple.WebKit"], kind: .browser, isolation: .shared),
    ]

    public static func entry(forBundleID bundleID: String?) -> Entry? {
        guard let bundleID else { return nil }
        let lower = bundleID.lowercased()
        return entries.first { entry in entry.bundlePrefixes.contains { lower.hasPrefix($0.lowercased()) } }
    }
}

/// One application as seen by the audio system: all of its audio processes
/// (main app + helpers inside its bundle) grouped together.
public struct AudioApplication: Sendable, Hashable, Identifiable {
    /// Stable group key: the outermost `.app` bundle path, else the bundle ID.
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let bundlePath: String?
    public let kind: ConversationAppKind
    public let isolation: CaptureIsolation
    public let processes: [AudioProcessInfo]

    public var isUsingInput: Bool { processes.contains(where: \.isRunningInput) }
    public var isUsingOutput: Bool { processes.contains(where: \.isRunningOutput) }
    public var objectIDs: [AudioObjectID] { processes.map(\.objectID) }

    public var selector: AudioAppSelector {
        AudioAppSelector(groupKey: id, bundleIdentifier: bundleIdentifier, name: name)
    }
}

/// Persisted reference to an app chosen as the remote source.
public struct AudioAppSelector: Sendable, Hashable, Codable {
    public var groupKey: String
    public var bundleIdentifier: String?
    public var name: String

    public init(groupKey: String, bundleIdentifier: String?, name: String) {
        self.groupKey = groupKey
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    public func matches(_ app: AudioApplication) -> Bool {
        app.id == groupKey || (bundleIdentifier != nil && app.bundleIdentifier == bundleIdentifier)
    }
}

public enum AudioApplicationResolver {
    /// Outermost `.app` bundle containing an executable path
    /// (`/Applications/Microsoft Teams.app/Contents/Helpers/X.app/...` → Teams).
    public static func outermostAppBundle(of path: String) -> String? {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            components.append(String(component))
            if component.hasSuffix(".app") { return "/" + components.joined(separator: "/") }
        }
        return nil
    }

    /// Groups audio processes into applications. `bundleInfo` resolves a bundle
    /// path to (identifier, display name); injected for tests.
    public static func group(_ processes: [AudioProcessInfo],
                             excludingBundlePath ownBundle: String? = Bundle.main.bundlePath,
                             excludingPID ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
                             bundleInfo: (String) -> (id: String?, name: String) = BundleInfoCache.shared.info) -> [AudioApplication] {
        var groups: [String: (bundlePath: String?, bundleID: String?, name: String, processes: [AudioProcessInfo])] = [:]
        for process in processes where process.pid != ownPID {
            let appPath = process.executablePath.flatMap(outermostAppBundle)
            if let appPath, let ownBundle, appPath == ownBundle { continue }
            // This app is never a recording source, wherever it is installed.
            if process.bundleID == AppIdentity.fallbackBundleIdentifier { continue }
            let key: String
            var bundleID = process.bundleID
            var name: String
            if let appPath {
                key = appPath
                let info = bundleInfo(appPath)
                if info.id == AppIdentity.fallbackBundleIdentifier { continue }
                bundleID = info.id ?? bundleID
                name = info.name
            } else if let id = process.bundleID, !id.isEmpty {
                key = id
                name = (process.executablePath as NSString?)?.lastPathComponent ?? id
            } else {
                key = "pid:\(process.pid)"
                name = (process.executablePath as NSString?)?.lastPathComponent ?? "PID \(process.pid)"
            }
            // Processes outside any .app (WebKit GPU, system daemons) take the catalog name.
            if appPath == nil, let entry = ConversationAppCatalog.entry(forBundleID: process.bundleID) {
                name = entry.name
            }
            groups[key, default: (appPath, bundleID, name, [])].processes.append(process)
        }
        return groups.map { key, value in
            let entry = ConversationAppCatalog.entry(forBundleID: value.bundleID)
                ?? value.processes.lazy.compactMap { ConversationAppCatalog.entry(forBundleID: $0.bundleID) }.first
            let isSystem = value.bundlePath == nil
                || value.bundlePath?.hasPrefix("/System/") == true
            let kind = entry?.kind ?? (isSystem ? .system : .other)
            return AudioApplication(id: key, name: value.name, bundleIdentifier: value.bundleID, bundlePath: value.bundlePath,
                                    kind: kind, isolation: entry?.isolation ?? (isSystem ? .shared : .exact),
                                    processes: value.processes.sorted { $0.pid < $1.pid })
        }
        .sorted { lhs, rhs in
            let l = (lhs.isUsingInput ? 0 : 2) + (lhs.isUsingOutput ? 0 : 1)
            let r = (rhs.isUsingInput ? 0 : 2) + (rhs.isUsingOutput ? 0 : 1)
            return l != r ? l < r : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Live snapshot from the HAL.
    public static func currentApplications() -> [AudioApplication] {
        group(AudioProcessCatalog.allProcesses())
    }
}

/// Caches bundle identifier + display name per bundle path.
public final class BundleInfoCache: @unchecked Sendable {
    public static let shared = BundleInfoCache()
    private let lock = NSLock()
    private var cache: [String: (id: String?, name: String)] = [:]

    public func info(_ path: String) -> (id: String?, name: String) {
        if let cached = lock.withLock({ cache[path] }) { return cached }
        let bundle = Bundle(path: path)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let value = (bundle?.bundleIdentifier, name)
        lock.withLock { cache[path] = value }
        return value
    }
}
