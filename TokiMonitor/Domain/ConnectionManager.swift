import Foundation

enum ConnectionState: Equatable {
    case connected
    case disconnected

    var isConnected: Bool {
        self == .connected
    }
}

/// Manages toki connection lifecycle.
/// Starts UDS listener → launches `toki trace --sink uds://` → receives events.
@MainActor
@Observable
final class ConnectionManager {
    private(set) var state: ConnectionState = .disconnected

    private let eventStream: TokiEventStream

    init(eventStream: TokiEventStream) {
        self.eventStream = eventStream
        eventStream.onConnected = { [weak self] in
            self?.state = .connected
        }
        eventStream.onDisconnect = { [weak self] in
            self?.eventStream.stop()
            self?.state = .disconnected
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

    /// Launch toki daemon, then connect.
    func startDaemonAndConnect() {
        Task {
            let launched = await launchDaemon()
            if launched {
                try? await Task.sleep(for: .seconds(1))
                connect()
            }
        }
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
