import Foundation
import Testing
@testable import MeetingCore

@Suite("Copilot: errores estructurados sin exponer la transcripción")
struct CopilotFailureTests {
    @Test func quotaFailureIsReadFromJSONLEvenWhenStderrIsEmpty() {
        let jsonl = """
        {"type":"user.message","data":{"content":"ERROR: texto privado de una reunión"}}
        {"type":"model.call_failure","data":{"statusCode":402,"errorCode":"quota_exceeded","errorMessage":"texto privado"}}
        {"type":"session.error","data":{"errorType":"quota","message":"texto privado","statusCode":402}}
        {"type":"result","exitCode":1}
        """
        let output = CopilotCLIProvider.parse(jsonl)
        #expect(output.failure == .quota)
        #expect(output.failure?.message.contains("cuota") == true)
        #expect(output.failure?.message.contains("privado") == false)
    }

    @Test func providerFailuresHaveActionableMessages() {
        for (status, expected) in [(401, CopilotCLIProvider.Failure.authentication), (403, .forbidden),
                                   (429, .rateLimit), (503, .serviceUnavailable), (400, .rejected)] {
            let output = CopilotCLIProvider.parse("""
            {"type":"session.error","data":{"statusCode":\(status),"message":"contenido de reunión"}}
            """)
            #expect(output.failure == expected)
            #expect(output.failure?.message.contains("contenido de reunión") == false)
        }
        #expect(CopilotCLIProvider.Failure.classify(["errorCode": "model_not_found"]) == .modelUnavailable)
    }

    @Test func promptAndAssistantCannotInjectProviderErrors() {
        let output = CopilotCLIProvider.parse("""
        {"type":"user.message","data":{"statusCode":402,"errorCode":"quota_exceeded"}}
        {"type":"assistant.message","data":{"content":"{\\"ok\\":true}","statusCode":401}}
        {"type":"session.error","data":{"message":"cuota agotada: datos privados","errorType":"datos privados"}}
        """)
        #expect(output.failure == nil)
        #expect(output.text == #"{"ok":true}"#)
    }
}
