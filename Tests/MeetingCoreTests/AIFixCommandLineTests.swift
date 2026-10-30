import Foundation
import Testing
@testable import MeetingCore

@Suite("CLI: opciones que exigen valor")
struct AIFixCommandLineTests {
    private func parse(_ raw: [String]) throws -> CommandLineArguments {
        try CommandLineArguments(parsing: raw, specification: .mi)
    }

    @Test func optionsThatNeedAValueNeverBecomeFlags() {
        for raw in [["¿Qué se decidió?", "--meeting", "--provider", "claude", "--share"],
                    ["¿Qué se decidió?", "--provider", "claude", "--share", "--meeting"],
                    ["x", "--meeting="], ["x", "--meeting", ""], ["m1", "--format"], ["m1", "--out", "--format", "pdf"]] {
            let error = #expect(throws: CommandLineArgumentError.self) { try parse(raw) }
            #expect(error?.message.contains("requiere un valor") == true, "\(raw)")
        }
    }

    @Test func unknownOptionsAndFlagValuesAreRejected() {
        #expect(throws: CommandLineArgumentError.self) { try parse(["x", "--meting", "M1"]) }
        #expect(throws: CommandLineArgumentError.self) { try parse(["x", "--share=yes"]) }
    }

    @Test func parsesOptionsFlagsAndPositionals() throws {
        let args = try parse(["¿Qué", "se", "decidió?", "--meeting", "M1", "--provider=ollama", "--share", "--floor", "-0.5"])
        #expect(args.positional == ["¿Qué", "se", "decidió?"])
        #expect(args.options == ["meeting": "M1", "provider": "ollama", "floor": "-0.5"])
        #expect(args.flags == ["share"])
        #expect(try parse(["--share", "x"]) == CommandLineArguments(positional: ["x"], flags: ["share"]))
        #expect(try parse(["--", "--share"]).positional == ["--share"])
        #expect(try parse([]) == CommandLineArguments())
    }
}
