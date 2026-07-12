import Foundation

enum ConnectionState: Equatable {
    case connected
    case disconnected
    case starting

    var isConnected: Bool {
        self == .connected
    }
}

/// Manages toki connection lifecycle via CLI commands.
/// - Status: `toki daemon status` (exit 0 = running)
/// - Start:  `toki daemon start`
/// - Trace:  `toki trace --sink uds://`
@MainActor
@Observable
final class ConnectionManager {
    private(set) var state: ConnectionState = .disconnected

    private let eventStream: TokiEventStream
    /// Number of fast (3/6/9s) attempts before falling back to the slow retry.
    private let maxFastAttempts = 3
    /// Interval for the slow persistent retry once fast attempts are exhausted.
    private let slowRetryInterval: TimeInterval = 30
    private var reconnectTask: Task<Void, Never>?

    init(eventStream: TokiEventStream) {
        self.eventStream = eventStream
        eventStream.onConnected = { [weak self] in
            guard let self else { return }
            self.state = .connected
            // Stop any in-flight reconnect loop now that we're up.
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
        }
        eventStream.onDisconnect = { [weak self] in
            self?.eventStream.stop()
            self?.state = .disconnected
            self?.attemptReconnect()
        }
    }

    /// Persistent reconnect loop. Fast backoff (3/6/9s) for the first few
    /// attempts, then a slow steady retry — the monitor is the daemon's lifecycle
    /// manager on this machine, so a daemon that comes back minutes later must
    /// still be picked up. A single loop runs at a time; `onConnected` tears it down.
    private func attemptReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                attempt += 1
                let delay = attempt <= (self?.maxFastAttempts ?? 3)
                    ? Double(attempt) * 3.0
                    : (self?.slowRetryInterval ?? 30)
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, !self.state.isConnected else {
                    self?.reconnectTask = nil
                    return
                }
                if await self.isDaemonRunning() {
                    guard !Task.isCancelled, !self.state.isConnected else {
                        self.reconnectTask = nil
                        return
                    }
                    self.connect()
                    // Give the stream a moment to establish. onConnected cancels this
                    // task on success; if it didn't connect, loop and retry.
                    try? await Task.sleep(for: .seconds(2))
                    if self.state.isConnected {
                        self.reconnectTask = nil
                        return
                    }
                }
                // Daemon still down (or connect didn't take) → keep looping.
            }
            self?.reconnectTask = nil
        }
    }

    /// Check if daemon is running and auto-connect if so.
    func checkAndConnect() {
        Task {
            let running = await isDaemonRunning()
            if running {
                connect()
            }
        }
    }

    func connect() {
        guard !state.isConnected else { return }
        eventStream.start()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        eventStream.stop()
        state = .disconnected
    }

    /// Start daemon, then verify it's running before connecting.
    func startDaemonAndConnect() {
        state = .starting
        Task {
            _ = await runToki(args: ["daemon", "start"])
            // Verify daemon actually started via status check
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(500))
                if await isDaemonRunning() {
                    connect()
                    return
                }
            }
        }
    }

    /// Stop daemon.
    func stopDaemon() {
        Task {
            disconnect()
            _ = await runToki(args: ["daemon", "stop"])
        }
    }

    // MARK: - Public accessors for StatusBarController

    func isDaemonRunningPublic() async -> Bool {
        await isDaemonRunning()
    }

    // MARK: - toki CLI

    /// Check daemon status via `toki daemon status`.
    /// toki always exits 0, so we parse stdout for "is running".
    private func isDaemonRunning() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: TokiPath.resolved)
                process.arguments = ["daemon", "status"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                let resumed = NSLock()
                var didResume = false

                func resumeOnce(value: Bool) {
                    resumed.lock()
                    defer { resumed.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: value)
                }

                do {
                    try process.run()

                    // Timeout: kill the process after 10 seconds
                    let timeoutItem = DispatchWorkItem {
                        if process.isRunning { process.terminate() }
                        resumeOnce(value: false)
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + 10, execute: timeoutItem
                    )

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeoutItem.cancel()

                    let output = String(data: data, encoding: .utf8) ?? ""
                    resumeOnce(value: output.contains("is running"))
                } catch {
                    resumeOnce(value: false)
                }
            }
        }
    }

    /// Run a toki CLI command. Returns true if exit code 0.
    /// Enforces a 15-second timeout to prevent indefinite hang on daemon start/stop.
    private func runToki(args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: TokiPath.resolved)
                process.arguments = args
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                let lock = NSLock()
                var didResume = false
                func resumeOnce(_ value: Bool) {
                    lock.lock(); defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: value)
                }

                do {
                    try process.run()

                    let timeoutItem = DispatchWorkItem {
                        if process.isRunning { process.terminate() }
                        resumeOnce(false)
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeoutItem)

                    process.waitUntilExit()
                    timeoutItem.cancel()
                    resumeOnce(process.terminationStatus == 0)
                } catch {
                    resumeOnce(false)
                }
            }
        }
    }
}
