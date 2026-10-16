import Foundation

/// Shared plumbing for CLI-based providers.
enum CLISupport {
    static func version(_ executable: URL, env: [String: String]) async -> String? {
        guard let result = try? await ProcessRunner.run(executable: executable, arguments: ["--version"],
                                                        environment: env, timeout: 20),
              result.exitCode == 0 else { return nil }
        return result.stdoutText.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Fresh private working directory so project hooks/config/MCP files are never picked up.
    static func makeSandboxDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mi-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    static func shortError(_ text: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.suffix(3).joined(separator: " · ").prefix(400).description
    }
}

// MARK: - Claude Code

/// `claude -p` with JSON schema output. Tools are disabled (`--tools ""`), MCP is
/// restricted to none, nothing is persisted, and the process runs in an empty
/// private directory. Prompts are sent to Anthropic's cloud models.
public struct ClaudeCodeProvider: AIProvider {
    public let kind = AIProviderKind.claudeCode
    public init() {}

    public func detect(configuration: AIProviderConfiguration) async -> ProviderStatus {
        guard let exe = await ToolEnvironment.shared.locate("claude", configuredPath: configuration.executablePath) else {
            return ProviderStatus(kind: kind, installed: false)
        }
        let env = await ToolEnvironment.shared.environment()
        var status = ProviderStatus(kind: kind, installed: true, executablePath: exe.path,
                                    version: await CLISupport.version(exe, env: env),
                                    models: ["sonnet", "opus", "haiku"],
                                    notes: ["Se ejecuta localmente, pero el modelo de Anthropic procesa los datos en la nube."])
        if let result = try? await ProcessRunner.run(executable: exe, arguments: ["auth", "status", "--json"],
                                                     environment: env, timeout: 20),
           let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] {
            let loggedIn = json["loggedIn"] as? Bool ?? false
            status.authenticated = loggedIn
            status.authDetail = loggedIn ? "Método: \(json["authMethod"] as? String ?? "?")"
                                         : "Sin sesión. Ejecuta `claude` en una terminal e inicia sesión."
        }
        return status
    }

    public func complete(_ request: AIRequest, configuration: AIProviderConfiguration) async throws -> AIResponse {
        guard let exe = await ToolEnvironment.shared.locate("claude", configuredPath: configuration.executablePath) else {
            throw AIProviderError.notInstalled(kind)
        }
        let workdir = try CLISupport.makeSandboxDirectory()
        defer { try? FileManager.default.removeItem(at: workdir) }
        var args = ["-p", "--output-format", "json", "--json-schema", request.jsonSchema,
                    "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                    "--permission-mode", "dontAsk", "--system-prompt", request.instructions]
        if let model = request.model, !model.isEmpty { args += ["--model", model] }
        let result = try await ProcessRunner.run(executable: exe, arguments: args, stdin: Data(request.input.utf8),
                                                 environment: await ToolEnvironment.shared.environment(),
                                                 workingDirectory: workdir, timeout: request.timeoutSeconds)
        if result.timedOut { throw ProcessRunnerError.timedOut(request.timeoutSeconds) }
        guard let envelope = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw AIProviderError.failed(kind, CLISupport.shortError(result.stderrText + result.stdoutText))
        }
        if envelope["is_error"] as? Bool == true {
            let message = envelope["result"] as? String ?? "error desconocido"
            if message.localizedCaseInsensitiveContains("auth") || message.localizedCaseInsensitiveContains("login") {
                throw AIProviderError.notAuthenticated(kind, message)
            }
            throw AIProviderError.failed(kind, message)
        }
        let model = (envelope["modelUsage"] as? [String: Any])?.keys.sorted().joined(separator: ", ")
        if let structured = envelope["structured_output"], JSONSerialization.isValidJSONObject(structured) {
            let data = try JSONSerialization.data(withJSONObject: structured)
            return AIResponse(json: data, rawOutput: result.stdoutText, model: model ?? request.model,
                              durationSeconds: result.durationSeconds)
        }
        let text = envelope["result"] as? String ?? ""
        guard let data = JSONExtraction.object(in: text, requiredKeys: request.requiredKeys) else {
            throw AIProviderError.invalidOutput(kind, "sin objeto JSON con las claves esperadas")
        }
        return AIResponse(json: data, rawOutput: result.stdoutText, model: model ?? request.model,
                          durationSeconds: result.durationSeconds)
    }
}

// MARK: - Codex

/// `codex exec` with `--output-schema`, read-only sandbox, ephemeral session and
/// an empty working directory. Prompts are sent to OpenAI's cloud models.
public struct CodexProvider: AIProvider {
    public let kind = AIProviderKind.codex
    public init() {}

    public func detect(configuration: AIProviderConfiguration) async -> ProviderStatus {
        guard let exe = await ToolEnvironment.shared.locate("codex", configuredPath: configuration.executablePath) else {
            return ProviderStatus(kind: kind, installed: false)
        }
        let env = await ToolEnvironment.shared.environment()
        var status = ProviderStatus(kind: kind, installed: true, executablePath: exe.path,
                                    version: await CLISupport.version(exe, env: env),
                                    notes: ["Se ejecuta localmente, pero el modelo de OpenAI procesa los datos en la nube.",
                                            "Modelo vacío = el configurado en ~/.codex/config.toml."])
        if let result = try? await ProcessRunner.run(executable: exe, arguments: ["login", "status"], environment: env, timeout: 20) {
            let text = (result.stdoutText + result.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
            status.authenticated = result.exitCode == 0 && text.localizedCaseInsensitiveContains("logged in")
            status.authDetail = text.isEmpty ? nil : String(text.prefix(160))
        }
        return status
    }

    public func complete(_ request: AIRequest, configuration: AIProviderConfiguration) async throws -> AIResponse {
        guard let exe = await ToolEnvironment.shared.locate("codex", configuredPath: configuration.executablePath) else {
            throw AIProviderError.notInstalled(kind)
        }
        let workdir = try CLISupport.makeSandboxDirectory()
        defer { try? FileManager.default.removeItem(at: workdir) }
        let schemaURL = workdir.appendingPathComponent("schema.json")
        let outURL = workdir.appendingPathComponent("last-message.json")
        try Data(request.jsonSchema.utf8).write(to: schemaURL)
        // The sandbox dir also holds the schema; the agent sees an otherwise empty folder.
        let runDir = workdir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        var args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral", "--color", "never",
                    "--output-schema", schemaURL.path, "-o", outURL.path, "-C", runDir.path]
        if let model = request.model, !model.isEmpty { args += ["-m", model] }
        args.append("-")
        let prompt = request.instructions + "\n\n" + request.input
        let result = try await ProcessRunner.run(executable: exe, arguments: args, stdin: Data(prompt.utf8),
                                                 environment: await ToolEnvironment.shared.environment(),
                                                 workingDirectory: runDir, timeout: request.timeoutSeconds)
        if result.timedOut { throw ProcessRunnerError.timedOut(request.timeoutSeconds) }
        let lastMessage = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        guard result.exitCode == 0 else {
            throw AIProviderError.failed(kind, CLISupport.shortError(result.stderrText))
        }
        guard let data = JSONExtraction.object(in: lastMessage.isEmpty ? result.stdoutText : lastMessage,
                                               requiredKeys: request.requiredKeys) else {
            throw AIProviderError.invalidOutput(kind, "sin objeto JSON con las claves esperadas")
        }
        let model = result.stderrText.split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("model:") }
            .map { $0.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
        return AIResponse(json: data, rawOutput: lastMessage, model: model ?? request.model,
                          durationSeconds: result.durationSeconds)
    }
}

// MARK: - Antigravity

/// `agy -p` (headless). Tool requests are auto-denied by headless mode; we never
/// pass `--dangerously-skip-permissions`. The `response` field may contain more
/// than one JSON object, so the one with the expected keys is extracted.
public struct AntigravityProvider: AIProvider {
    public let kind = AIProviderKind.antigravity
    public init() {}
    static let maxArgumentBytes = 700_000

    public func detect(configuration: AIProviderConfiguration) async -> ProviderStatus {
        guard let exe = await ToolEnvironment.shared.locate("agy", configuredPath: configuration.executablePath) else {
            return ProviderStatus(kind: kind, installed: false)
        }
        let env = await ToolEnvironment.shared.environment()
        var status = ProviderStatus(kind: kind, installed: true, executablePath: exe.path,
                                    version: await CLISupport.version(exe, env: env),
                                    notes: ["Se ejecuta localmente, pero los modelos procesan los datos en la nube de Google.",
                                            "Las herramientas del agente quedan denegadas en modo headless."])
        if let result = try? await ProcessRunner.run(executable: exe, arguments: ["models"], environment: env, timeout: 40) {
            let models = result.stdoutText.split(separator: "\n").compactMap { line -> String? in
                let id = line.split(separator: "\t").first.map(String.init) ?? ""
                return id.isEmpty || id.contains(" ") ? nil : id
            }
            status.models = models
            status.authenticated = result.exitCode == 0 && !models.isEmpty
            status.authDetail = status.authenticated == true ? "\(models.count) modelos disponibles"
                                                             : CLISupport.shortError(result.stderrText + result.stdoutText)
        }
        return status
    }

    public func complete(_ request: AIRequest, configuration: AIProviderConfiguration) async throws -> AIResponse {
        guard let exe = await ToolEnvironment.shared.locate("agy", configuredPath: configuration.executablePath) else {
            throw AIProviderError.notInstalled(kind)
        }
        let prompt = request.instructions + "\n\n" + request.input
        guard prompt.utf8.count < Self.maxArgumentBytes else {
            throw AIProviderError.failed(kind, "La transcripción es demasiado larga para pasarla como argumento a agy.")
        }
        let workdir = try CLISupport.makeSandboxDirectory()
        defer { try? FileManager.default.removeItem(at: workdir) }
        var args = ["-p", prompt, "--output-format", "json", "--json-schema", request.jsonSchema,
                    "--print-timeout", "\(Int(request.timeoutSeconds))s", "--sandbox", "--disable-slash-commands"]
        if let model = request.model, !model.isEmpty { args += ["--model", model] }
        let result = try await ProcessRunner.run(executable: exe, arguments: args,
                                                 environment: await ToolEnvironment.shared.environment(),
                                                 workingDirectory: workdir, timeout: request.timeoutSeconds + 15)
        if result.timedOut { throw ProcessRunnerError.timedOut(request.timeoutSeconds) }
        guard let envelope = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw AIProviderError.failed(kind, CLISupport.shortError(result.stderrText + result.stdoutText))
        }
        let response = envelope["response"] as? String ?? ""
        guard (envelope["status"] as? String) == "SUCCESS", !response.isEmpty else {
            let denied = (envelope["denied_actions"] as? [[String: Any]])?.compactMap { $0["display_name"] as? String } ?? []
            let reason = denied.isEmpty ? CLISupport.shortError(result.stderrText)
                                        : "el agente intentó usar herramientas denegadas (\(denied.joined(separator: ", ")))"
            throw AIProviderError.failed(kind, "sin respuesta: \(reason)")
        }
        guard let data = JSONExtraction.object(in: response, requiredKeys: request.requiredKeys) else {
            throw AIProviderError.invalidOutput(kind, "sin objeto JSON con las claves esperadas")
        }
        return AIResponse(json: data, rawOutput: response, model: request.model ?? "predeterminado de agy",
                          durationSeconds: result.durationSeconds)
    }
}
