import Foundation

/// Local app-server metadata only. No thread, turn, prompt or inference is created.
enum CodexModelCatalog {
    static func load(executable: URL, environment: [String: String]) async throws -> [String] {
        let directory = try CLISupport.makeSandboxDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let available = try await CodexFeatureCache.shared.names(executable: executable, environment: environment)
        let disabled = try CodexProvider.disabledFeatures(available: available)
        let process = Process()
        process.executableURL = executable
        process.environment = environment
        process.currentDirectoryURL = directory
        var arguments = ["app-server", "--listen", "stdio://", "-c", "model_provider=\"openai\"",
                         "-c", "web_search=\"disabled\""]
        for feature in disabled { arguments += ["--disable", feature] }
        process.arguments = arguments
        let cancelled = OutputBuffer.Flag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try query(process: process, cancelled: cancelled)
            }.value
        } onCancel: {
            cancelled.set()
            ProcessRunner.terminate(process)
        }
    }

    static func modelIDs(in result: [String: Any]) throws -> [String] {
        guard let models = result["data"] as? [[String: Any]] else {
            throw AIProviderError.failed(.codex, "el catálogo no contiene una lista de modelos")
        }
        return models.compactMap { model in
            guard model["hidden"] as? Bool != true,
                  let id = model["model"] as? String, !id.isEmpty else { return nil }
            if let modalities = model["inputModalities"] as? [String], !modalities.contains("text") { return nil }
            return id
        }
    }

    private static func query(process: Process, cancelled: OutputBuffer.Flag) throws -> [String] {
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
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": [
                "name": "meeting_intelligence", "title": "Meeting Intelligence", "version": AppIdentity.version,
            ]]], to: input.fileHandleForWriting)
            _ = try response(id: 1, from: output.fileHandleForReading)
            try send(["method": "initialized"], to: input.fileHandleForWriting)
            var models: [String] = [], cursor: String?, seen: Set<String> = []
            for id in 2..<22 {
                var params: [String: Any] = ["includeHidden": false, "limit": 100]
                if let cursor { params["cursor"] = cursor }
                try send(["id": id, "method": "model/list", "params": params], to: input.fileHandleForWriting)
                let page = try response(id: id, from: output.fileHandleForReading)
                models += try modelIDs(in: page)
                cursor = page["nextCursor"] as? String
                guard let cursor, !cursor.isEmpty else { return models.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
                guard seen.insert(cursor).inserted else { break }
            }
            throw AIProviderError.failed(.codex, "el catálogo devolvió demasiadas páginas o un cursor repetido")
        } catch {
            if cancelled.value { throw CancellationError() }
            if timedOut.value { throw ProcessRunnerError.timedOut(20) }
            throw error
        }
    }

    private static func send(_ message: [String: Any], to file: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try file.write(contentsOf: data)
    }

    private static func response(id: Int, from file: FileHandle) throws -> [String: Any] {
        while true {
            let event = try readLine(from: file)
            guard event["id"] as? Int == id else { continue }
            if let error = event["error"] as? [String: Any] {
                throw AIProviderError.failed(.codex, String((error["message"] as? String ?? "error al consultar modelos").prefix(400)))
            }
            guard let result = event["result"] as? [String: Any] else {
                throw AIProviderError.failed(.codex, "respuesta de catálogo no válida")
            }
            return result
        }
    }

    static func readLine(from file: FileHandle) throws -> [String: Any] {
        var line = Data()
        while true {
            let byte = file.readData(ofLength: 1)
            guard !byte.isEmpty, line.count < ProcessRunner.outputLimitBytes else {
                throw AIProviderError.failed(.codex, "la consulta del catálogo terminó sin respuesta")
            }
            if byte.first == 10 { break }
            line.append(byte)
        }
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw AIProviderError.failed(.codex, "catálogo no válido")
        }
        return object
    }
}
