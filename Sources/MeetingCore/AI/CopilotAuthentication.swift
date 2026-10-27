import Foundation

/// Account-selection metadata only. Credentials stay in Copilot's own Keychain.
struct CopilotAccount: Codable, Sendable, Equatable {
    var host: String
    var login: String
}

enum CopilotAuthentication {
    private struct StoredUser: Codable {
        var host: String
        var login: String
        var kind: String?
    }
    private struct Selection: Codable {
        var lastLoggedInUser: CopilotAccount?
        var loggedInUsers: [StoredUser]?
    }

    /// Copy only the selected account's identity into the otherwise empty home.
    /// Never copy tokens, hooks, plugins, trusted folders or user instructions.
    static func prepare(environment: [String: String], temporaryHome: URL,
                        sourceDirectory: URL? = nil) throws -> CopilotAccount? {
        if let token = environment["COPILOT_GITHUB_TOKEN"], !token.isEmpty { return nil }
        let source = sourceDirectory ?? environment["COPILOT_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot")
        let file = source.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let selection: Selection
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
            selection = try decoder.decode(Selection.self, from: Data(contentsOf: file))
        } catch {
            throw AIProviderError.notAuthenticated(.copilotCLI,
                "No se pudo leer la selección de cuenta de Copilot. Abre Copilot y verifica /user antes de reintentar.")
        }
        guard let account = selection.lastLoggedInUser else { return nil }
        guard !account.login.isEmpty, !account.login.contains(where: \.isWhitespace),
              let host = URL(string: account.host), host.scheme == "https", host.host != nil else {
            throw AIProviderError.notAuthenticated(.copilotCLI, "La cuenta seleccionada de Copilot no es válida. Verifica /user.")
        }
        let users = (selection.loggedInUsers ?? []).filter { $0.host == account.host && $0.login == account.login }
        let minimal = Selection(lastLoggedInUser: account, loggedInUsers: users)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        let destination = temporaryHome.appendingPathComponent("config.json")
        try JSONEncoder().encode(minimal).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return account
    }

    static func validate(_ status: [String: Any], expected account: CopilotAccount?) throws {
        guard status["isAuthenticated"] as? Bool == true else {
            throw AIProviderError.notAuthenticated(.copilotCLI, "Inicia sesión con `copilot login` y verifica /user.")
        }
        if let account {
            let login = status["login"] as? String ?? ""
            let host = (status["host"] as? String).flatMap(URL.init(string:))?.host?.lowercased()
            let expectedHost = URL(string: account.host)?.host?.lowercased()
            guard login.caseInsensitiveCompare(account.login) == .orderedSame, host == expectedHost,
                  status["authType"] as? String != "gh-cli" else {
                throw AIProviderError.notAuthenticated(.copilotCLI,
                    "No se pudo usar la sesión de Copilot de \(account.login). Verifica `copilot login` y /user; no se enviará el análisis con la cuenta de gh.")
            }
        }
    }
}
