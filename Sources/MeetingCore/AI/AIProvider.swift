public import Foundation

/// A single structured completion request. The user prompt carries meeting
/// content; it is always treated as untrusted data by the prompt templates.
public struct AIRequest: Sendable {
    public var instructions: String
    public var input: String
    /// JSON Schema (as JSON text) the final answer must satisfy.
    public var jsonSchema: String
    /// Top-level keys that identify the expected object in noisy outputs.
    public var requiredKeys: [String]
    public var model: String?
    /// Provider-specific reasoning effort (nil = provider default).
    public var effort: String?
    public var timeoutSeconds: Double

    public init(instructions: String, input: String, jsonSchema: String, requiredKeys: [String],
                model: String?, effort: String? = nil, timeoutSeconds: Double) {
        self.instructions = instructions
        self.input = input
        self.jsonSchema = jsonSchema
        self.requiredKeys = requiredKeys
        self.model = model
        self.effort = effort
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct AIResponse: Sendable {
    /// The JSON object matching the schema.
    public var json: Data
    public var rawOutput: String
    public var model: String?
    public var durationSeconds: Double
}

public struct ProviderStatus: Sendable, Hashable {
    public var kind: AIProviderKind
    public var installed: Bool
    public var executablePath: String?
    public var version: String?
    /// nil = could not be determined.
    public var authenticated: Bool?
    public var authDetail: String?
    public var accountLogin: String? = nil
    public var models: [String]
    /// A valid catalog was returned, even when it has no manually selectable models.
    public var modelCatalogLoaded: Bool = false
    public var supportsStructuredOutput: Bool
    public var notes: [String]
    /// Reasoning effort levels the provider accepts (empty = not configurable).
    public var effortLevels: [String] = []

    public init(kind: AIProviderKind, installed: Bool, executablePath: String? = nil, version: String? = nil,
                authenticated: Bool? = nil, authDetail: String? = nil, models: [String] = [],
                supportsStructuredOutput: Bool = true, notes: [String] = []) {
        self.kind = kind
        self.installed = installed
        self.executablePath = executablePath
        self.version = version
        self.authenticated = authenticated
        self.authDetail = authDetail
        self.models = models
        self.supportsStructuredOutput = supportsStructuredOutput
        self.notes = notes
    }

    public var isUsable: Bool { installed && authenticated != false }
}

public enum AIProviderError: LocalizedError, Sendable {
    case notInstalled(AIProviderKind)
    case notAuthenticated(AIProviderKind, String)
    case failed(AIProviderKind, String)
    case invalidOutput(AIProviderKind, String)
    case remoteConsentRequired(AIProviderKind)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let k): "\(k.displayName) no está instalado o no se encontró el ejecutable."
        case .notAuthenticated(let k, let detail): "\(k.displayName) no tiene una sesión activa: \(detail)"
        case .failed(let k, let detail): "\(k.displayName) falló: \(detail)"
        case .invalidOutput(let k, let detail): "\(k.displayName) devolvió una respuesta que no cumple el formato: \(detail)"
        case .remoteConsentRequired(let k): "Confirma qué información se compartirá con \(k.displayName) antes de continuar."
        }
    }
}

/// Common contract for every AI backend (Claude Code, Codex, Antigravity, Ollama).
public protocol AIProvider: Sendable {
    var kind: AIProviderKind { get }
    func detect(configuration: AIProviderConfiguration) async -> ProviderStatus
    func complete(_ request: AIRequest, configuration: AIProviderConfiguration) async throws -> AIResponse
}

extension AIProviderKind {
    public func sendsDataToRemoteService(model: String?) -> Bool {
        switch self {
        case .ollama: model.map(OllamaProvider.isCloudModel) ?? false
        default: sendsDataToRemoteService
        }
    }
}

public enum AIProviders {
    public static func provider(for kind: AIProviderKind) -> any AIProvider {
        switch kind {
        case .claudeCode: ClaudeCodeProvider()
        case .codex: CodexProvider()
        case .antigravity: AntigravityProvider()
        case .copilotCLI: CopilotCLIProvider()
        case .ollama: OllamaProvider()
        }
    }
}

/// Finds the JSON object that satisfies the expected shape inside model output
/// that may contain prose, code fences or several JSON objects.
public enum JSONExtraction {
    public static func object(in text: String, requiredKeys: [String]) -> Data? {
        for candidate in topLevelObjects(in: text) {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if requiredKeys.allSatisfy({ object[$0] != nil }) { return data }
        }
        return nil
    }

    /// Balanced `{…}` substrings, string-literal aware.
    static func topLevelObjects(in text: String) -> [String] {
        var results: [String] = []
        let chars = Array(text.unicodeScalars)
        var depth = 0, start = -1
        var inString = false, escaped = false
        for (i, c) in chars.enumerated() {
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = i }
                depth += 1
            case "}":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, start >= 0 {
                    var s = String.UnicodeScalarView()
                    s.append(contentsOf: chars[start...i])
                    results.append(String(s))
                }
            default: break
            }
        }
        return results
    }
}
