import AppKit
import Foundation
import MeetingCore
import OSLog

/// In-app updates (TD-29): finds newer releases on GitHub, downloads and verifies them, and installs only
/// when the user asks — never while recording or processing. The download must carry a valid Ed25519
/// signature for the key embedded in this build.
@Observable
final class AppUpdateController {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double?)
        case ready
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Newest release offered (nil when none is known).
    private(set) var release: AppRelease?
    /// Version installed before this launch and whether it is the one running now.
    private(set) var completedUpdate: (version: String, succeeded: Bool)?
    var isSheetPresented = false
    private var bannerDismissed = false

    let configuration: AppUpdateConfiguration?
    let currentVersion: String
    let bundleURL: URL
    /// Ad-hoc signed builds lose macOS privacy grants when replaced (no stable signing identity).
    let permissionsResetOnUpdate: Bool
    private let source: (any AppUpdateSource)?
    private let installer: AppUpdateInstaller?
    private let settings: AppSettings
    private let busyReason: () -> String?
    private let relaunch: (URL, Int32) throws -> Void
    private let quit: () -> Void
    private var prepared: PreparedAppUpdate?
    private var downloadTask: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    /// End-to-end test hook (TD-29): with a loopback `MI_UPDATE_API` and `MI_UPDATE_E2E=1`, the download and
    /// the install are accepted as the user would. Never active against the real GitHub API.
    private let acceptsForEndToEndTest: Bool
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "app-update")

    init(configuration: AppUpdateConfiguration?, settings: AppSettings, bundleURL: URL = Bundle.main.bundleURL,
         source: (any AppUpdateSource)? = nil, workDirectory: URL? = nil,
         busyReason: @escaping () -> String? = { nil },
         relaunch: @escaping (URL, Int32) throws -> Void = { try AppUpdateInstaller.relaunch(bundleURL: $0, afterExitOf: $1) },
         quit: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.configuration = configuration
        self.settings = settings
        self.bundleURL = bundleURL
        self.busyReason = busyReason
        self.relaunch = relaunch
        self.quit = quit
        currentVersion = configuration?.currentVersion.description ?? AppIdentity.version
        acceptsForEndToEndTest = configuration?.usesLoopbackAPI == true
            && ProcessInfo.processInfo.environment["MI_UPDATE_E2E"] == "1"
        permissionsResetOnUpdate = CodeSignature.isAdHoc(bundleURL)
        if let configuration {
            self.source = source ?? GitHubReleaseSource(repository: configuration.repository, apiBase: configuration.apiBase)
            installer = AppUpdateInstaller(configuration: configuration, workDirectory: workDirectory)
        } else {
            self.source = nil
            installer = nil
        }
    }

    var isConfigured: Bool { configuration != nil }
    var lastChecked: Date? { settings.lastAppUpdateCheck }

    /// Why the update cannot be installed right now (busy, or the app cannot be replaced where it is).
    var installBlockedReason: String? {
        if let problem = installLocationProblem { return problem }
        return busyReason().map { AppUpdateError.busy($0).localizedDescription }
    }

    var installLocationProblem: String? { AppUpdateInstaller.installProblem(bundleURL: bundleURL) }

    /// Release for the floating banner: automatic findings that were not skipped or dismissed.
    var bannerRelease: AppRelease? {
        guard let release, !bannerDismissed, release.versionString != settings.skippedAppVersion else { return nil }
        switch phase {
        case .available, .downloading, .ready, .failed: return release
        case .idle, .checking, .upToDate, .installing: return nil
        }
    }

    // MARK: Launch and schedule

    /// Reports the outcome of an update installed before this launch and removes the previous version.
    func handleLaunch() {
        if let pending = settings.pendingAppUpdateVersion {
            completedUpdate = (pending, pending == currentVersion)
            settings.pendingAppUpdateVersion = nil
            logger.notice("Update to \(pending, privacy: .public): \(pending == self.currentVersion ? "installed" : "not applied", privacy: .public)")
        }
        if let installer { AppUpdateInstaller.cleanUp(bundleURL: bundleURL, workDirectory: installer.workDirectory) }
    }

    /// Checks shortly after launch (if the last check is over an hour old) and then every 24 hours.
    func startAutomaticChecks() {
        guard isConfigured, scheduleTask == nil else { return }
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            var interval: TimeInterval = 3_600
            while !Task.isCancelled {
                guard let self else { return }
                if self.settings.checkForAppUpdates,
                   Date().timeIntervalSince(self.settings.lastAppUpdateCheck ?? .distantPast) >= interval {
                    await self.check(userInitiated: false)
                }
                interval = 86_400
                try? await Task.sleep(for: .seconds(3_600))
            }
        }
    }

    // MARK: Actions

    /// A manual check opens the sheet (also for "up to date" and errors) and offers skipped versions.
    func check(userInitiated: Bool) async {
        if userInitiated { isSheetPresented = true }
        switch phase {
        case .checking, .downloading, .ready, .installing: return
        default: break
        }
        guard let source, let configuration else {
            if userInitiated { phase = .failed(AppUpdateError.notConfigured.localizedDescription) }
            return
        }
        let previous = phase
        phase = .checking
        do {
            let releases = try await source.releases()
            settings.lastAppUpdateCheck = Date()
            if let newest = GitHubReleases.newest(releases, newerThan: configuration.currentVersion) {
                if newest != release { bannerDismissed = false }
                release = newest
                phase = .available
                logger.notice("Update available: \(newest.versionString, privacy: .public)")
                if acceptsForEndToEndTest { download() }
            } else {
                release = nil
                phase = .upToDate
            }
        } catch {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            // A failed background check keeps what was known (e.g. an update on offer).
            phase = userInitiated ? .failed(error.localizedDescription) : previous
        }
    }

    /// Downloads and verifies; refused when this copy cannot be replaced (the sheet offers GitHub instead).
    func download() {
        guard let release, let source, let installer, installLocationProblem == nil else { return }
        switch phase {
        case .available, .failed: break
        default: return
        }
        phase = .downloading(0)
        downloadTask = Task { [weak self] in
            do {
                let prepared = try await installer.prepare(release, source: source) { done, total in
                    Task { @MainActor in self?.downloadProgress(done: done, total: total) }
                }
                self?.prepared = prepared
                self?.phase = .ready
                self?.logger.notice("Update \(release.versionString, privacy: .public) downloaded and verified")
                if self?.acceptsForEndToEndTest == true { self?.installAndRelaunch() }
            } catch {
                if Task.isCancelled {
                    self?.phase = .available
                } else {
                    self?.logger.error("Update download failed: \(error.localizedDescription, privacy: .public)")
                    self?.phase = .failed(error.localizedDescription)
                }
            }
            self?.downloadTask = nil
        }
    }

    private func downloadProgress(done: Int64, total: Int64) {
        guard case .downloading = phase else { return }
        phase = .downloading(total > 0 ? min(1, Double(done) / Double(total)) : nil)
    }

    func cancelDownload() { downloadTask?.cancel() }

    /// Replaces the app, schedules the relaunch and quits.
    func installAndRelaunch() {
        guard phase == .ready, let prepared, let installer, installBlockedReason == nil else { return }
        phase = .installing
        do {
            try installer.install(prepared, replacing: bundleURL)
        } catch {
            phase = .failed(error.localizedDescription)
            logger.error("Install failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        settings.pendingAppUpdateVersion = prepared.release.versionString
        do {
            try relaunch(bundleURL, getpid())
        } catch {
            phase = .failed("La versión \(prepared.release.versionString) ya está instalada, pero no se pudo reiniciar sola. "
                            + "Cierra la app y vuelve a abrirla.")
            return
        }
        logger.notice("Installed \(prepared.release.versionString, privacy: .public); relaunching")
        quit()
    }

    func skipRelease() {
        settings.skippedAppVersion = release?.versionString
        isSheetPresented = false
    }

    func unskip() { settings.skippedAppVersion = nil; bannerDismissed = false }

    func dismissBanner() { bannerDismissed = true }

    func dismissCompletedUpdate() { completedUpdate = nil }

    /// Fixed state for UI snapshots (`SnapshotDriver`); no network.
    func showForSnapshot(_ release: AppRelease?, phase: Phase) {
        self.release = release
        self.phase = phase
        bannerDismissed = false
    }
}
