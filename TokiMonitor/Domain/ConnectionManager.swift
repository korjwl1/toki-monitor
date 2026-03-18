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
    private var connectionContinuation: CheckedContinuation<Bool, Never>?

    init(eventStream: TokiEventStream) {
        self.eventStream = eventStream
        eventStream.onConnected = { [weak self] in
            self?.handleConnected()
        }
        eventStream.onDisconnect = { [weak self] in
            self?.handleDisconnect()
        }
    }

    func connect() {
        guard !state.isConnected else { return }
        cancelReconnect()
        eventStream.start()
        // State will transition to .connected via onConnected callback
        // If connection fails, onDisconnect will fire instead
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
                try? await Task.sleep(for: .seconds(1))
                connect()
            }
        }
    }

    // MARK: - Connection State Callbacks

    private func handleConnected() {
        cancelReconnect()
        state = .connected
        // Resume any waiting reconnect attempt
        connectionContinuation?.resume(returning: true)
        connectionContinuation = nil
    }

    private func handleDisconnect() {
        let wasConnected = state.isConnected
        eventStream.stop()
        // Resume any waiting reconnect attempt as failed
        connectionContinuation?.resume(returning: false)
        connectionContinuation = nil

        if wasConnected {
            startReconnect()
        }
    }

    // MARK: - Reconnect

    private func startReconnect() {
        cancelReconnect()

        reconnectTask = Task { [weak self] in
            guard let self else { return }

            for attempt in 1...self.maxReconnectAttempts {
                self.state = .reconnecting(attempt: attempt, maxAttempts: self.maxReconnectAttempts)

                try? await Task.sleep(for: .seconds(self.reconnectInterval))
                guard !Task.isCancelled else { return }

                // Try connecting and wait for result via callback
                let connected = await withCheckedContinuation { continuation in
                    self.connectionContinuation = continuation
                    self.eventStream.start()

                    // Timeout after 3 seconds — if no callback fires, treat as failed
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        // If continuation hasn't been resumed yet, fail it
                        self.connectionContinuation?.resume(returning: false)
                        self.connectionContinuation = nil
                    }
                }

                if connected {
                    return // handleConnected already set state = .connected
                }
                self.eventStream.stop()
            }

            self.state = .disconnected
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionContinuation?.resume(returning: false)
        connectionContinuation = nil
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
