public import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var durationSeconds: Double
    public var timedOut: Bool

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: LocalizedError, Sendable {
    case launchFailed(String)
    case timedOut(Double)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): "No se pudo ejecutar el proceso: \(detail)"
        case .timedOut(let s): "El proceso excedió el tiempo límite de \(Int(s)) s y fue detenido."
        }
    }
}

/// Runs an external program with stdin, timeout and cooperative cancellation.
/// Output is captured in memory (capped) and never logged.
public enum ProcessRunner {
    public static let outputLimitBytes = 8 * 1024 * 1024

    public static func run(executable: URL, arguments: [String], stdin: Data? = nil,
                           environment: [String: String]? = nil, workingDirectory: URL? = nil,
                           timeout: Double) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

        let out = OutputBuffer(), err = OutputBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }

        let started = Date()
        let timedOut = OutputBuffer.Flag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, any Error>) in
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: ProcessResult(
                        exitCode: p.terminationStatus, stdout: out.data, stderr: err.data,
                        durationSeconds: Date().timeIntervalSince(started), timedOut: timedOut.value))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                    return
                }
                if let stdin {
                    DispatchQueue.global(qos: .utility).async {
                        try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    timedOut.set()
                    terminate(process)
                }
            }
        } onCancel: {
            terminate(process)
        }
    }

    /// SIGTERM, then SIGKILL if the process ignores it.
    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            if storage.count < ProcessRunner.outputLimitBytes {
                storage.append(data.prefix(ProcessRunner.outputLimitBytes - storage.count))
            }
        }
    }

    var data: Data { lock.withLock { storage } }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.withLock { flag = true } }
        var value: Bool { lock.withLock { flag } }
    }
}

/// Environment and executable discovery for CLIs installed through the user's
/// shell (Homebrew, npm, fnm/nvm, ~/.local/bin). GUI apps do not inherit the
/// login-shell PATH, so it is resolved explicitly and cached briefly.
public actor ToolEnvironment {
    public static let shared = ToolEnvironment()

    private var cachedPath: (value: String, at: Date)?

    static let fallbackDirectories = [
        "~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.npm-global/bin",
        "~/.bun/bin", "~/.volta/bin", "~/.cargo/bin", "/usr/bin", "/bin",
    ].map { ($0 as NSString).expandingTildeInPath }

    public func searchPath() async -> String {
        if let cachedPath, Date().timeIntervalSince(cachedPath.at) < 300 { return cachedPath.value }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var path = ""
        if let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: shell), arguments: ["-lic", "printf '__MI_PATH__%s' \"$PATH\""],
            timeout: 8), let range = result.stdoutText.range(of: "__MI_PATH__") {
            path = String(result.stdoutText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let merged = (path.split(separator: ":").map(String.init) + Self.fallbackDirectories)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ":")
        cachedPath = (merged, Date())
        return merged
    }

    /// Child-process environment: current environment with the login PATH.
    public func environment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = await searchPath()
        env["NO_COLOR"] = "1"
        return env
    }

    public func locate(_ name: String, configuredPath: String? = nil) async -> URL? {
        if let configuredPath, !configuredPath.isEmpty {
            let expanded = (configuredPath as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        for dir in await searchPath().split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }
}
