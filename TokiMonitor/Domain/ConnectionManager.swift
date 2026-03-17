import Foundation

enum ConnectionState: Equatable {
    case connected
    case disconnected
    case reconnecting(attempt: Int, maxAttempts: Int)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Manages toki daemon connection lifecycle: connect, reconnect, and daemon launch.
@MainActor
@Observable
final class ConnectionManager {
    private(set) var state: ConnectionState = .disconnected

    private let eventStream: TokiEventStream
    private let maxReconnectAttempts = 3
    private let reconnectInterval: TimeInterval = 5.0
    private var reconnectTask: Task<Void, Never>?

    init(eventStream: TokiEventStream) {
        self.eventStream = eventStream
        eventStream.onDisconnect = { [weak self] in
            self?.handleDisconnect()
        }
    }

    func connect() {
        guard !state.isConnected else { return }
        cancelReconnect()
        eventStream.start()
        state = .connected
    }

    func disconnect() {
        cancelReconnect()
        eventStream.stop()
        state = .disconnected
    }

    /// Launch toki daemon via CLI, then connect.
    func startDaemonAndConnect() {
        Task {
            let launched = await launchDaemon()
            if launched {
                // Give daemon time to create the socket
                try? await Task.sleep(for: .seconds(1))
                connect()
            }
        }
    }

    // MARK: - Reconnect

    private func handleDisconnect() {
        guard state.isConnected else { return }
        eventStream.stop()
        startReconnect()
    }

    private func startReconnect() {
        cancelReconnect()
        state = .reconnecting(attempt: 1, maxAttempts: maxReconnectAttempts)

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1...self.maxReconnectAttempts {
                self.state = .reconnecting(attempt: attempt, maxAttempts: self.maxReconnectAttempts)

                try? await Task.sleep(for: .seconds(self.reconnectInterval))
                guard !Task.isCancelled else { return }

                // Try connecting
                self.eventStream.start()

                // Check if socket exists (simple heuristic)
                let socketExists = FileManager.default.fileExists(
                    atPath: "\(NSHomeDirectory())/.config/toki/daemon.sock"
                )
                if socketExists {
                    self.state = .connected
                    return
                }
                self.eventStream.stop()
            }

            // All attempts failed
            self.state = .disconnected
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Daemon Launch

    private func launchDaemon() async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["toki", "daemon", "start"]
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
