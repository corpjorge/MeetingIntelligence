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
        // A child that exits before reading all of stdin must yield EPIPE, not a SIGPIPE that kills this process.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

        let execution = ProcessExecution(process: process, output: outPipe, errors: errPipe,
                                         input: stdin == nil ? nil : inPipe, stdin: stdin ?? Data())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, any Error>) in
                execution.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }

    static let drainGraceSeconds = 2.0
    static let killGraceSeconds = 3.0

    /// SIGTERM, then SIGKILL if the process ignores it.
    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        terminateTree(of: process.processIdentifier)
    }

    static func terminateTree(of root: pid_t) {
        let group: pid_t? = getpgid(root) == root ? root : nil
        let members = [root] + descendants(of: root)
        send(SIGTERM, to: members, group: group)
        DispatchQueue.global().asyncAfter(deadline: .now() + killGraceSeconds) {
            var survivors = members.filter { kill($0, 0) == 0 }
            for pid in survivors { survivors += descendants(of: pid).filter { !survivors.contains($0) } }
            send(SIGKILL, to: survivors, group: group)
        }
    }

    static func send(_ sig: Int32, to pids: [pid_t], group: pid_t?) {
        if let group { killpg(group, sig) }
        for pid in pids where pid > 0 { kill(pid, sig) }
    }

    static func descendants(of root: pid_t) -> [pid_t] {
        var found: [pid_t] = [], pending = [root], seen: Set<pid_t> = [root]
        while let parent = pending.popLast() {
            for child in childProcesses(of: parent) where seen.insert(child).inserted {
                found.append(child)
                pending.append(child)
            }
        }
        return found
    }

    static func childProcesses(of parent: pid_t) -> [pid_t] {
        let capacity = proc_listchildpids(parent, nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = pids.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(min(Int(count), pids.count)).filter { $0 > 0 }
    }
}

final class ProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let output: Pipe
    private let errors: Pipe
    private let input: Pipe?
    private let stdin: Data
    private let stdout = OutputBuffer()
    private let stderr = OutputBuffer()
    private var continuation: CheckedContinuation<ProcessResult, any Error>?
    private var started = Date()
    private var cancelled = false
    private var launched = false
    private var timedOut = false
    private var exitStatus: Int32 = 0
    private var exitedAt: Date?
    private var drained = false

    init(process: Process, output: Pipe, errors: Pipe, input: Pipe?, stdin: Data) {
        self.process = process
        self.output = output
        self.errors = errors
        self.input = input
        self.stdin = stdin
    }

    func start(timeout: Double, continuation: CheckedContinuation<ProcessResult, any Error>) {
        process.terminationHandler = { [weak self] finished in self?.exited(status: finished.terminationStatus) }
        let failure: (any Error)? = lock.withLock {
            guard !cancelled else { return CancellationError() }
            started = Date()
            do {
                try process.run()
            } catch {
                return ProcessRunnerError.launchFailed(error.localizedDescription)
            }
            launched = true
            self.continuation = continuation
            return nil
        }
        if let failure {
            process.terminationHandler = nil
            continuation.resume(throwing: failure)
            return
        }
        Thread.detachNewThread { [self] in pump() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.expire() }
    }

    func cancel() {
        let running = lock.withLock { () -> Bool in
            cancelled = true
            return launched && exitedAt == nil
        }
        if running { ProcessRunner.terminate(process) }
    }

    private func expire() {
        let running = lock.withLock { () -> Bool in
            guard launched, exitedAt == nil else { return false }
            timedOut = true
            return true
        }
        if running { ProcessRunner.terminate(process) }
    }

    private func exited(status: Int32) {
        lock.withLock {
            exitStatus = status
            exitedAt = Date()
        }
        finishIfComplete()
    }

    private func pump() {
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = errors.fileHandleForReading.fileDescriptor
        let inFD = input?.fileHandleForWriting.fileDescriptor ?? -1
        for fd in [outFD, errFD, inFD] where fd >= 0 { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var outOpen = true, errOpen = true, inOpen = inFD >= 0 && !stdin.isEmpty
        if inFD >= 0 && !inOpen { try? input?.fileHandleForWriting.close() }
        var written = 0
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while outOpen || errOpen || inOpen {
            if let exitedAt = lock.withLock({ self.exitedAt }) {
                if !outOpen && !errOpen { break }
                if Date().timeIntervalSince(exitedAt) > ProcessRunner.drainGraceSeconds { break }
            }
            var fds: [pollfd] = []
            if outOpen { fds.append(pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)) }
            if errOpen { fds.append(pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)) }
            if inOpen { fds.append(pollfd(fd: inFD, events: Int16(POLLOUT), revents: 0)) }
            guard poll(&fds, nfds_t(fds.count), 100) > 0 else { continue }
            for entry in fds where entry.revents != 0 {
                if entry.fd == inFD {
                    let (count, failure) = stdin.withUnsafeBytes { raw in
                        let count = write(inFD, raw.baseAddress! + written, min(chunk.count, stdin.count - written))
                        return (count, errno)
                    }
                    if count > 0 { written += count }
                    if written >= stdin.count || (count < 0 && failure != EAGAIN && failure != EINTR) {
                        try? input?.fileHandleForWriting.close()
                        inOpen = false
                    }
                    continue
                }
                let count = read(entry.fd, &chunk, chunk.count)
                let failure = errno
                if count > 0 {
                    (entry.fd == outFD ? stdout : stderr).append(Data(chunk[0..<count]))
                } else if count == 0 || (failure != EAGAIN && failure != EINTR) {
                    if entry.fd == outFD { outOpen = false } else { errOpen = false }
                }
            }
        }
        if inOpen { try? input?.fileHandleForWriting.close() }
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        lock.withLock { drained = true }
        finishIfComplete()
    }

    private func finishIfComplete() {
        let completion = lock.withLock { () -> (CheckedContinuation<ProcessResult, any Error>, Result<ProcessResult, any Error>)? in
            guard drained, exitedAt != nil, let continuation else { return nil }
            self.continuation = nil
            if cancelled { return (continuation, .failure(CancellationError())) }
            return (continuation, .success(ProcessResult(
                exitCode: exitStatus, stdout: stdout.data, stderr: stderr.data,
                durationSeconds: Date().timeIntervalSince(started), timedOut: timedOut)))
        }
        if let (continuation, result) = completion { continuation.resume(with: result) }
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
        if !Task.isCancelled { cachedPath = (merged, Date()) }
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
