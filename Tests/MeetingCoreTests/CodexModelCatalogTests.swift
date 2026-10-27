import Foundation
import Testing
@testable import MeetingCore

@Suite("Codex: catálogo de modelos")
struct CodexModelCatalogTests {
    @Test func usesRequestModelIdentifierAndOnlyVisibleTextModels() throws {
        let page: [String: Any] = ["data": [
            ["id": "display-id", "model": "request-model", "displayName": "Modelo", "hidden": false],
            ["model": "hidden-model", "hidden": true],
            ["model": "image-model", "inputModalities": ["image"]],
            ["model": "second-model", "inputModalities": ["text", "image"]],
        ]]
        #expect(try CodexModelCatalog.modelIDs(in: page) == ["request-model", "second-model"])
    }

    @Test func readsConsecutiveUnicodeJSONLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mi-models-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"id\":1,\"result\":{\"name\":\"Español · 模型\"}}\n{\"id\":2,\"result\":{}}\n".utf8).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #expect(try CodexModelCatalog.readLine(from: handle)["id"] as? Int == 1)
        #expect(try CodexModelCatalog.readLine(from: handle)["id"] as? Int == 2)
    }
}

@Suite("Integración: catálogo de Codex",
       .enabled(if: ProcessInfo.processInfo.environment["MI_CODEX_CATALOG_TEST"] == "1"))
struct CodexCatalogIntegrationTests {
    @Test func readsModelsWithoutStartingAnInference() async throws {
        let executable = try #require(await ToolEnvironment.shared.locate("codex"))
        let environment = await ToolEnvironment.shared.environment()
        let models = try await CodexModelCatalog.load(executable: executable, environment: environment)
        #expect(!models.isEmpty)
        #expect(models.count == Set(models).count)
    }
}
