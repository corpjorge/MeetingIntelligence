import Foundation
import Testing
@testable import MeetingCore

/// Opt-in cloud requests with synthetic content; never reads saved meetings.
@Suite("Integración: respuesta real de los proveedores CLI",
       .enabled(if: ProcessInfo.processInfo.environment["MI_AI_PROVIDER_TEST"] == "1"))
struct CLIProviderIntegrationTests {
    @Test(arguments: [AIProviderKind.claudeCode, .codex, .antigravity])
    func syntheticStructuredResponse(provider kind: AIProviderKind) async throws {
        try await check(provider: kind)
    }

    @Test func selectedClaudeModelReturnsStructuredResponse() async throws {
        try await check(provider: .claudeCode, model: "opus", effort: "medium")
    }

    private func check(provider kind: AIProviderKind, model: String? = nil, effort: String? = nil) async throws {
        let request = AIRequest(
            instructions: "No uses herramientas. Procesa solo el texto sintético proporcionado y devuelve únicamente el JSON solicitado.",
            input: "FIXTURE SINTÉTICO: comprobación del proveedor. Devuelve {\"ok\":true}.",
            jsonSchema: #"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}"#,
            requiredKeys: ["ok"], model: model, effort: effort, timeoutSeconds: 90)
        let response = try await AIProviders.provider(for: kind).complete(
            request, configuration: AIProviderConfiguration(provider: kind))
        let object = try #require(try JSONSerialization.jsonObject(with: response.json) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
    }
}
