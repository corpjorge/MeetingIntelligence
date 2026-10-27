import Foundation

/// Read-only SDK request: no session, prompt, tool execution or inference.
enum CopilotModelCatalog {
    struct Catalog: Sendable {
        var models: [String]
        var login: String?
    }

    static func load(executable: URL, environment: [String: String]) async throws -> [String] {
        try await catalog(executable: executable, environment: environment).models
    }

    static func catalog(executable: URL, environment: [String: String]) async throws -> Catalog {
        let root = try CLISupport.makeSandboxDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("copilot-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let account = try CopilotAuthentication.prepare(environment: environment, temporaryHome: home)
        var env = CopilotCLIProvider.environment(environment, home: home, account: account)
        var arguments = ["--headless", "--stdio", "--no-auto-update", "--no-custom-instructions",
                         "--disable-builtin-mcps", "--disable-client-telemetry", "--no-remote-export",
                         "--available-tools=\(CopilotCLIProvider.noToolsAllowlist)",
                         "--deny-tool=shell", "--deny-tool=write", "--deny-tool=url"]
        if let token = env["COPILOT_GITHUB_TOKEN"], !token.isEmpty {
            // Credential stays in the child environment, never argv or logs.
            env["COPILOT_SDK_AUTH_TOKEN"] = token
            arguments += ["--auth-token-env", "COPILOT_SDK_AUTH_TOKEN"]
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = env
        process.currentDirectoryURL = root
        let cancelled = OutputBuffer.Flag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try query(process: process, cancelled: cancelled, expectedAccount: account)
            }.value
        } onCancel: {
            cancelled.set()
            ProcessRunner.terminate(process)
        }
    }

    static func modelIDs(in result: [String: Any]) throws -> [String] {
        guard let models = result["models"] as? [[String: Any]] else {
            throw AIProviderError.failed(.copilotCLI, "el catálogo no contiene modelos de texto")
        }
        return Set(models.compactMap { model -> String? in
            guard let id = model["id"] as? String, !id.isEmpty, id.lowercased() != "auto",
                  model["availability"] as? String != "unavailable",
                  (model["policy"] as? [String: Any])?["state"] as? String != "disabled" else { return nil }
            return id
        }).sorted()
    }

    private static func query(process: Process, cancelled: OutputBuffer.Flag,
                              expectedAccount: CopilotAccount?) throws -> Catalog {
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let stderr = OutputBuffer(), timedOut = OutputBuffer.Flag()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        errors.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }
        defer {
            errors.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            ProcessRunner.terminate(process)
        }
        guard !cancelled.value else { throw CancellationError() }
        try process.run()
        guard !cancelled.value else { throw CancellationError() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            if process.isRunning { timedOut.set(); ProcessRunner.terminate(process) }
        }
        do {
            try send(id: 1, method: "connect", params: ["supportedTaskKinds": ["agent", "client", "shell"]],
                     to: input.fileHandleForWriting)
            let connected = try response(id: 1, from: output.fileHandleForReading)
            guard connected["ok"] as? Bool == true else {
                throw AIProviderError.failed(.copilotCLI, "no se pudo abrir la consulta de modelos")
            }
            // Let the CLI finish activating the SDK connection after its reply.
            Thread.sleep(forTimeInterval: 0.1)
            try send(id: 2, method: "auth.getStatus", params: [:], to: input.fileHandleForWriting)
            let authentication = try response(id: 2, from: output.fileHandleForReading)
            try CopilotAuthentication.validate(authentication, expected: expectedAccount)
            try send(id: 3, method: "models.list", params: [:], to: input.fileHandleForWriting)
            return Catalog(models: try modelIDs(in: response(id: 3, from: output.fileHandleForReading)),
                           login: authentication["login"] as? String)
        } catch {
            if cancelled.value { throw CancellationError() }
            if timedOut.value { throw ProcessRunnerError.timedOut(20) }
            throw error
        }
    }

    private static func send(id: Int, method: String, params: [String: Any], to file: FileHandle) throws {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        try file.write(contentsOf: frame)
    }

    private static func response(id: Int, from file: FileHandle) throws -> [String: Any] {
        while true {
            let event = try readFrame(from: file)
            guard event["id"] as? Int == id else { continue }
            if let error = event["error"] as? [String: Any] {
                throw AIProviderError.failed(.copilotCLI, String((error["message"] as? String ?? "error al consultar modelos").prefix(400)))
            }
            guard let result = event["result"] as? [String: Any] else {
                throw AIProviderError.failed(.copilotCLI, "respuesta de catálogo no válida")
            }
            return result
        }
    }

    static func readFrame(from file: FileHandle) throws -> [String: Any] {
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            let byte = file.readData(ofLength: 1)
            guard !byte.isEmpty, header.count < 8_192 else {
                throw AIProviderError.failed(.copilotCLI, "la consulta del catálogo terminó sin respuesta")
            }
            header.append(byte)
        }
        let lengthLine = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
        guard let value = lengthLine?.split(separator: ":", maxSplits: 1).last,
              let count = Int(value.trimmingCharacters(in: .whitespaces)), count > 0,
              count <= ProcessRunner.outputLimitBytes else {
            throw AIProviderError.failed(.copilotCLI, "tamaño de catálogo no válido")
        }
        var body = Data()
        while body.count < count {
            let chunk = file.readData(ofLength: count - body.count)
            guard !chunk.isEmpty else { throw AIProviderError.failed(.copilotCLI, "catálogo incompleto") }
            body.append(chunk)
        }
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw AIProviderError.failed(.copilotCLI, "catálogo no válido")
        }
        return object
    }
}
