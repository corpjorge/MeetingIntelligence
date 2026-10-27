import Foundation
import Testing
@testable import MeetingCore

/// Opt-in: makes one cloud request with synthetic text, never a saved meeting.
@Suite("Integración: GitHub Copilot CLI",
       .enabled(if: ProcessInfo.processInfo.environment["MI_COPILOT_TEST"] == "1"))
struct CopilotCLIIntegrationTests {
    @Test func automaticModelReturnsStructuredAnalysis() async throws {
        let request = AIRequest(
            instructions: "Procesa únicamente el texto proporcionado. No uses herramientas. Devuelve un análisis JSON con executiveSummary y technicalSummary como cadenas y items como una lista vacía.",
            input: "FIXTURE SINTÉTICO: el equipo revisó el estado del proyecto. No se asignaron tareas ni se asumieron compromisos.",
            jsonSchema: #"{"type":"object","properties":{"executiveSummary":{"type":"string"},"technicalSummary":{"type":"string"},"items":{"type":"array","maxItems":0}},"required":["executiveSummary","technicalSummary","items"],"additionalProperties":false}"#,
            requiredKeys: ["executiveSummary", "technicalSummary", "items"],
            model: nil, effort: nil, timeoutSeconds: 60)
        let response = try await CopilotCLIProvider().complete(request, configuration: AIProviderConfiguration(provider: .copilotCLI))
        let object = try #require(try JSONSerialization.jsonObject(with: response.json) as? [String: Any])
        #expect(!(object["executiveSummary"] as? String ?? "").isEmpty)
        #expect(object["technicalSummary"] is String)
        #expect((object["items"] as? [Any])?.isEmpty == true)
        #expect(response.model != nil)
    }
}

/// Catalog metadata only: no inference or meeting content is sent.
@Suite("Integración: catálogo de GitHub Copilot",
       .enabled(if: ProcessInfo.processInfo.environment["MI_COPILOT_CATALOG_TEST"] == "1"))
struct CopilotCatalogIntegrationTests {
    @Test func readsCatalogThroughInstalledCLI() async throws {
        let executable = try #require(await ToolEnvironment.shared.locate("copilot"))
        let environment = await ToolEnvironment.shared.environment()
        let catalog = try await CopilotModelCatalog.catalog(executable: executable, environment: environment)
        #expect(catalog.models == catalog.models.sorted())
        if let expected = ProcessInfo.processInfo.environment["MI_COPILOT_EXPECTED_LOGIN"] {
            #expect(catalog.login == expected)
            #expect(!catalog.models.isEmpty)
        }
    }
}
