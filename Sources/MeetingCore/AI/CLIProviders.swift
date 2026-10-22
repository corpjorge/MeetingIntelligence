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
    /// `claude --effort` values (verified in `claude --help`, v2.1.286).
    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]
    public init() {}

    /// Never includes flags that bypass permissions; tools are disabled entirely.
    static func arguments(for request: AIRequest) -> [String] {
        var args = ["-p", "--output-format", "json", "--json-schema", request.jsonSchema,
                    "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                    "--permission-mode", "dontAsk", "--system-prompt", request.instructions]
        if let model = request.model, !model.isEmpty { args += ["--model", model] }
        if let effort = request.effort, effortLevels.contains(effort) { args += ["--effort", effort] }
        return args
    }

    public func detect(configuration: AIProviderConfiguration) async -> ProviderStatus {
        guard let exe = await ToolEnvironment.shared.locate("claude", configuredPath: configuration.executablePath) else {
            return ProviderStatus(kind: kind, installed: false)
        }
        let env = await ToolEnvironment.shared.environment()
        var status = ProviderStatus(kind: kind, installed: true, executablePath: exe.path,
                                    version: await CLISupport.version(exe, env: env),
                                    models: ["sonnet", "opus", "haiku"],
                                    notes: ["Se ejecuta localmente, pero el modelo de Anthropic procesa los datos en la nube."])
        status.effortLevels = Self.effortLevels
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
        let args = Self.arguments(for: request)
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

/// `codex exec` isolated from the user's Codex setup (TD-12): `--ignore-user-config` skips MCP servers,
/// plugins, hooks, `notify`, web search and sandbox overrides from config.toml; command execution is disabled
/// (`shell_tool`, `unified_exec`); read-only sandbox, ephemeral session and an empty working directory.
/// Prompts are sent to OpenAI's cloud models.
public struct CodexProvider: AIProvider {
    public let kind = AIProviderKind.codex
    /// Passed as `-c model_reasoning_effort=…` (config key verified in the Codex 0.160.1 binary
    /// and the user's config.toml). Accepted values depend on the model; Codex reports them on error.
    public static let effortLevels = ["low", "medium", "high", "xhigh"]
    /// Without these the agent can run commands (verified with 0.160.1). If this Codex does not list them,
    /// nothing is sent.
    static let requiredDisabledFeatures = ["shell_tool", "unified_exec"]
    /// Other agent tools, disabled too when this Codex lists them: an unknown name makes Codex exit with an error.
    static let optionalDisabledFeatures = [
        "apps", "plugins", "remote_plugin", "browser_use", "browser_use_external", "in_app_browser", "computer_use",
        "image_generation", "multi_agent", "multi_agent_v2", "view_image", "hooks", "skill_search",
        "skill_mcp_dependency_install", "tool_suggest", "code_mode", "code_mode_host", "goals", "sleep_tool",
        "memories", "workspace_dependencies", "request_permissions_tool", "standalone_web_search",
    ]
    public init() {}

    static func arguments(for request: AIRequest, schemaPath: String, outputPath: String, workingDirectory: String,
                          disabledFeatures: [String] = requiredDisabledFeatures,
                          defaults: CodexUserDefaults = CodexUserDefaults()) -> [String] {
        var args = ["exec", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                    "--sandbox", "read-only", "--ephemeral", "--color", "never", "-c", "web_search=\"disabled\""]
        for feature in disabledFeatures { args += ["--disable", feature] }
        args += ["--output-schema", schemaPath, "-o", outputPath, "-C", workingDirectory]
        if let model = request.model.flatMap({ $0.isEmpty ? nil : $0 }) ?? defaults.model { args += ["-m", model] }
        let effort = request.effort.flatMap { effortLevels.contains($0) ? $0 : nil } ?? defaults.reasoningEffort
        if let effort { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        args.append("-")
        return args
    }

    /// Feature names from `codex features list` (first column of each row).
    static func featureNames(in listing: String) -> Set<String> {
        Set(listing.split(separator: "\n").compactMap { line in
            line.split(whereSeparator: \.isWhitespace).first.map(String.init)
                .flatMap { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." } ? $0 : nil }
        })
    }

    /// Features to pass to `--disable`; throws when command execution cannot be turned off.
    static func disabledFeatures(available: Set<String>) throws -> [String] {
        let missing = requiredDisabledFeatures.filter { !available.contains($0) }
        guard missing.isEmpty else {
            throw AIProviderError.failed(.codex, "esta versión de Codex no permite desactivar la ejecución de comandos "
                                         + "(\(missing.joined(separator: ", "))); no se envió nada. Actualiza Codex.")
        }
        return requiredDisabledFeatures + optionalDisabledFeatures.filter(available.contains)
    }

    public func detect(configuration: AIProviderConfiguration) async -> ProviderStatus {
        guard let exe = await ToolEnvironment.shared.locate("codex", configuredPath: configuration.executablePath) else {
            return ProviderStatus(kind: kind, installed: false)
        }
        let env = await ToolEnvironment.shared.environment()
        let defaults = CodexUserDefaults.load(environment: env)
        var notes = ["Se ejecuta localmente, pero el modelo de OpenAI procesa los datos en la nube.",
                     "Modelo y esfuerzo vacíos = los de ~/.codex/config.toml. El resto de ese archivo (MCP, plugins, "
                     + "hooks, búsqueda web) no se carga, y Codex se ejecuta sin poder usar comandos."]
        if let provider = defaults.modelProvider, provider != "openai" {
            notes.append("El proveedor «\(provider)» de config.toml no se usa: la app ignora ese archivo por seguridad.")
        }
        var status = ProviderStatus(kind: kind, installed: true, executablePath: exe.path,
                                    version: await CLISupport.version(exe, env: env), notes: notes)
        status.effortLevels = Self.effortLevels
        do {
            _ = try Self.disabledFeatures(available: try await CodexFeatureCache.shared.names(executable: exe, environment: env))
        } catch {
            status.notes.append(error.localizedDescription)
        }
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
        let env = await ToolEnvironment.shared.environment()
        let disabled = try Self.disabledFeatures(
            available: try await CodexFeatureCache.shared.names(executable: exe, environment: env))
        let workdir = try CLISupport.makeSandboxDirectory()
        defer { try? FileManager.default.removeItem(at: workdir) }
        let schemaURL = workdir.appendingPathComponent("schema.json")
        let outURL = workdir.appendingPathComponent("last-message.json")
        try Data(request.jsonSchema.utf8).write(to: schemaURL)
        // The sandbox dir also holds the schema; the agent sees an otherwise empty folder.
        let runDir = workdir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let args = Self.arguments(for: request, schemaPath: schemaURL.path, outputPath: outURL.path, workingDirectory: runDir.path,
                                  disabledFeatures: disabled, defaults: CodexUserDefaults.load(environment: env))
        let prompt = request.instructions + "\n\n" + request.input
        let result = try await ProcessRunner.run(executable: exe, arguments: args, stdin: Data(prompt.utf8),
                                                 environment: env, workingDirectory: runDir, timeout: request.timeoutSeconds)
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

// MARK: - GitHub Copilot CLI

/// `copilot` (GitHub Copilot CLI) reading the prompt from stdin, isolated (TD-12):
/// * a fresh, empty `COPILOT_HOME` per run, so the user's hooks, plugins, MCP servers, custom instructions and
///   saved sessions are not loaded, and nothing of the meeting is persisted in `~/.copilot` (the session store
///   and logs live in the temporary home and are deleted);
/// * no tools at all: `--available-tools` lists only a name that does not exist, which hides every tool
///   (verified: Copilot reports "Disabled tools: bash, create, edit, …"); shell, writes and URLs are also denied;
/// * any tool execution in the event stream discards the answer.
/// Prompts are sent to GitHub Copilot's cloud models. There is no JSON Schema flag: the schema goes in the prompt.
public struct CopilotCLIProvider: AIProvider {
    public let kind = AIProviderKind.copilotCLI
    /// `--reasoning-effort` values (`copilot --help`, 1.0.101). Copilot rejects them with the "auto" model.
    public static let effortLevels = ["minimal", "low", "medium", "high", "xhigh", "max"]
    /// Allowlist entry that matches no tool: every tool is hidden from the model.
    static let noToolsAllowlist = "mi_sin_herramientas"
    /// Environment variables that could re-enable tools, approvals or instruction files.
    static let strippedEnvironment = ["COPILOT_ALLOW_ALL", "COPILOT_ASSISTED_APPROVAL", "COPILOT_CUSTOM_INSTRUCTIONS_DIRS",
                                      "COPILOT_HOME"]
    public init() {}

    /// Never includes `--allow-all*`, `--yolo`, `--trust-folder` or `--allow-tool`.
    static func arguments(for request: AIRequest) -> [String] {
        var args = ["--output-format", "json", "--no-auto-update", "--no-custom-instructions", "--no-ask-user",
                    "--disable-builtin-mcps", "--disallow-temp-dir", "--no-remote-export", "--disable-client-telemetry",
                    "--available-tools=\(noToolsAllowlist)",
                    "--deny-tool=shell", "--deny-tool=write", "--deny-tool=url"]
        if let model = explicitModel(request.model) { args += ["--model", model] }
        if let effort = request.effort, effortLevels.contains(effort) { args += ["--reasoning-effort", effort] }
        return args
    }

    /// nil = let Copilot choose ("auto"), which is also its default.
    static func explicitModel(_ model: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty,
              model.lowercased() != "auto" else { return nil }
        return model
    }

    /// Rejects combinations Copilot would refuse, before anything is sent.
    static func validate(_ request: AIRequest) throws {
        if let effort = request.effort, effortLevels.contains(effort), explicitModel(request.model) == nil {
            throw AIProviderError.failed(.copilotCLI, "con el modelo «auto» no se puede elegir el esfuerzo. Escribe un "
                                         + "modelo concreto o deja el esfuerzo en Predeterminado. No se envió nada.")
        }
    }

    static func prompt(for request: AIRequest) -> String {
        request.instructions
            + "\n\nFormato de la respuesta: devuelve únicamente un objeto JSON válido, sin texto antes ni después y sin "
            + "bloques de código, que cumpla este JSON Schema:\n" + request.jsonSchema + "\n\n" + request.input
    }

    static func environment(_ base: [String: String], home: URL) -> [String: String] {
        var env = base.filter { !strippedEnvironment.contains($0.key) }
        env["COPILOT_HOME"] = home.path
        env["COPILOT_AUTO_UPDATE"] = "false"
        env["NO_COLOR"] = "1"
        return env
    }

    struct Output: Equatable {
        var text = ""
        var model: String?
        var toolsUsed: [String] = []
    }

    /// Last non-empty `assistant.message` of the JSONL event stream, and any tool execution.
    static func parse(_ jsonl: String) -> Output {
        var output = Output()
        for line in jsonl.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            let data = event["data"] as? [String: Any]
            switch type {
            case "assistant.message":
                if let content = data?["content"] as? String,
                   !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    output.text = content
                    output.model = data?["model"] as? String ?? output.model
                }
            case "tool.execution_start":
                output.toolsUsed.append(data?["toolName"] as? String ?? "desconocida")
            default:
                break
            }
        }
        return output
    }

    /// Another tool is also called `copilot` (AWS Copilot CLI): never send meetings to it.
    static func isGitHubCopilot(version: String?) -> Bool {
        version?.localizedCaseInsensitiveContains("GitHub Copilot") == true
    }

    public func detect(configuration: AIProviderConfiguration) async -> ProviderStatus {
        guard let exe = await ToolEnvironment.shared.locate("copilot", configuredPath: configuration.executablePath) else {
            return ProviderStatus(kind: kind, installed: false)
        }
        let env = await ToolEnvironment.shared.environment()
        let version = await CLISupport.version(exe, env: env)
        guard Self.isGitHubCopilot(version: version) else {
            return ProviderStatus(kind: kind, installed: false, executablePath: exe.path, version: version,
                                  notes: ["El ejecutable «copilot» de esta ubicación no es GitHub Copilot CLI."])
        }
        var status = ProviderStatus(kind: kind, installed: true, executablePath: exe.path, version: version,
                                    notes: ["Se ejecuta localmente, pero los modelos de GitHub Copilot procesan los datos en la nube.",
                                            "Sin herramientas y sin cargar tu ~/.copilot (hooks, plugins, MCP, instrucciones); "
                                            + "la sesión no se guarda.",
                                            "Modelo vacío = auto. El esfuerzo solo se aplica con un modelo concreto. "
                                            + "Cada análisis cuenta como una solicitud de Copilot."])
        status.authDetail = "Usa la sesión de `copilot login` o de `gh auth login`; se comprueba al analizar."
        status.effortLevels = Self.effortLevels
        return status
    }

    public func complete(_ request: AIRequest, configuration: AIProviderConfiguration) async throws -> AIResponse {
        guard let exe = await ToolEnvironment.shared.locate("copilot", configuredPath: configuration.executablePath) else {
            throw AIProviderError.notInstalled(kind)
        }
        try Self.validate(request)
        let env = await ToolEnvironment.shared.environment()
        guard Self.isGitHubCopilot(version: await CLISupport.version(exe, env: env)) else {
            throw AIProviderError.failed(kind, "el ejecutable \(exe.path) no es GitHub Copilot CLI; no se envió nada.")
        }
        let workdir = try CLISupport.makeSandboxDirectory()
        defer { try? FileManager.default.removeItem(at: workdir) }
        let home = workdir.appendingPathComponent("copilot-home", isDirectory: true)
        let runDir = workdir.appendingPathComponent("work", isDirectory: true)
        for dir in [home, runDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let result = try await ProcessRunner.run(executable: exe, arguments: Self.arguments(for: request),
                                                 stdin: Data(Self.prompt(for: request).utf8),
                                                 environment: Self.environment(env, home: home),
                                                 workingDirectory: runDir, timeout: request.timeoutSeconds)
        if result.timedOut { throw ProcessRunnerError.timedOut(request.timeoutSeconds) }
        let output = Self.parse(result.stdoutText)
        guard output.toolsUsed.isEmpty else {
            throw AIProviderError.failed(kind, "el agente usó herramientas (\(output.toolsUsed.joined(separator: ", "))); "
                                         + "se descartó la respuesta")
        }
        guard result.exitCode == 0 else {
            if result.stderrText.localizedCaseInsensitiveContains("No authentication information") {
                throw AIProviderError.notAuthenticated(kind, "ejecuta `copilot` en una terminal e inicia sesión con /login "
                                                       + "(o `gh auth login`).")
            }
            // stdout (JSONL) echoes the prompt, i.e. the transcript: errors use stderr only.
            throw AIProviderError.failed(kind, result.stderrText.isEmpty ? "terminó con el código \(result.exitCode)"
                                                                         : CLISupport.shortError(result.stderrText))
        }
        guard let data = JSONExtraction.object(in: output.text, requiredKeys: request.requiredKeys) else {
            throw AIProviderError.invalidOutput(kind, "sin objeto JSON con las claves esperadas")
        }
        return AIResponse(json: data, rawOutput: output.text, model: output.model ?? request.model,
                          durationSeconds: result.durationSeconds)
    }
}

/// The values of `$CODEX_HOME/config.toml` the app still honours: model and reasoning effort, used when the user
/// leaves them empty. Only top-level quoted strings with a safe charset are read; the rest of the file is ignored.
struct CodexUserDefaults: Equatable, Sendable {
    var model: String?
    var reasoningEffort: String?
    var modelProvider: String?

    static func parse(_ toml: String) -> CodexUserDefaults {
        var values: [String: String] = [:]
        for raw in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break } // first table: top-level keys are over
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard let quote = rest.first, quote == "\"" || quote == "'",
                  let close = rest.dropFirst().firstIndex(of: quote) else { continue }
            let value = String(rest[rest.index(after: rest.startIndex)..<close])
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:/-".contains($0)) })
            else { continue }
            values[key] = value
        }
        return CodexUserDefaults(model: values["model"], reasoningEffort: values["model_reasoning_effort"],
                                 modelProvider: values["model_provider"])
    }

    static func load(environment: [String: String]) -> CodexUserDefaults {
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? ("~/.codex" as NSString).expandingTildeInPath
        guard let text = try? String(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("config.toml"),
                                     encoding: .utf8) else { return CodexUserDefaults() }
        return parse(text)
    }
}

/// `codex features list`, cached per executable until it changes (upgrades rename or remove features).
actor CodexFeatureCache {
    static let shared = CodexFeatureCache()
    private var cache: [String: (stamp: Date?, names: Set<String>)] = [:]

    func names(executable: URL, environment: [String: String]) async throws -> Set<String> {
        let stamp = (try? FileManager.default.attributesOfItem(
            atPath: executable.resolvingSymlinksInPath().path)[.modificationDate]) as? Date
        if let hit = cache[executable.path], hit.stamp == stamp { return hit.names }
        let result = try await ProcessRunner.run(executable: executable, arguments: ["features", "list"],
                                                 environment: environment, timeout: 20)
        guard result.exitCode == 0 else {
            throw AIProviderError.failed(.codex, "no se pudieron consultar sus funciones (`codex features list`): "
                                         + CLISupport.shortError(result.stderrText))
        }
        let names = CodexProvider.featureNames(in: result.stdoutText)
        cache[executable.path] = (stamp, names)
        return names
    }
}

// MARK: - Antigravity

/// `agy -p` (headless). Tool requests are auto-denied by headless mode; we never
/// pass `--dangerously-skip-permissions`. The `response` field may contain more
/// than one JSON object, so the one with the expected keys is extracted.
public struct AntigravityProvider: AIProvider {
    public let kind = AIProviderKind.antigravity
    /// `agy --effort` values (verified in `agy --help`).
    public static let effortLevels = ["low", "medium", "high", "max"]
    public init() {}
    static let maxArgumentBytes = 700_000

    static func arguments(for request: AIRequest, prompt: String) -> [String] {
        var args = ["-p", prompt, "--output-format", "json", "--json-schema", request.jsonSchema,
                    "--print-timeout", "\(Int(request.timeoutSeconds))s", "--sandbox", "--disable-slash-commands"]
        if let model = request.model, !model.isEmpty { args += ["--model", model] }
        if let effort = request.effort, effortLevels.contains(effort) { args += ["--effort", effort] }
        return args
    }

    public func detect(configuration: AIProviderConfiguration) async -> ProviderStatus {
        guard let exe = await ToolEnvironment.shared.locate("agy", configuredPath: configuration.executablePath) else {
            return ProviderStatus(kind: kind, installed: false)
        }
        let env = await ToolEnvironment.shared.environment()
        var status = ProviderStatus(kind: kind, installed: true, executablePath: exe.path,
                                    version: await CLISupport.version(exe, env: env),
                                    notes: ["Se ejecuta localmente, pero los modelos procesan los datos en la nube de Google.",
                                            "Las herramientas del agente quedan denegadas en modo headless."])
        status.effortLevels = Self.effortLevels
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
        let args = Self.arguments(for: request, prompt: prompt)
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
