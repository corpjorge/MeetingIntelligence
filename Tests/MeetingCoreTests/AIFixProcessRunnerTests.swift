import Foundation
import Testing
@testable import MeetingCore

@Suite("IA: ProcessRunner (cancelación, descendientes y lectura completa)")
struct AIFixProcessRunnerTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mi-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func waitUntilGone(_ pid: pid_t, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) != 0
    }

    @Test func alreadyCancelledTaskNeverLaunchesTheProcess() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let witness = dir.appendingPathComponent("transcripcion-enviada")
        let task = Task { () async throws -> ProcessResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                               arguments: ["-c", "cat > '\(witness.path)'"],
                                               stdin: Data("transcripción".utf8), timeout: 5)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: witness.path))
    }

    @Test func cancellingARunningProcessThrowsCancellationQuickly() async throws {
        let task = Task {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 60)
        }
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(cancelledAt) < 5)
    }

    @Test func grandchildHoldingThePipeDoesNotBlockTheResult() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                 arguments: ["-c", "sleep 30 & echo $!; echo hola"], timeout: 20)
        let lines = result.stdoutText.split(separator: "\n")
        if let pid = lines.first.flatMap({ pid_t($0) }) { kill(pid, SIGKILL) }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(lines.last == "hola")
        #expect(result.exitCode == 0 && !result.timedOut)
    }

    @Test func timeoutTerminatesTheWholeProcessTree() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                 arguments: ["-c", "sleep 30 & echo $!; wait"], timeout: 1)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 8)
        let pid = try #require(result.stdoutText.split(separator: "\n").first.flatMap { pid_t($0) })
        let gone = await waitUntilGone(pid, seconds: 5)
        if !gone { kill(pid, SIGKILL) }
        #expect(gone)
    }

    @Test func outputWrittenRightBeforeExitIsNeverLost() async throws {
        for _ in 0..<10 {
            let result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "head -c 300000 /dev/zero | tr '\\000' a; printf FIN; head -c 200000 /dev/zero | tr '\\000' e >&2"],
                timeout: 20)
            #expect(result.stdout.count == 300_003)
            #expect(result.stdoutText.hasSuffix("FIN"))
            #expect(result.stderr.count == 200_000)
        }
    }

    @Test func largeStdinAndStdoutArePumpedTogether() async throws {
        let input = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: input,
                                                 timeout: 20)
        #expect(result.exitCode == 0)
        #expect(result.stdout == input)
    }
}
