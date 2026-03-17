import Foundation
import Network

/// Parses NDJSON stream from toki UDS trace connection into TokenEvents.
@MainActor
@Observable
final class TokiEventStream {
    private(set) var latestEvent: TokenEvent?

    private let connection: TokiConnection
    private var activeConnection: NWConnection?
    private var buffer = Data()
    private let decoder = JSONDecoder()

    var onEvent: ((TokenEvent) -> Void)?
    var onDisconnect: (() -> Void)?

    init(connection: TokiConnection = TokiConnection()) {
        self.connection = connection
    }

    func start() {
        activeConnection = connection.connectForTrace(
            onEvent: { [weak self] data in
                Task { @MainActor in
                    self?.handleData(data)
                }
            },
            onError: { [weak self] _ in
                Task { @MainActor in
                    self?.handleDisconnect()
                }
            },
            onComplete: { [weak self] in
                Task { @MainActor in
                    self?.handleDisconnect()
                }
            }
        )
    }

    func stop() {
        activeConnection?.cancel()
        activeConnection = nil
        buffer = Data()
    }

    // MARK: - NDJSON Parsing

    private func handleData(_ data: Data) {
        buffer.append(data)

        // Split on newlines and parse each complete line
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])

            guard !lineData.isEmpty else { continue }

            parseLine(Data(lineData))
        }
    }

    private func parseLine(_ data: Data) {
        guard let envelope = try? decoder.decode(TokiEventEnvelope.self, from: data),
              envelope.type == "event" else {
            return
        }

        let event = TokenEvent(from: envelope.data)
        latestEvent = event
        onEvent?(event)
    }

    private func handleDisconnect() {
        activeConnection = nil
        buffer = Data()
        onDisconnect?()
    }
}
