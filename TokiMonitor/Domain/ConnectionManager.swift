import Foundation

enum ConnectionState: Equatable {
    case connected
    case disconnected

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
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3

    init(eventStream: TokiEventStream) {
        self.eventStream = eventStream
        eventStream.onConnected = { [weak self] in
            self?.state = .connected
            self?.reconnectAttempts = 0
        }
        eventStream.onDisconnect = { [weak self] in
            self?.eventStream.stop()
            self?.state = .disconnected
            self?.attemptReconnect()
        }
    }

    private func attemptReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            reconnectAttempts = 0
            return
        }
        reconnectAttempts += 1
        let delay = Double(reconnectAttempts) * 3.0 // 3s, 6s, 9s
        Task {
            try? await Task.sleep(for: .seconds(delay))
            let running = await isDaemonRunning()
            if running {
                connect()
            }
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
        eventStream.stop()
        state = .disconnected
    }

    /// Start daemon, then connect.
    func startDaemonAndConnect() {
        Task {
            let launched = await runToki(args: ["daemon", "start"])
            if launched {
                try? await Task.sleep(for: .seconds(1))
                connect()
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

    // MARK: - toki CLI

    /// Check daemon status via `toki daemon status`. Exit code 0 = running.
    private func isDaemonRunning() async -> Bool {
        await runToki(args: ["daemon", "status"])
    }

    /// Run a toki CLI command. Returns true if exit code 0.
    private func runToki(args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: TokiPath.resolved)
                process.arguments = args
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
