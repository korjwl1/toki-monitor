import Foundation
import Network

/// Low-level UDS connection to toki daemon.
/// Handles connect/disconnect and raw data receive.
final class TokiConnection: Sendable {
    enum ConnectionError: Error, LocalizedError {
        case connectionFailed(String)
        case notConnected
        case sendFailed(String)

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let msg): "Connection failed: \(msg)"
            case .notConnected: "Not connected to toki daemon"
            case .sendFailed(let msg): "Send failed: \(msg)"
            }
        }
    }

    private let socketPath: String
    private let queue = DispatchQueue(label: "com.toki.connection", qos: .utility)

    init(socketPath: String = "\(NSHomeDirectory())/.config/toki/daemon.sock") {
        self.socketPath = socketPath
    }

    /// Create a new NWConnection to the toki UDS.
    func makeConnection() -> NWConnection {
        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        let endpoint = NWEndpoint.unix(path: socketPath)
        return NWConnection(to: endpoint, using: params)
    }

    /// Connect for trace mode (streaming). Does NOT send any data —
    /// the toki daemon classifies silent clients as trace clients after 200ms.
    func connectForTrace(
        onReady: @escaping @Sendable () -> Void,
        onEvent: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) -> NWConnection {
        let connection = makeConnection()

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onReady()
                self.receiveLoop(connection: connection, onData: onEvent, onError: onError, onComplete: onComplete)
            case .failed(let error):
                onError(ConnectionError.connectionFailed(error.localizedDescription))
            case .cancelled:
                onComplete()
            default:
                break
            }
        }

        connection.start(queue: queue)
        return connection
    }

    /// Connect for report mode (request/response). Sends query immediately,
    /// so toki daemon classifies this as a report client.
    func sendReport(
        query: String,
        timezone: String? = nil,
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        let connection = makeConnection()

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = TokiReportRequest(query: query, tz: timezone)
                guard let jsonData = try? JSONEncoder().encode(request),
                      var line = String(data: jsonData, encoding: .utf8) else {
                    completion(.failure(ConnectionError.sendFailed("Failed to encode request")))
                    connection.cancel()
                    return
                }
                line += "\n"

                let conn = connection
                conn.send(
                    content: line.data(using: .utf8),
                    completion: .contentProcessed { error in
                        if let error {
                            completion(.failure(ConnectionError.sendFailed(error.localizedDescription)))
                            conn.cancel()
                            return
                        }
                        // Read single-line response
                        self.receiveOnce(connection: conn, completion: { result in
                            completion(result)
                            conn.cancel()
                        })
                    }
                )

            case .failed(let error):
                completion(.failure(ConnectionError.connectionFailed(error.localizedDescription)))
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    // MARK: - Private

    private func receiveLoop(
        connection: NWConnection,
        onData: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                onData(data)
            }
            if isComplete {
                onComplete()
                return
            }
            if let error {
                onError(error)
                return
            }
            // Continue receiving
            self.receiveLoop(connection: connection, onData: onData, onError: onError, onComplete: onComplete)
        }
    }

    private func receiveOnce(
        connection: NWConnection,
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            if let error {
                completion(.failure(error))
            } else if let data {
                completion(.success(data))
            } else {
                completion(.failure(ConnectionError.notConnected))
            }
        }
    }
}
