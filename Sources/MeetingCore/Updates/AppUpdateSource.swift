public import Foundation

public enum AppUpdateError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case network(String)
    case invalidSignature
    case invalidArchive(String)
    case incompatibleSystem(String)
    case cannotReplace(String)
    case busy(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Esta compilación no tiene configuradas las actualizaciones."
        case .network(let detail): "No se pudo consultar GitHub: \(detail)"
        case .invalidSignature: "La firma de la descarga no es válida. No se instaló nada."
        case .invalidArchive(let detail): "La descarga no es una versión válida de la app: \(detail). No se instaló nada."
        case .incompatibleSystem(let minimum): "Esta versión requiere macOS \(minimum) o posterior."
        case .cannotReplace(let detail): detail
        case .busy(let what): "No se puede instalar mientras \(what)."
        }
    }
}

/// Where updates come from and how they are authenticated. Read from the app's Info.plist
/// (`MIUpdateRepository`, `MIUpdatePublicKey`, written by `scripts/build-app.sh` from `config/app.env`).
public struct AppUpdateConfiguration: Sendable, Equatable {
    public var repository: String
    public var publicKey: String
    public var bundleIdentifier: String
    public var currentVersion: AppVersion
    /// GitHub API root. `MI_UPDATE_API` may point it to a loopback server for end-to-end tests;
    /// archives must still carry a valid signature for the embedded key.
    public var apiBase: URL

    public static let defaultAPIBase = URL(string: "https://api.github.com")!

    public init(repository: String, publicKey: String, bundleIdentifier: String, currentVersion: AppVersion,
                apiBase: URL = defaultAPIBase) {
        self.repository = repository
        self.publicKey = publicKey
        self.bundleIdentifier = bundleIdentifier
        self.currentVersion = currentVersion
        self.apiBase = apiBase
    }

    public var usesLoopbackAPI: Bool { Self.isLoopback(apiBase) }

    static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
    }

    /// nil when this build cannot update itself (no key, no repository, or not a bundled app).
    public static func fromMainBundle(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> AppUpdateConfiguration? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let repository = info["MIUpdateRepository"] as? String, repository.split(separator: "/").count == 2,
              let key = info["MIUpdatePublicKey"] as? String, Data(base64Encoded: key)?.count == 32,
              let bundleId = Bundle.main.bundleIdentifier,
              let version = AppVersion(AppIdentity.version) else { return nil }
        var apiBase = defaultAPIBase
        if let override = environment["MI_UPDATE_API"].flatMap(URL.init(string:)), isLoopback(override) {
            apiBase = override
        }
        return AppUpdateConfiguration(repository: repository, publicKey: key, bundleIdentifier: bundleId,
                                      currentVersion: version, apiBase: apiBase)
    }
}

public protocol AppUpdateSource: Sendable {
    func releases() async throws -> [AppRelease]
    func download(_ asset: AppRelease.Asset, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// Public GitHub REST API, no account. Called on launch and once a day when automatic checks are on,
/// or when the user asks; it sends nothing but the repository name (and the usual HTTP headers).
public struct GitHubReleaseSource: AppUpdateSource {
    let repository: String
    let apiBase: URL

    public init(repository: String, apiBase: URL = AppUpdateConfiguration.defaultAPIBase) {
        self.repository = repository
        self.apiBase = apiBase
    }

    public func releases() async throws -> [AppRelease] {
        guard let url = URL(string: "\(apiBase.absoluteString)/repos/\(repository)/releases?per_page=30") else {
            throw AppUpdateError.notConfigured
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AppUpdateError.network("HTTP \(http.statusCode)")
            }
            data = body
        } catch let error as AppUpdateError {
            throw error
        } catch {
            throw AppUpdateError.network(error.localizedDescription)
        }
        do {
            return try GitHubReleases.releases(from: data)
        } catch {
            throw AppUpdateError.network("respuesta inesperada")
        }
    }

    public func download(_ asset: AppRelease.Asset, to destination: URL,
                         progress: @escaping @Sendable (Int64) -> Void) async throws {
        do {
            try await FileDownload(url: asset.url, destination: destination, progress: progress).run()
        } catch let ModelInstallError.network(detail) {
            throw AppUpdateError.network(detail)
        }
    }
}
