import Foundation

/// Resolves the absolute path to the `toki` binary.
/// GUI apps don't inherit shell PATH, so we search common locations.
enum TokiPath {
    static let resolved: String = {
        let candidates = [
            "/opt/homebrew/bin/toki",
            "/usr/local/bin/toki",
            "\(NSHomeDirectory())/.local/bin/toki",
            "\(NSHomeDirectory())/.cargo/bin/toki",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fallback — hope it's in PATH
        return "toki"
    }()
}

/// UDS server that listens for incoming JSONL from `toki trace --sink uds://<path>`.
/// Toki Monitor acts as the SERVER — toki connects to us and pushes events.
final class TokiTraceListener {
    private let socketPath: String
    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.toki.trace-listener", qos: .utility)

    var onReady: (@Sendable () -> Void)?
    var onData: (@Sendable (Data) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?

    init(socketPath: String = "/tmp/toki-monitor.sock") {
        self.socketPath = socketPath
    }

    func start() -> Bool {
        stop()
        unlink(socketPath)

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString { cstr in strlcpy(ptr, cstr, maxLen) }
        }

        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindOK == 0 else {
            close(serverFD); serverFD = -1; return false
        }
        guard listen(serverFD, 1) == 0 else {
            close(serverFD); serverFD = -1; return false
        }
        _ = fcntl(serverFD, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.serverFD >= 0 { close(self.serverFD); self.serverFD = -1 }
        }
        source.resume()
        acceptSource = source

        onReady?()
        return true
    }

    func stop() {
        clientSource?.cancel()
        clientSource = nil
        acceptSource?.cancel()
        acceptSource = nil
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        unlink(socketPath)
    }

    // MARK: - Private

    private func acceptClient() {
        var clientAddr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(serverFD, sockPtr, &len)
            }
        }
        guard clientFD >= 0 else { return }
        _ = fcntl(clientFD, F_SETFL, O_NONBLOCK)

        // Only keep one client (toki trace process)
        clientSource?.cancel()

        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readFromClient(fd: clientFD)
        }
        source.setCancelHandler { [weak self] in
            close(clientFD)
            self?.onDisconnect?()
        }
        source.resume()
        clientSource = source
    }

    private func readFromClient(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)

        if n <= 0 {
            clientSource?.cancel()
            clientSource = nil
            return
        }

        onData?(Data(buf[0..<n]))
    }
}

// MARK: - Shared CLI Process Runner

enum CLIRunnerError: Error, LocalizedError {
    case exitCode(Int)
    case timeout
    var errorDescription: String? {
        switch self {
        case .exitCode(let code): "toki exited with code \(code)"
        case .timeout: "toki CLI timed out"
        }
    }
}

enum CLIProcessRunner {
    /// Run a CLI process on a background queue, reading stdout before waitUntilExit
    /// to avoid pipe buffer deadlock.
    /// - Parameter timeout: Maximum time in seconds before the process is killed (default 30s).
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 30) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                // Track whether continuation has been resumed
                let resumed = LockedFlag()

                do {
                    try process.run()

                    // Schedule a timeout that kills the process
                    let timeoutItem = DispatchWorkItem {
                        if process.isRunning {
                            process.terminate()
                        }
                        if resumed.setIfUnset() {
                            continuation.resume(throwing: CLIRunnerError.timeout)
                        }
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + timeout,
                        execute: timeoutItem
                    )

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeoutItem.cancel()

                    if resumed.setIfUnset() {
                        if process.terminationStatus == 0 {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: CLIRunnerError.exitCode(Int(process.terminationStatus)))
                        }
                    }
                } catch {
                    if resumed.setIfUnset() {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

/// Thread-safe one-shot flag to prevent double-resume of continuations.
private final class LockedFlag: @unchecked Sendable {
    private var _value = false
    private let lock = NSLock()

    /// Returns `true` if this call set the flag (i.e., first caller wins).
    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _value { return false }
        _value = true
        return true
    }
}

/// Runs `toki report` CLI and returns JSON output.
final class TokiReportRunner: Sendable {
    private let tokiPath: String

    init(tokiPath: String = TokiPath.resolved) {
        self.tokiPath = tokiPath
    }

    func runReport(
        reportOptions: [String] = [],
        subcommandArgs: [String]
    ) async throws -> Data {
        let args = ["report", "--output-format", "json"] + reportOptions + subcommandArgs
        return try await CLIProcessRunner.run(executable: tokiPath, arguments: args)
    }
}

/// Runs toki settings commands.
final class TokiSettingsRunner: Sendable {
    private let tokiPath: String

    init(tokiPath: String = TokiPath.resolved) {
        self.tokiPath = tokiPath
    }

    /// Get current list of enabled provider IDs.
    func getProviders() async throws -> [String] {
        let output = try await runCommand(["settings", "list"])
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            if line.contains("providers") && line.contains("=") {
                let parts = line.components(separatedBy: "=")
                if parts.count >= 2 {
                    let raw = parts[1].trimmingCharacters(in: .whitespaces)
                    let cleaned = raw
                        .replacingOccurrences(of: "[", with: "")
                        .replacingOccurrences(of: "]", with: "")
                        .replacingOccurrences(of: "\"", with: "")
                    return cleaned.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            }
        }
        return []
    }

    func addProvider(_ id: String) async throws {
        _ = try await runCommand(["settings", "set", "providers", "--add", id])
    }

    func removeProvider(_ id: String) async throws {
        _ = try await runCommand(["settings", "set", "providers", "--remove", id])
    }

    private func runCommand(_ args: [String]) async throws -> String {
        let data = try await CLIProcessRunner.run(executable: tokiPath, arguments: args)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
