import CryptoKit
import Foundation
@testable import MeetingCore
import Testing
@testable import MeetingIntelligenceApp

/// Signed fake bundle (re-signed /usr/bin/true) and a local "GitHub" serving one signed update.
fileprivate enum UpdateFixture {
    static func app(in dir: URL, version: String) async throws -> URL {
        let app = dir.appendingPathComponent("Meeting Intelligence.app", isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: macos.appendingPathComponent("MeetingIntelligence"))
        let info: [String: Any] = ["CFBundleIdentifier": "dev.meetingintelligence.app", "CFBundleShortVersionString": version,
                                   "CFBundleExecutable": "MeetingIntelligence", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                                        arguments: ["--force", "--sign", "-", app.path], timeout: 60)
        return app
    }

    static func version(at app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?[
            "CFBundleShortVersionString"] as? String
    }

    /// Simulates losing the connection between checks.
    nonisolated final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isOn: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    struct Source: AppUpdateSource {
        var list: [AppRelease]
        var files: [URL: URL]
        let offline = Switch()
        func releases() async throws -> [AppRelease] {
            if offline.isOn { throw AppUpdateError.network("sin conexión") }
            return list
        }
        func download(_ asset: AppRelease.Asset, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
            try FileManager.default.copyItem(at: try #require(files[asset.url]), to: destination)
            progress(asset.size)
        }
    }

    static func published(in dir: URL, version: String, key: Curve25519.Signing.PrivateKey) async throws -> Source {
        let app = try await app(in: dir.appendingPathComponent("build", isDirectory: true), version: version)
        let zip = dir.appendingPathComponent("Meeting-Intelligence-\(version).zip")
        _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                                        arguments: ["-c", "-k", "--keepParent", app.path, zip.path], timeout: 60)
        let sig = dir.appendingPathComponent(zip.lastPathComponent + ".sig")
        try UpdateSignature.sign(version: version, sha256: try ContentHash.sha256(of: zip), privateKey: key)
            .write(to: sig, atomically: true, encoding: .utf8)
        let zipURL = URL(string: "https://example.invalid/\(zip.lastPathComponent)")!
        let sigURL = URL(string: "https://example.invalid/\(sig.lastPathComponent)")!
        let size = Int64(try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let release = AppRelease(version: AppVersion(version)!, versionString: version, tag: "v\(version)",
                                 title: "MI \(version)", notes: "## Novedades\n- Algo nuevo",
                                 pageURL: URL(string: "https://example.invalid/r")!, publishedAt: nil, isPrerelease: true,
                                 archive: .init(name: zip.lastPathComponent, url: zipURL, size: size),
                                 signature: .init(name: sig.lastPathComponent, url: sigURL, size: 88))
        return Source(list: [release], files: [zipURL: zip, sigURL: sig])
    }
}

@Suite("App: actualizaciones")
struct AppUpdateControllerTests {
    let key = Curve25519.Signing.PrivateKey()

    private func setup(_ label: String, installed: String = "0.2.0", offered: String = "0.3.0", failing: Bool = false,
                       folder: String = "Applications", busy: @escaping () -> String? = { nil })
        async throws -> (AppUpdateController, AppSettings, URL, IsolatedDefaults, Box) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mi-app-update-\(label)-\(UUID().uuidString)")
        let bundle = try await UpdateFixture.app(in: dir.appendingPathComponent(folder), version: installed)
        let source = try await UpdateFixture.published(in: dir, version: offered, key: key)
        source.offline.isOn = failing
        let suite = try IsolatedDefaults()
        let settings = AppSettings(defaults: suite.defaults)
        let configuration = AppUpdateConfiguration(repository: "o/r", publicKey: UpdateSignature.publicKey(of: key),
                                                   bundleIdentifier: "dev.meetingintelligence.app",
                                                   currentVersion: AppVersion(installed)!)
        let box = Box(offline: source.offline)
        let controller = AppUpdateController(configuration: configuration, settings: settings, bundleURL: bundle,
                                             source: source, workDirectory: dir.appendingPathComponent("work"),
                                             busyReason: busy,
                                             relaunch: { url, pid in box.relaunched = (url, pid) },
                                             quit: { box.quitCount += 1 })
        return (controller, settings, dir, suite, box)
    }

    final class Box {
        var relaunched: (URL, Int32)?
        var quitCount = 0
        fileprivate let offline: UpdateFixture.Switch
        fileprivate init(offline: UpdateFixture.Switch) { self.offline = offline }
    }

    @Test func failedBackgroundCheckKeepsTheKnownUpdate() async throws {
        let (updates, settings, dir, suite, box) = try await setup("keep")
        defer { suite.remove(); try? FileManager.default.removeItem(at: dir) }
        await updates.check(userInitiated: false)
        box.offline.isOn = true
        await updates.check(userInitiated: false)
        #expect(updates.phase == .available)
        #expect(updates.bannerRelease?.versionString == "0.3.0")
        #expect(settings.lastAppUpdateCheck != nil)
    }

    @Test func neverDownloadsWhereTheAppCannotBeReplaced() async throws {
        let (updates, _, dir, suite, _) = try await setup("translocated", folder: "AppTranslocation/ABC/d")
        defer { suite.remove(); try? FileManager.default.removeItem(at: dir) }
        await updates.check(userInitiated: false)
        #expect(updates.installLocationProblem?.contains("ubicación temporal") == true)
        updates.download()
        #expect(updates.phase == .available) // the sheet offers the GitHub page instead
    }

    @Test func automaticCheckShowsBannerAndSkippingHidesIt() async throws {
        let (updates, settings, dir, suite, _) = try await setup("banner")
        defer { suite.remove(); try? FileManager.default.removeItem(at: dir) }

        await updates.check(userInitiated: false)
        #expect(updates.phase == .available)
        #expect(updates.bannerRelease?.versionString == "0.3.0")
        #expect(!updates.isSheetPresented) // automatic findings never open a window
        #expect(settings.lastAppUpdateCheck != nil)

        updates.dismissBanner()
        #expect(updates.bannerRelease == nil)

        updates.skipRelease()
        #expect(settings.skippedAppVersion == "0.3.0")
        await updates.check(userInitiated: false)
        #expect(updates.bannerRelease == nil)

        // A manual check still offers it, in the sheet.
        await updates.check(userInitiated: true)
        #expect(updates.isSheetPresented && updates.release?.versionString == "0.3.0")
        updates.unskip()
        #expect(settings.skippedAppVersion == nil)
    }

    @Test func upToDateAndFailuresAreReportedOnlyWhenAsked() async throws {
        let (current, _, dir1, suite1, _) = try await setup("uptodate", installed: "0.3.0", offered: "0.3.0")
        defer { suite1.remove(); try? FileManager.default.removeItem(at: dir1) }
        await current.check(userInitiated: true)
        #expect(current.phase == .upToDate && current.release == nil)

        let (offline, _, dir2, suite2, _) = try await setup("offline", failing: true)
        defer { suite2.remove(); try? FileManager.default.removeItem(at: dir2) }
        await offline.check(userInitiated: false)
        #expect(offline.phase == .idle) // silent in the background
        await offline.check(userInitiated: true)
        guard case .failed(let message) = offline.phase else { Issue.record("se esperaba un error"); return }
        #expect(message.contains("sin conexión"))
    }

    @Test func downloadVerifyInstallAndRelaunch() async throws {
        var busy: String? = "se graba una reunión"
        let (updates, settings, dir, suite, box) = try await setup("install", busy: { busy })
        defer { suite.remove(); try? FileManager.default.removeItem(at: dir) }

        await updates.check(userInitiated: false)
        updates.download()
        try await waitUntil { updates.phase == .ready }

        // Never while recording or processing.
        #expect(updates.installBlockedReason?.contains("se graba") == true)
        updates.installAndRelaunch()
        #expect(updates.phase == .ready && box.quitCount == 0)
        #expect(UpdateFixture.version(at: updates.bundleURL) == "0.2.0")

        busy = nil
        updates.isSheetPresented = true
        updates.installAndRelaunch()
        #expect(UpdateFixture.version(at: updates.bundleURL) == "0.3.0")
        // AppKit ignores `terminate` while a sheet is attached, so the update sheet closes before quitting.
        #expect(!updates.isSheetPresented)
        #expect(box.relaunched?.0 == updates.bundleURL && box.relaunched?.1 == getpid())
        #expect(box.quitCount == 1)
        #expect(settings.pendingAppUpdateVersion == "0.3.0")
    }

    @Test func nextLaunchReportsTheUpdateAndRemovesThePreviousVersion() async throws {
        let (updates, settings, dir, suite, _) = try await setup("relaunch", installed: "0.3.0", offered: "0.3.0")
        defer { suite.remove(); try? FileManager.default.removeItem(at: dir) }
        let leftover = AppUpdateInstaller.leftoverURL(for: updates.bundleURL)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        settings.pendingAppUpdateVersion = "0.3.0"

        updates.handleLaunch()
        #expect(updates.completedUpdate?.version == "0.3.0" && updates.completedUpdate?.succeeded == true)
        #expect(settings.pendingAppUpdateVersion == nil)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))

        settings.pendingAppUpdateVersion = "0.4.0" // the swap did not take effect
        updates.handleLaunch()
        #expect(updates.completedUpdate?.succeeded == false)
    }

    @Test func freshInstallChecksAutomaticallyByDefault() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let settings = AppSettings(defaults: suite.defaults)
        #expect(settings.checkForAppUpdates)
        #expect(settings.skippedAppVersion == nil && settings.pendingAppUpdateVersion == nil)
        let unconfigured = AppUpdateController(configuration: nil, settings: settings)
        #expect(!unconfigured.isConfigured)
    }
}
