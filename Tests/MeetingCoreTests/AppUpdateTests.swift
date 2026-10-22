import CryptoKit
import Foundation
import Testing
@testable import MeetingCore

/// Minimal signed app bundle (a re-signed copy of /usr/bin/true) for updater tests.
enum FakeAppBundle {
    static let bundleId = "dev.meetingintelligence.app"

    static func make(in dir: URL, version: String, bundleId: String = bundleId, minimumSystem: String = "26.0",
                     name: String = "Meeting Intelligence.app") async throws -> URL {
        let app = dir.appendingPathComponent(name, isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: macos.appendingPathComponent("MeetingIntelligence"))
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleId, "CFBundleShortVersionString": version, "CFBundleVersion": "1",
            "CFBundleExecutable": "MeetingIntelligence", "CFBundlePackageType": "APPL",
            "LSMinimumSystemVersion": minimumSystem,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                                               arguments: ["--force", "--sign", "-", app.path], timeout: 60)
        #expect(sign.exitCode == 0, "\(sign.stderrText)")
        return app
    }

    static func zip(_ app: URL, to zip: URL) async throws {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                                                 arguments: ["-c", "-k", "--keepParent", app.path, zip.path], timeout: 60)
        #expect(result.exitCode == 0)
    }

    static func version(at app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?[
            "CFBundleShortVersionString"] as? String
    }
}

/// Serves assets from local files.
struct LocalUpdateSource: AppUpdateSource {
    var releaseList: [AppRelease] = []
    var files: [URL: URL] = [:]

    func releases() async throws -> [AppRelease] { releaseList }

    func download(_ asset: AppRelease.Asset, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let file = files[asset.url] else { throw AppUpdateError.network("HTTP 404") }
        try FileManager.default.copyItem(at: file, to: destination)
        progress(asset.size)
    }
}

/// A published update built from a fake bundle: ZIP + signature + release metadata.
struct PublishedUpdate {
    let release: AppRelease
    let source: LocalUpdateSource

    static func make(in dir: URL, bundleVersion: String, releaseVersion: String? = nil, bundleId: String = FakeAppBundle.bundleId,
                     key: Curve25519.Signing.PrivateKey, minimumSystem: String = "26.0") async throws -> PublishedUpdate {
        let version = releaseVersion ?? bundleVersion
        let build = dir.appendingPathComponent("build-\(version)-\(UUID().uuidString)", isDirectory: true)
        let app = try await FakeAppBundle.make(in: build, version: bundleVersion, bundleId: bundleId, minimumSystem: minimumSystem)
        let zip = dir.appendingPathComponent("Meeting-Intelligence-\(version).zip")
        try? FileManager.default.removeItem(at: zip)
        try await FakeAppBundle.zip(app, to: zip)
        let signature = dir.appendingPathComponent("Meeting-Intelligence-\(version).zip.sig")
        try UpdateSignature.sign(version: version, sha256: try ContentHash.sha256(of: zip), privateKey: key)
            .write(to: signature, atomically: true, encoding: .utf8)
        let size = Int64(try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let zipURL = URL(string: "https://example.invalid/\(version)/\(zip.lastPathComponent)")!
        let sigURL = URL(string: "https://example.invalid/\(version)/\(signature.lastPathComponent)")!
        let release = AppRelease(version: AppVersion(version)!, versionString: version, tag: "v\(version)",
                                 title: "Meeting Intelligence \(version)", notes: "## Novedades\n- Cambios",
                                 pageURL: URL(string: "https://example.invalid/releases/v\(version)")!,
                                 publishedAt: nil, isPrerelease: false,
                                 archive: .init(name: zip.lastPathComponent, url: zipURL, size: size),
                                 signature: .init(name: signature.lastPathComponent, url: sigURL, size: 88))
        return PublishedUpdate(release: release,
                               source: LocalUpdateSource(releaseList: [release], files: [zipURL: zip, sigURL: signature]))
    }
}

func temporaryDirectory(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mi-update-tests-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Actualizaciones de la app")
struct AppUpdateTests {
    let key = Curve25519.Signing.PrivateKey()

    private func configuration(current: String = "0.2.0") -> AppUpdateConfiguration {
        AppUpdateConfiguration(repository: "corpjorge/MeetingIntelligence", publicKey: UpdateSignature.publicKey(of: key),
                               bundleIdentifier: FakeAppBundle.bundleId, currentVersion: AppVersion(current)!)
    }

    @Test func versionsOrderLikeReleaseTags() throws {
        let v = { (s: String) in try #require(AppVersion(s)) }
        #expect(try v("v0.2.0") > v("0.1.0"))
        #expect(try v("0.10.0") > v("0.9.9"))
        #expect(try v("1.0") == v("1.0.0"))
        #expect(try v("0.2.0-beta.2") < v("0.2.0"))
        #expect(try v("0.2.0-beta.10") > v("0.2.0-beta.2"))
        #expect(try v("0.1.0-dev") < v("0.1.0"))
        #expect(try v("v1.2.3").description == "1.2.3")
        for invalid in ["", "abc", "1..2", "1.2.3-", "-1.0", "1.2.3.4.5", "nightly"] {
            #expect(AppVersion(invalid) == nil, "\(invalid)")
        }
    }

    @Test func picksNewestSignedReleaseIncludingPrereleases() throws {
        func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, signed: Bool = true) -> String {
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let sig = signed ? #", {"name": "Meeting-Intelligence-\#(version).zip.sig", "browser_download_url": "https://github.com/x/sig", "size": 88}"# : ""
            return """
            {"tag_name": "\(tag)", "name": "MI \(version)", "body": "## Novedades\\r\\n- **Uno**\\r\\n* Dos\\r\\n\\r\\n## Instalación\\r\\n| a | b |\\r\\nTexto",
             "html_url": "https://github.com/x/releases/\(tag)", "draft": \(draft), "prerelease": \(prerelease),
             "published_at": "2026-10-22T14:46:20Z",
             "assets": [{"name": "Meeting-Intelligence-\(version).dmg", "browser_download_url": "https://github.com/x/dmg", "size": 10},
                        {"name": "Meeting-Intelligence-\(version).zip", "browser_download_url": "https://github.com/x/zip", "size": 20}\(sig)]}
            """
        }
        let json = "[" + [release("v0.4.0", draft: true), release("v0.3.0", signed: false),
                          release("v0.2.1", prerelease: true), release("nightly"), release("v0.1.0", prerelease: true)]
            .joined(separator: ",") + "]"
        let releases = try GitHubReleases.releases(from: Data(json.utf8))
        #expect(releases.map(\.versionString) == ["0.2.1", "0.1.0"]) // draft, unsigned and non-version tags skipped
        let newest = try #require(GitHubReleases.newest(releases, newerThan: AppVersion("0.1.0")!))
        #expect(newest.versionString == "0.2.1" && newest.isPrerelease)
        #expect(newest.archive.size == 20 && newest.signature.name == "Meeting-Intelligence-0.2.1.zip.sig")
        #expect(newest.publishedAt != nil)
        #expect(newest.highlights == "• **Uno**\n• Dos")
        #expect(GitHubReleases.newest(releases, newerThan: AppVersion("0.2.1")!) == nil)
    }

    @Test func releaseNotesJoinWrappedLinesOfTheNoveltiesSection() throws {
        let notes = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/releases/0.2.0.md"), encoding: .utf8)
        let highlights = ReleaseNotes.highlights(notes)
        let lines = highlights.split(separator: "\n")
        #expect(lines.count == 5)
        #expect(lines.allSatisfy { $0.hasPrefix("• ") })
        #expect(lines[0].contains("busca versiones nuevas en GitHub y muestra un aviso con **Ver novedades**"))
        #expect(!highlights.contains("Meeting-Intelligence-0.2.0.dmg") && !highlights.contains("|"))
        #expect(ReleaseNotes.highlights("Intro\ncontinúa.\n\n- a\n  b\nTexto") == "Intro continúa.\n\n• a b Texto")
    }

    @Test func signatureBindsArchiveVersionAndKey() throws {
        let sha = String(repeating: "ab", count: 32)
        let signature = try UpdateSignature.sign(version: "0.2.0", sha256: sha, privateKey: key)
        let publicKey = UpdateSignature.publicKey(of: key)
        #expect(UpdateSignature.isValid(signature: signature + "\n", version: "0.2.0", sha256: sha.uppercased(), publicKey: publicKey))
        #expect(!UpdateSignature.isValid(signature: signature, version: "0.2.1", sha256: sha, publicKey: publicKey))
        #expect(!UpdateSignature.isValid(signature: signature, version: "0.2.0", sha256: String(repeating: "cd", count: 32),
                                         publicKey: publicKey))
        let other = UpdateSignature.publicKey(of: Curve25519.Signing.PrivateKey())
        #expect(!UpdateSignature.isValid(signature: signature, version: "0.2.0", sha256: sha, publicKey: other))
        #expect(!UpdateSignature.isValid(signature: "basura", version: "0.2.0", sha256: sha, publicKey: publicKey))
    }

    @Test func preparesOnlyVerifiedUpdates() async throws {
        let dir = try temporaryDirectory("prepare")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        let installer = AppUpdateInstaller(configuration: configuration(), workDirectory: work)

        let good = try await PublishedUpdate.make(in: dir, bundleVersion: "0.3.0", key: key)
        let prepared = try await installer.prepare(good.release, source: good.source) { _, _ in }
        #expect(FakeAppBundle.version(at: prepared.appURL) == "0.3.0")
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("0.3.0/update.zip").path))

        // Signed with another key (e.g. a compromised GitHub account without the private key).
        let forged = try await PublishedUpdate.make(in: dir, bundleVersion: "0.4.0", key: Curve25519.Signing.PrivateKey())
        await #expect(throws: AppUpdateError.invalidSignature) {
            try await installer.prepare(forged.release, source: forged.source) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("0.4.0").path))

        // Properly signed, but the bundle inside is not the advertised version or app.
        let mislabeled = try await PublishedUpdate.make(in: dir, bundleVersion: "0.1.0", releaseVersion: "0.5.0", key: key)
        await #expect(throws: AppUpdateError.invalidArchive("la versión no coincide con la publicada")) {
            try await installer.prepare(mislabeled.release, source: mislabeled.source) { _, _ in }
        }
        let otherApp = try await PublishedUpdate.make(in: dir, bundleVersion: "0.6.0", bundleId: "com.example.other", key: key)
        await #expect(throws: AppUpdateError.invalidArchive("identificador de app distinto")) {
            try await installer.prepare(otherApp.release, source: otherApp.source) { _, _ in }
        }
        let future = try await PublishedUpdate.make(in: dir, bundleVersion: "0.7.0", key: key, minimumSystem: "99.0")
        await #expect(throws: AppUpdateError.incompatibleSystem("99.0")) {
            try await installer.prepare(future.release, source: future.source) { _, _ in }
        }
        var truncated = good.release
        truncated.archive.size += 1
        await #expect(throws: AppUpdateError.invalidArchive("el tamaño no coincide con el publicado")) {
            try await installer.prepare(truncated, source: good.source) { _, _ in }
        }
    }

    @Test func installSwapsBundleAndLaunchCleansUp() async throws {
        let dir = try temporaryDirectory("install")
        defer { try? FileManager.default.removeItem(at: dir) }
        let applications = dir.appendingPathComponent("Applications", isDirectory: true)
        let installed = try await FakeAppBundle.make(in: applications, version: "0.2.0")
        let work = dir.appendingPathComponent("work")
        let installer = AppUpdateInstaller(configuration: configuration(), workDirectory: work)
        let update = try await PublishedUpdate.make(in: dir, bundleVersion: "0.3.0", key: key)
        let prepared = try await installer.prepare(update.release, source: update.source) { _, _ in }

        try installer.install(prepared, replacing: installed)
        #expect(FakeAppBundle.version(at: installed) == "0.3.0")
        #expect(CodeSignature.isValid(installed))
        let previous = AppUpdateInstaller.leftoverURL(for: installed)
        #expect(previous.lastPathComponent == ".Meeting Intelligence.app.mi-update")
        #expect(FakeAppBundle.version(at: previous) == "0.2.0")

        AppUpdateInstaller.cleanUp(bundleURL: installed, workDirectory: work)
        #expect(!FileManager.default.fileExists(atPath: previous.path))
        #expect(!FileManager.default.fileExists(atPath: work.path))
        #expect(FakeAppBundle.version(at: installed) == "0.3.0")
    }

    @Test func refusesLocationsThatCannotBeReplaced() async throws {
        let dir = try temporaryDirectory("location")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("locked").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let writable = try await FakeAppBundle.make(in: dir.appendingPathComponent("ok"), version: "0.2.0")
        #expect(AppUpdateInstaller.installProblem(bundleURL: writable) == nil)
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/ABC/d/Meeting Intelligence.app")
        #expect(AppUpdateInstaller.installProblem(bundleURL: translocated)?.contains("ubicación temporal") == true)
        #expect(AppUpdateInstaller.installProblem(bundleURL: URL(fileURLWithPath: "/usr/local/bin/mi")) != nil)
        let locked = try await FakeAppBundle.make(in: dir.appendingPathComponent("locked"), version: "0.2.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.deletingLastPathComponent().path)
        #expect(AppUpdateInstaller.installProblem(bundleURL: locked)?.contains("permiso") == true)

        let installer = AppUpdateInstaller(configuration: configuration(), workDirectory: dir.appendingPathComponent("work"))
        let update = try await PublishedUpdate.make(in: dir, bundleVersion: "0.3.0", key: key)
        let prepared = try await installer.prepare(update.release, source: update.source) { _, _ in }
        #expect(throws: AppUpdateError.self) { try installer.install(prepared, replacing: locked) }
        #expect(FakeAppBundle.version(at: locked) == "0.2.0")
    }

    @Test func codeSignatureDetectsTamperingAndAdHoc() async throws {
        let dir = try temporaryDirectory("codesign")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try await FakeAppBundle.make(in: dir, version: "0.2.0")
        #expect(CodeSignature.isValid(app))
        #expect(CodeSignature.isAdHoc(app))
        try Data("x".utf8).write(to: app.appendingPathComponent("Contents/MacOS/extra"))
        #expect(!CodeSignature.isValid(app))
    }
}
