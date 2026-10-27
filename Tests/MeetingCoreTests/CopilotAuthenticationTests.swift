import Foundation
import Testing
@testable import MeetingCore

@Suite("Copilot: cuentas independientes de gh")
struct CopilotAuthenticationTests {
    @Test func preservesOnlySelectedAccountMetadataAndIgnoresPersonalTokens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-copilot-auth-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("temporary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let original = """
        // Copilot-managed internal state, including unrelated settings.
        {
          "lastLoggedInUser": {"host":"https://github.com","login":"business-user"},
          "loggedInUsers": [
            {"host":"https://github.com","login":"business-user","kind":"github"},
            {"host":"https://github.com","login":"personal-user","kind":"github"}
          ],
          "oauthToken":"FAKE_SECRET_MUST_NOT_COPY",
          "hooks":{"sessionStart":"must-not-run"},
          "enabledPlugins":{"computer-use":true},
          "trustedFolders":["/private/project"]
        }
        """
        let sourceFile = source.appendingPathComponent("config.json")
        try Data(original.utf8).write(to: sourceFile)
        let environment = ["COPILOT_HOME": source.path, "GH_TOKEN": "personal-token", "GITHUB_TOKEN": "another-personal-token"]
        let account = try #require(try CopilotAuthentication.prepare(environment: environment, temporaryHome: target))
        #expect(account.login == "business-user")
        let copied = try Data(contentsOf: target.appendingPathComponent("config.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: copied) as? [String: Any])
        #expect(Set(object.keys) == ["lastLoggedInUser", "loggedInUsers"])
        #expect((object["loggedInUsers"] as? [[String: Any]])?.count == 1)
        #expect(!String(decoding: copied, as: UTF8.self).contains("FAKE_SECRET"))
        #expect(try String(contentsOf: sourceFile, encoding: .utf8) == original)
        let child = CopilotCLIProvider.environment(environment, home: target, account: account)
        #expect(child["GH_TOKEN"] == nil && child["GITHUB_TOKEN"] == nil)
        #expect(child["COPILOT_HOME"] == target.path)
        #expect(child["COPILOT_GH_HOST"] == "github.com")
        #expect(environment["GH_TOKEN"] == "personal-token")
    }

    @Test func rejectsFallbackToAnotherAccount() throws {
        let expected = CopilotAccount(host: "https://github.com", login: "business-user")
        #expect(throws: AIProviderError.self) {
            try CopilotAuthentication.validate(["isAuthenticated": true, "login": "personal-user",
                                                 "host": "https://github.com", "authType": "gh-cli"], expected: expected)
        }
        #expect(throws: AIProviderError.self) {
            try CopilotAuthentication.validate(["isAuthenticated": false], expected: expected)
        }
        try CopilotAuthentication.validate(["isAuthenticated": true, "login": "business-user",
                                             "host": "https://github.com", "authType": "user"], expected: expected)
    }

    @Test func honorsExplicitCopilotTokenWithoutImportingOtherSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-copilot-token-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try CopilotAuthentication.prepare(environment: ["COPILOT_GITHUB_TOKEN": "dedicated-token"],
                                                        temporaryHome: root, sourceDirectory: root)
        #expect(account == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path))
    }
}
