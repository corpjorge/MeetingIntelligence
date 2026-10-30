public import Foundation

/// Ollama over its local HTTP API. Only loopback endpoints are accepted; meeting content leaves
/// the Mac only with Ollama Cloud models, which require consent like the other cloud providers.
public struct OllamaProvider: AIProvider {
    public let kind = AIProviderKind.ollama
    public static let defaultEndpoint = "http://127.0.0.1:11434"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func isCloudModel(_ name: String) -> Bool {
        var reference = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while let colon = reference.lastIndex(of: ":") {
            let tag = reference[reference.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            if tag == "cloud" || (!tag.contains("/") && tag.hasSuffix("-cloud")) { return true }
            guard tag == "local" else { return false }
            reference = String(reference[..<colon])
        }
        return false
    }

    static func endpoint(_ configuration: AIProviderConfiguration) throws -> URL {
        let raw = configuration.endpoint?.isEmpty == false ? configuration.endpoint! : defaultEndpoint
        guard let url = URL(string: raw), let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else {
            throw AIProviderError.failed(.ollama, "El endpoint de Ollama debe ser local (127.0.0.1 / localhost).")
        }
        return url
    }

    public func detect(configuration: AIProviderConfiguration) async -> ProviderStatus {
        guard let base = try? Self.endpoint(configuration) else {
            return ProviderStatus(kind: kind, installed: false, notes: ["Endpoint no local rechazado."])
        }
        var request = URLRequest(url: base.appendingPathComponent("api/version"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            let binary = await ToolEnvironment.shared.locate("ollama")
            return ProviderStatus(kind: kind, installed: false, executablePath: binary?.path,
                                  notes: [binary == nil ? "Ollama no está instalado. Descárgalo de ollama.com."
                                                        : "Ollama está instalado pero el servidor no responde. Ejecuta `ollama serve`."])
        }
        let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String
        let effortLevels = await thinkingLevels(base: base, model: configuration.model)
        var models: [String] = []
        if let (tags, _) = try? await session.data(from: base.appendingPathComponent("api/tags")),
           let json = try? JSONSerialization.jsonObject(with: tags) as? [String: Any],
           let list = json["models"] as? [[String: Any]] {
            models = list.compactMap { $0["name"] as? String }.sorted()
        }
        var status = ProviderStatus(kind: kind, installed: true, executablePath: base.absoluteString, version: version,
                                    authenticated: true, authDetail: "Servidor local", models: models,
                                    notes: Self.notes(models: models, selected: configuration.model))
        status.effortLevels = effortLevels
        return status
    }

    static func notes(models: [String], selected: String?) -> [String] {
        var notes = models.isEmpty ? ["No hay modelos descargados. Ejecuta `ollama pull <modelo>`."] : []
        if let selected, isCloudModel(selected) {
            notes.append("«\(selected)» es un modelo de Ollama Cloud: la transcripción se envía a ollama.com y requiere "
                         + "tu consentimiento.")
        } else if !models.isEmpty {
            notes.append("Todo se procesa en este Mac.")
        }
        if models.contains(where: isCloudModel) {
            notes.append("Los modelos con la etiqueta «cloud» se ejecutan en ollama.com, fuera de este Mac.")
        }
        return notes
    }

    /// Thinking levels a model declares in `/api/show` (`thinking.values`): model-defined
    /// strings (e.g. gpt-oss: low/medium/high) or on/off booleans. Empty when unsupported.
    func thinkingLevels(base: URL, model: String?) async -> [String] {
        guard let model, !model.isEmpty else { return [] }
        var request = URLRequest(url: base.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        request.timeoutInterval = 5
        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thinking = json["thinking"] as? [String: Any],
              let values = thinking["values"] as? [Any] else { return [] }
        var levels: [String] = []
        for value in values {
            if let s = value as? String { levels.append(s) }
            else if let b = value as? Bool { levels.append(b ? "on" : "off") }
        }
        return levels == ["off"] ? [] : levels
    }

    static let minimumContext = 32_768
    static let responseReserve = 16_384
    static let contextStep = 8_192

    struct ModelDetails: Equatable {
        var contextLength: Int?
        var isRemote: Bool
    }

    static func details(fromShow json: [String: Any]) -> ModelDetails {
        let info = json["model_info"] as? [String: Any] ?? [:]
        let architecture = info["general.architecture"] as? String
        let length = architecture.flatMap { info["\($0).context_length"] } ?? info["context_length"]
        let remote = (json["remote_host"] as? String).map { !$0.isEmpty } ?? false
        return ModelDetails(contextLength: (length as? NSNumber)?.intValue, isRemote: remote)
    }

    func modelDetails(base: URL, model: String) async throws -> ModelDetails? {
        var request = URLRequest(url: base.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        request.timeoutInterval = 10
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return nil
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Self.details(fromShow: json)
    }

    static func contextLength(for request: AIRequest, modelLimit: Int?) throws -> Int {
        let bytes = request.instructions.utf8.count + request.input.utf8.count + request.jsonSchema.utf8.count
        let needed = bytes * 2 / 3 + 512 + responseReserve
        let wanted = max(minimumContext, (needed + contextStep - 1) / contextStep * contextStep)
        guard let modelLimit, modelLimit > 0 else { return wanted }
        guard bytes / 6 + 1_024 <= modelLimit else {
            throw AIProviderError.failed(.ollama, "la transcripción no cabe en el contexto del modelo (\(modelLimit) tokens); "
                                         + "no se envió nada. Elige un modelo con más contexto.")
        }
        return min(wanted, modelLimit)
    }

    static func verifyComplete(_ json: [String: Any], contextLength: Int, checksContext: Bool) throws {
        if json["done_reason"] as? String == "length" {
            throw AIProviderError.failed(.ollama, "la respuesta se cortó al llegar al límite de \(contextLength) tokens de "
                                         + "contexto y no se guardó. Elige un modelo con más contexto o menos esfuerzo.")
        }
        let used = ((json["prompt_eval_count"] as? NSNumber)?.intValue ?? 0) + ((json["eval_count"] as? NSNumber)?.intValue ?? 0)
        if checksContext && used >= contextLength {
            throw AIProviderError.failed(.ollama, "se agotó el contexto (\(used) de \(contextLength) tokens): Ollama pudo "
                                         + "descartar parte de la transcripción o de las instrucciones, así que el resultado no "
                                         + "se guardó. Elige un modelo con más contexto.")
        }
    }

    static func failure(status: Int, body: Data, contextLength: Int) -> AIProviderError {
        let detail = ((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String)
            ?? String(decoding: body.prefix(300), as: UTF8.self)
        let lowered = detail.lowercased()
        if ["context length", "context size", "context window", "too long"].contains(where: { lowered.contains($0) }) {
            return .failed(.ollama, "la transcripción no cabe en el contexto de \(contextLength) tokens y Ollama no la "
                           + "procesó. Elige un modelo con más contexto.")
        }
        return .failed(.ollama, "HTTP \(status): \(detail.prefix(300))")
    }

    public func complete(_ request: AIRequest, configuration: AIProviderConfiguration) async throws -> AIResponse {
        let base = try Self.endpoint(configuration)
        guard let model = request.model ?? configuration.model, !model.isEmpty else {
            throw AIProviderError.failed(kind, "Selecciona un modelo de Ollama.")
        }
        let cloud = Self.isCloudModel(model)
        let details = try await modelDetails(base: base, model: model)
        if details?.isRemote == true && !cloud {
            throw AIProviderError.failed(kind, "«\(model)» se ejecuta en Ollama Cloud (ollama.com), pero su nombre no lo "
                                         + "indica; no se envió nada. Usa su nombre con la etiqueta «cloud» para confirmar el envío.")
        }
        let context = try Self.contextLength(for: request, modelLimit: details?.contextLength)
        let schema = try JSONSerialization.jsonObject(with: Data(request.jsonSchema.utf8))
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": schema,
            "options": ["temperature": 0.1, "num_ctx": context],
            "truncate": false,
            "shift": false,
            "messages": [
                ["role": "system", "content": request.instructions],
                ["role": "user", "content": request.input],
            ],
        ]
        switch request.effort {
        case nil, "": break
        case "on": body["think"] = true
        case "off": body["think"] = false
        case let level?: body["think"] = level
        }
        var urlRequest = URLRequest(url: base.appendingPathComponent("api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = request.timeoutSeconds
        try Task.checkCancellation()
        let started = Date()
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Self.failure(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data, contextLength: context)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any], let content = message["content"] as? String else {
            throw AIProviderError.invalidOutput(kind, "respuesta sin JSON válido")
        }
        try Self.verifyComplete(json, contextLength: context, checksContext: !cloud && details?.isRemote != true)
        guard let object = JSONExtraction.object(in: content, requiredKeys: request.requiredKeys) else {
            throw AIProviderError.invalidOutput(kind, "respuesta sin JSON válido")
        }
        return AIResponse(json: object, rawOutput: content, model: json["model"] as? String ?? model,
                          durationSeconds: Date().timeIntervalSince(started))
    }
}
