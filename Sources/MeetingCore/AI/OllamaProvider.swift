public import Foundation

/// Ollama over its local HTTP API. Only loopback endpoints are accepted, so
/// meeting content never leaves the Mac with this provider.
public struct OllamaProvider: AIProvider {
    public let kind = AIProviderKind.ollama
    public static let defaultEndpoint = "http://127.0.0.1:11434"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
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
        var models: [String] = []
        if let (tags, _) = try? await session.data(from: base.appendingPathComponent("api/tags")),
           let json = try? JSONSerialization.jsonObject(with: tags) as? [String: Any],
           let list = json["models"] as? [[String: Any]] {
            models = list.compactMap { $0["name"] as? String }.sorted()
        }
        return ProviderStatus(kind: kind, installed: true, executablePath: base.absoluteString, version: version,
                              authenticated: true, authDetail: "Servidor local", models: models,
                              notes: models.isEmpty ? ["No hay modelos descargados. Ejecuta `ollama pull <modelo>`."]
                                                    : ["Todo se procesa en este Mac."])
    }

    public func complete(_ request: AIRequest, configuration: AIProviderConfiguration) async throws -> AIResponse {
        let base = try Self.endpoint(configuration)
        guard let model = request.model ?? configuration.model, !model.isEmpty else {
            throw AIProviderError.failed(kind, "Selecciona un modelo de Ollama.")
        }
        let schema = try JSONSerialization.jsonObject(with: Data(request.jsonSchema.utf8))
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": schema,
            "options": ["temperature": 0.1, "num_ctx": 32_768],
            "messages": [
                ["role": "system", "content": request.instructions],
                ["role": "user", "content": request.input],
            ],
        ]
        var urlRequest = URLRequest(url: base.appendingPathComponent("api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = request.timeoutSeconds
        let started = Date()
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIProviderError.failed(kind, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any], let content = message["content"] as? String,
              let object = JSONExtraction.object(in: content, requiredKeys: request.requiredKeys) else {
            throw AIProviderError.invalidOutput(kind, "respuesta sin JSON válido")
        }
        return AIResponse(json: object, rawOutput: content, model: json["model"] as? String ?? model,
                          durationSeconds: Date().timeIntervalSince(started))
    }
}
