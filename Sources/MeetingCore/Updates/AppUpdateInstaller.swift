public import Foundation
import Security

/// A downloaded release whose signature, bundle identifier, version and code signature were verified.
public struct PreparedAppUpdate: Sendable, Equatable {
    public var release: AppRelease
    public var appURL: URL
}

/// Downloads, verifies and installs a new version of the running app (TD-29).
///
/// Nothing is replaced until the archive's Ed25519 signature matches the embedded public key and the
/// extracted bundle has the expected identifier, version and a valid code signature. The swap is a single
/// atomic `renamex_np(RENAME_SWAP)` next to the installed app; the previous version stays beside it,
/// hidden, until the new one launches and cleans it up.
public struct AppUpdateInstaller: Sendable {
    public let configuration: AppUpdateConfiguration
    public let workDirectory: URL

    public init(configuration: AppUpdateConfiguration, workDirectory: URL? = nil) {
        self.configuration = configuration
        self.workDirectory = workDirectory ?? Self.defaultWorkDirectory(bundleIdentifier: configuration.bundleIdentifier)
    }

    public static func defaultWorkDirectory(bundleIdentifier: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    // MARK: Download and verify

    /// `progress(done, total)` reports archive bytes.
    public func prepare(_ release: AppRelease, source: any AppUpdateSource,
                        progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> PreparedAppUpdate {
        let fm = FileManager.default
        let dir = workDirectory.appendingPathComponent(release.versionString, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let archive = dir.appendingPathComponent("update.zip")
            let signatureFile = dir.appendingPathComponent("update.zip.sig")
            try await source.download(release.signature, to: signatureFile) { _ in }
            try await source.download(release.archive, to: archive) { progress($0, release.archive.size) }
            try Task.checkCancellation()

            let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            if release.archive.size > 0, size != release.archive.size {
                throw AppUpdateError.invalidArchive("el tamaño no coincide con el publicado")
            }
            let signature = (try? String(contentsOf: signatureFile, encoding: .utf8)) ?? ""
            guard UpdateSignature.isValid(signature: signature, version: release.versionString,
                                          sha256: try ContentHash.sha256(of: archive),
                                          publicKey: configuration.publicKey) else {
                throw AppUpdateError.invalidSignature
            }

            let extracted = dir.appendingPathComponent("extracted", isDirectory: true)
            let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                                                     arguments: ["-x", "-k", archive.path, extracted.path], timeout: 300)
            guard result.exitCode == 0 else { throw AppUpdateError.invalidArchive("no se pudo descomprimir") }
            try? fm.removeItem(at: archive)
            let apps = (try fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil))
                .filter { $0.pathExtension == "app" }
            guard apps.count == 1, let app = apps.first else {
                throw AppUpdateError.invalidArchive("se esperaba una sola app en el ZIP")
            }
            try validate(app, expectedVersion: release.versionString)
            return PreparedAppUpdate(release: release, appURL: app)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// Bundle identifier, version, minimum macOS and code signature of an extracted app.
    public func validate(_ app: URL, expectedVersion: String) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        else { throw AppUpdateError.invalidArchive("falta Info.plist") }
        guard info["CFBundleIdentifier"] as? String == configuration.bundleIdentifier else {
            throw AppUpdateError.invalidArchive("identificador de app distinto")
        }
        guard info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw AppUpdateError.invalidArchive("la versión no coincide con la publicada")
        }
        if let minimum = info["LSMinimumSystemVersion"] as? String, let required = AppVersion(minimum) {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            if AppVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)").map({ $0 < required }) ?? false {
                throw AppUpdateError.incompatibleSystem(minimum)
            }
        }
        guard CodeSignature.isValid(app) else { throw AppUpdateError.invalidArchive("la firma de código no es válida") }
    }

    // MARK: Install

    /// Why the app at `bundleURL` cannot be replaced in place, or nil.
    public static func installProblem(bundleURL: URL) -> String? {
        let path = bundleURL.path
        guard bundleURL.pathExtension == "app" else {
            return "Esta copia no es una app empaquetada; descarga la versión nueva desde GitHub."
        }
        if path.contains("/AppTranslocation/") {
            return "macOS abrió la app desde una ubicación temporal. Muévela a la carpeta Aplicaciones, ábrela desde ahí y vuelve a intentarlo."
        }
        if (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            return "La app se está ejecutando desde la imagen de disco. Arrástrala a Aplicaciones, ábrela desde ahí y vuelve a intentarlo."
        }
        let parent = bundleURL.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: parent) || !FileManager.default.isWritableFile(atPath: path) {
            return "No tienes permiso para modificar «\(parent)». Descarga la versión nueva desde GitHub e instálala a mano."
        }
        return nil
    }

    /// Hidden sibling used for the swap; after a successful update it holds the previous version.
    public static func leftoverURL(for bundleURL: URL) -> URL {
        bundleURL.deletingLastPathComponent().appendingPathComponent(".\(bundleURL.lastPathComponent).mi-update",
                                                                      isDirectory: true)
    }

    /// Replaces the app at `bundleURL` with the prepared one. The running process keeps working
    /// (its files stay open in the previous version) until it quits.
    public func install(_ prepared: PreparedAppUpdate, replacing bundleURL: URL) throws {
        if let problem = Self.installProblem(bundleURL: bundleURL) { throw AppUpdateError.cannotReplace(problem) }
        let fm = FileManager.default
        let staging = Self.leftoverURL(for: bundleURL)
        try? fm.removeItem(at: staging)
        do {
            try fm.copyItem(at: prepared.appURL, to: staging)
            try validate(staging, expectedVersion: prepared.release.versionString)
        } catch {
            try? fm.removeItem(at: staging)
            throw error is AppUpdateError ? error : AppUpdateError.cannotReplace(
                "No se pudo copiar la versión nueva junto a la app: \(error.localizedDescription)")
        }
        try Self.swap(staging, bundleURL)
    }

    /// Atomic exchange of two directories on the same volume.
    static func swap(_ a: URL, _ b: URL) throws {
        if renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 { return }
        let reason = String(cString: strerror(errno))
        // Volumes without RENAME_SWAP: two renames, undone if the second fails.
        let aside = b.deletingLastPathComponent().appendingPathComponent(".\(b.lastPathComponent).mi-swap")
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: aside)
            try fm.moveItem(at: b, to: aside)
            do {
                try fm.moveItem(at: a, to: b)
            } catch {
                try? fm.moveItem(at: aside, to: b)
                throw error
            }
            try fm.moveItem(at: aside, to: a)
        } catch {
            throw AppUpdateError.cannotReplace("No se pudo reemplazar la app (\(reason)): \(error.localizedDescription)")
        }
    }

    /// Removes the previous version and any downloaded files. Called at launch.
    public static func cleanUp(bundleURL: URL, workDirectory: URL) {
        let fm = FileManager.default
        for url in [leftoverURL(for: bundleURL), workDirectory] where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
    }

    /// Opens the app at `bundleURL` once process `pid` has exited (gives up after 2 minutes). The helper runs
    /// in its own session with no inherited file descriptors, so it survives this app quitting. A separate
    /// library (`MEETING_INTELLIGENCE_HOME`) is kept across the relaunch.
    public static func relaunch(bundleURL: URL, afterExitOf pid: Int32,
                                environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let script = """
        pid=$1; shift; i=0
        while /bin/kill -0 "$pid" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 600 ] && exit 1; /bin/sleep 0.2; done
        exec /usr/bin/open "$@"
        """
        var openArguments: [String] = []
        if let home = environment[AppPaths.environmentOverrideKey], !home.isEmpty {
            openArguments += ["--env", "\(AppPaths.environmentOverrideKey)=\(home)"]
        }
        let arguments = ["/bin/sh", "-c", script, "mi-relaunch", String(pid)] + openArguments + [bundleURL.path]
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, "/bin/sh", &actions, &attributes, argv, environ)
        guard status == 0 else {
            throw AppUpdateError.cannotReplace("No se pudo programar el reinicio: \(String(cString: strerror(status)))")
        }
    }
}

/// Code-signature checks on bundles (Security framework; no `codesign` process).
public enum CodeSignature {
    /// Strict validation of the bundle and its nested code (the seal covers every file).
    public static func isValid(_ bundle: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    /// Ad-hoc signatures have no stable identity, so macOS asks for privacy permissions again after an update.
    public static func isAdHoc(_ bundle: URL) -> Bool {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32 else { return true }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }
}
