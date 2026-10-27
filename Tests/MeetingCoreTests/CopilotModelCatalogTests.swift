import Foundation
import Testing
@testable import MeetingCore

@Suite("Copilot: catálogo de modelos")
struct CopilotModelCatalogTests {
    @Test func listsTextModelsAndFiltersDisabledModels() throws {
        let result: [String: Any] = ["models": [
            ["id": "model-b"], ["id": "model-a"], ["id": "model-b"],
            ["id": "disabled", "policy": ["state": "disabled"]],
            ["id": "unavailable", "availability": "unavailable"], ["id": "auto"],
        ], "imageModels": [["id": "image-model"]]]
        #expect(try CopilotModelCatalog.modelIDs(in: result) == ["model-a", "model-b"])
        #expect(try CopilotModelCatalog.modelIDs(in: ["models": []]) == [])
    }

    @Test func readsByteLengthFramedUnicodeAndConsecutiveMessages() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mi-rpc-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var wire = Data()
        for id in [1, 2] {
            let body = try JSONSerialization.data(withJSONObject: ["id": id, "result": ["name": "Español · 模型"]])
            wire.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8))
            wire.append(body)
        }
        try wire.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #expect(try CopilotModelCatalog.readFrame(from: handle)["id"] as? Int == 1)
        #expect(try CopilotModelCatalog.readFrame(from: handle)["id"] as? Int == 2)
    }

    @Test func rejectsUnboundedFrameLength() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mi-rpc-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Content-Length: 999999999\r\n\r\n".utf8).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #expect(throws: AIProviderError.self) { try CopilotModelCatalog.readFrame(from: handle) }
    }
}
