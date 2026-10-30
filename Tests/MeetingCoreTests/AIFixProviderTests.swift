import Foundation
import Testing
@testable import MeetingCore

final class OllamaStubProtocol: URLProtocol {
    final class Server: @unchecked Sendable {
        let port: Int
        private let lock = NSLock()
        private let respond: @Sendable (String, [String: Any]) -> (Int, Any)
        private var received: [(path: String, body: [String: Any])] = []

        init(port: Int, respond: @escaping @Sendable (String, [String: Any]) -> (Int, Any)) {
            self.port = port
            self.respond = respond
        }

        var configuration: AIProviderConfiguration {
            var configuration = AIProviderConfiguration(provider: .ollama)
            configuration.endpoint = "http://127.0.0.1:\(port)"
            return configuration
        }

        var provider: OllamaProvider {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.protocolClasses = [OllamaStubProtocol.self]
            return OllamaProvider(session: URLSession(configuration: sessionConfiguration))
        }

        func requests(to path: String) -> [[String: Any]] {
            lock.withLock { received.filter { $0.path == path }.map(\.body) }
        }

        func handle(path: String, body: [String: Any]) -> (Int, Any) {
            lock.withLock { received.append((path, body)) }
            return respond(path, body)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [Int: Server] = [:]

    static func start(_ respond: @escaping @Sendable (String, [String: Any]) -> (Int, Any)) -> Server {
        lock.withLock {
            var port = Int.random(in: 20_000...60_000)
            while servers[port] != nil { port = Int.random(in: 20_000...60_000) }
            let server = Server(port: port, respond: respond)
            servers[port] = server
            return server
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.lock.withLock({ Self.servers[url.port ?? 0] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let body = (try? JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any]) ?? [:]
        let (status, payload) = server.handle(path: url.path, body: body)
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("IA: aislamiento de Claude, errores de Codex y contexto de Ollama")
struct AIFixProviderTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mi-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func executable(_ name: String, in dir: URL, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func request(input: String = "x", model: String? = nil, keys: [String] = []) -> AIRequest {
        AIRequest(instructions: "Instrucciones", input: input, jsonSchema: #"{"type":"object"}"#, requiredKeys: keys,
                  model: model, timeoutSeconds: 30)
    }

    nonisolated(unsafe) private static let chatAnswer: [String: Any] = [
        "model": "llama3.1", "message": ["role": "assistant", "content": #"{"a":"ok"}"#], "done": true,
        "done_reason": "stop", "prompt_eval_count": 1_000, "eval_count": 20,
    ]

    @Test func claudeRunsInSafeModeWithoutBareMode() {
        let args = ClaudeCodeProvider.arguments(for: request())
        #expect(args.contains("--safe-mode"))
        #expect(!args.contains("--bare"))
        #expect(!args.contains { $0.localizedCaseInsensitiveContains("dangerously") })
        #expect(args.windowContains(["--tools", ""]) && args.contains("--strict-mcp-config"))
    }

    @Test func claudeSafeModeIsDetectedFromItsHelp() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = try executable("claude-actual", in: dir, """
        #!/bin/sh
        [ "$1" = --help ] && echo '  --safe-mode                           Start with all customizations disabled'
        exit 0
        """)
        let old = try executable("claude-antiguo", in: dir, """
        #!/bin/sh
        [ "$1" = --help ] && echo '  --bare                                Minimal mode'
        exit 0
        """)
        let environment = ["PATH": "/usr/bin:/bin"]
        #expect(try await ClaudeSafeModeCache.shared.supportsSafeMode(executable: current, environment: environment))
        #expect(try await ClaudeSafeModeCache.shared.supportsSafeMode(executable: old, environment: environment) == false)
        try await ClaudeCodeProvider.requireSafeMode(executable: current, environment: environment)
        let error = await #expect(throws: AIProviderError.self) {
            try await ClaudeCodeProvider.requireSafeMode(executable: old, environment: environment)
        }
        #expect(error?.localizedDescription.contains("Actualiza Claude Code") == true)
    }

    @Test func claudeWithoutSafeModeSendsNothing() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let witness = dir.appendingPathComponent("transcripcion-enviada")
        let fake = try executable("claude", in: dir, """
        #!/bin/sh
        if [ "$1" = --help ]; then echo '  -p, --print'; exit 0; fi
        cat > '\(witness.path)'
        echo '{"is_error":false,"result":"{}"}'
        """)
        var configuration = AIProviderConfiguration(provider: .claudeCode)
        configuration.executablePath = fake.path
        await #expect(throws: AIProviderError.self) {
            try await ClaudeCodeProvider().complete(request(input: "transcripción"), configuration: configuration)
        }
        #expect(!FileManager.default.fileExists(atPath: witness.path))
    }

    @Test func codexErrorsUseOnlyItsErrorLines() {
        let prompt = "Instrucciones\n\n<<<TRANSCRIPCION_INICIO>>>\n"
            + "[S1 | 00:00:01 | Ana] ERROR: el pago del cliente Pérez falló\n<<<TRANSCRIPCION_FIN>>>"
        let stderr = """
        OpenAI Codex v0.160.1 (research preview)
        --------
        workdir: /w
        model: gpt-5
        --------
        user
        \(prompt)
        [2026-10-30T10:00:00] ERROR: unexpected status 401 Unauthorized: Missing bearer token
        """
        let summary = CodexProvider.errorSummary(stderr: stderr, prompt: prompt, exitCode: 1)
        #expect(summary.contains("401 Unauthorized"))
        #expect(!summary.contains("Pérez") && !summary.contains("TRANSCRIPCION") && !summary.contains("Instrucciones"))
        #expect(CodexProvider.errorSummary(stderr: "user\n" + prompt, prompt: prompt, exitCode: 2) == "terminó con el código 2")
        #expect(CodexProvider.errorSummary(stderr: "Error: Unknown feature flag: x", prompt: prompt, exitCode: 2)
            .contains("Unknown feature flag"))
        let merged = CodexProvider.errorSummary(stderr: "user\n" + prompt + "[ts] ERROR: stream disconnected", prompt: prompt,
                                                exitCode: 1)
        #expect(merged.contains("stream disconnected") && !merged.contains("Pérez"))
        let partial = CodexProvider.errorSummary(stderr: "user\nfalló[ts] ERROR: el pago del cliente Pérez falló",
                                                 prompt: prompt, exitCode: 1)
        #expect(partial == "terminó con el código 1")
    }

    @Test func codexFailureNeverShowsTheTranscript() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try executable("codex", in: dir, """
        #!/bin/sh
        case "$1" in
          features) printf 'shell_tool  stable  true\\nunified_exec  stable  true\\n'; exit 0 ;;
          --version) echo 'codex-cli 0.160.1'; exit 0 ;;
          exec) echo user >&2; cat >&2; echo '[2026-10-30T10:00:00] ERROR: unexpected status 401 Unauthorized' >&2; exit 1 ;;
        esac
        exit 64
        """)
        var configuration = AIProviderConfiguration(provider: .codex)
        configuration.executablePath = fake.path
        let error = await #expect(throws: AIProviderError.self) {
            try await CodexProvider().complete(
                request(input: "[S1 | 00:00:01 | Ana] ERROR: el pago del cliente Pérez falló", model: "gpt-5"),
                configuration: configuration)
        }
        let message = error?.localizedDescription ?? ""
        #expect(message.contains("401 Unauthorized"))
        #expect(!message.contains("Pérez") && !message.contains("Instrucciones"))
    }

    @Test func ollamaCloudModelsAreRemote() {
        for name in ["gpt-oss:120b-cloud", "qwen3-coder:480b-cloud", "glm-4.6:cloud", "GPT-OSS:20B-CLOUD",
                     " deepseek-v3.1:671b-cloud ", "gpt-oss:120b-cloud:local"] {
            #expect(OllamaProvider.isCloudModel(name), "\(name)")
        }
        for name in ["llama3.2", "llama3.2:latest", "cloud", "registry.local:5000/llama3", "mimodelo:cloud-v2",
                     "gpt-oss:120b", "gpt-oss:local", ""] {
            #expect(!OllamaProvider.isCloudModel(name), "\(name)")
        }
        #expect(AIProviderKind.ollama.sendsDataToRemoteService(model: "gpt-oss:120b-cloud"))
        #expect(!AIProviderKind.ollama.sendsDataToRemoteService(model: "llama3.2"))
        #expect(!AIProviderKind.ollama.sendsDataToRemoteService(model: nil))
        for kind in AIProviderKind.allCases where kind != .ollama {
            #expect(kind.sendsDataToRemoteService(model: nil) && kind.sendsDataToRemoteService(model: "llama3.2"))
        }
        let notes = OllamaProvider.notes(models: ["gpt-oss:120b-cloud", "llama3.2"], selected: "gpt-oss:120b-cloud")
        #expect(notes.contains { $0.contains("ollama.com") } && !notes.contains("Todo se procesa en este Mac."))
        #expect(OllamaProvider.notes(models: ["llama3.2"], selected: "llama3.2") == ["Todo se procesa en este Mac."])
    }

    @Test func ollamaSizesTheContextAndAsksNotToTruncate() async throws {
        let server = OllamaStubProtocol.start { path, _ in
            path == "/api/show"
                ? (200, ["model_info": ["general.architecture": "llama", "llama.context_length": 131_072]])
                : (200, Self.chatAnswer)
        }
        let long = String(repeating: "[S1 | 00:00:01 | Ana] Revisamos el despliegue del viernes y el plan. ", count: 2_000)
        let response = try await server.provider.complete(request(input: long, model: "llama3.1", keys: ["a"]),
                                                          configuration: server.configuration)
        #expect(String(decoding: response.json, as: UTF8.self).contains("ok"))
        let chat = try #require(server.requests(to: "/api/chat").first)
        let context = try #require((chat["options"] as? [String: Any])?["num_ctx"] as? Int)
        #expect(context > 32_768 && context <= 131_072 && context % 8_192 == 0)
        #expect(context >= long.utf8.count * 2 / 3)
        #expect(chat["truncate"] as? Bool == false && chat["shift"] as? Bool == false)

        let small = try await server.provider.complete(request(input: "hola", model: "llama3.1", keys: ["a"]),
                                                       configuration: server.configuration)
        #expect(small.model == "llama3.1")
        #expect((server.requests(to: "/api/chat").last?["options"] as? [String: Any])?["num_ctx"] as? Int == 32_768)
    }

    @Test func ollamaNeverAcceptsATruncatedResult() async throws {
        let exhausted = OllamaStubProtocol.start { path, body in
            guard path == "/api/chat" else { return (200, ["model_info": [String: Any]()]) }
            let context = ((body["options"] as? [String: Any])?["num_ctx"] as? Int) ?? 0
            var answer = Self.chatAnswer
            answer["prompt_eval_count"] = context
            answer["eval_count"] = 12
            return (200, answer)
        }
        let error = await #expect(throws: AIProviderError.self) {
            try await exhausted.provider.complete(request(model: "llama3.1", keys: ["a"]), configuration: exhausted.configuration)
        }
        #expect(error?.localizedDescription.contains("contexto") == true)

        let cut = OllamaStubProtocol.start { path, _ in
            guard path == "/api/chat" else { return (200, ["model_info": [String: Any]()]) }
            var answer = Self.chatAnswer
            answer["done_reason"] = "length"
            return (200, answer)
        }
        await #expect(throws: AIProviderError.self) {
            try await cut.provider.complete(request(model: "llama3.1", keys: ["a"]), configuration: cut.configuration)
        }

        let rejected = OllamaStubProtocol.start { path, _ in
            path == "/api/chat" ? (400, ["error": "the input length exceeds the context length"])
                                : (200, ["model_info": [String: Any]()])
        }
        let refusal = await #expect(throws: AIProviderError.self) {
            try await rejected.provider.complete(request(model: "llama3.1", keys: ["a"]), configuration: rejected.configuration)
        }
        #expect(refusal?.localizedDescription.contains("no cabe en el contexto") == true)
    }

    @Test func ollamaSendsNothingThatCannotFitOrThatGoesToTheCloudUnannounced() async throws {
        let small = OllamaStubProtocol.start { path, _ in
            path == "/api/show" ? (200, ["model_info": ["general.architecture": "llama", "llama.context_length": 8_192]])
                                : (200, Self.chatAnswer)
        }
        let long = String(repeating: "Revisamos el despliegue del viernes. ", count: 4_000)
        await #expect(throws: AIProviderError.self) {
            try await small.provider.complete(request(input: long, model: "llama3.1", keys: ["a"]), configuration: small.configuration)
        }
        #expect(small.requests(to: "/api/chat").isEmpty)
        _ = try await small.provider.complete(request(input: "hola", model: "llama3.1", keys: ["a"]), configuration: small.configuration)
        #expect((small.requests(to: "/api/chat").last?["options"] as? [String: Any])?["num_ctx"] as? Int == 8_192)

        let remote = OllamaStubProtocol.start { path, _ in
            path == "/api/show" ? (200, ["remote_host": "https://ollama.com:443", "remote_model": "gpt-oss:120b"])
                                : (200, Self.chatAnswer)
        }
        await #expect(throws: AIProviderError.self) {
            try await remote.provider.complete(request(model: "mi-modelo:latest", keys: ["a"]), configuration: remote.configuration)
        }
        #expect(remote.requests(to: "/api/chat").isEmpty)
        _ = try await remote.provider.complete(request(model: "gpt-oss:120b-cloud", keys: ["a"]), configuration: remote.configuration)
        #expect(remote.requests(to: "/api/chat").count == 1)
    }
}
