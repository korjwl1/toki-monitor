import Foundation

/// Parses NDJSON from TokiTraceListener into TokenEvents.
@MainActor
@Observable
final class TokiEventStream {
    private(set) var latestEvent: TokenEvent?

    private let listener: TokiTraceListener
    private var buffer = Data()
    private let decoder = JSONDecoder()

    var onEvent: ((TokenEvent) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnect: (() -> Void)?

    init(listener: TokiTraceListener = TokiTraceListener()) {
        self.listener = listener
        listener.onReady = { [weak self] in
            Task { @MainActor in self?.onConnected?() }
        }
        listener.onData = { [weak self] data in
            Task { @MainActor in self?.handleData(data) }
        }
        listener.onDisconnect = { [weak self] in
            Task { @MainActor in self?.handleDisconnect() }
        }
    }

    func start() {
        // Kill stale toki trace from previous app run
        killStaleTokiTrace()

        guard listener.start() else {
            onDisconnect?()
            return
        }
        launchTokiTrace()
    }

    func stop() {
        tokiProcess?.terminate()
        tokiProcess = nil
        listener.stop()
        buffer = Data()
    }

    // MARK: - toki trace Process

    private var tokiProcess: Process?

    private func launchTokiTrace() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TokiPath.resolved)
        process.arguments = ["trace", "--sink", "uds:///tmp/toki-monitor.sock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleDisconnect() }
        }

        do {
            try process.run()
            tokiProcess = process
        } catch {
            onDisconnect?()
        }
    }

    // MARK: - NDJSON Parsing

    private func handleData(_ data: Data) {
        buffer.append(data)

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

    private func killStaleTokiTrace() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "toki trace --sink uds:///tmp/toki-monitor.sock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func handleDisconnect() {
        tokiProcess?.terminate()
        tokiProcess = nil
        buffer = Data()
        onDisconnect?()
    }
}
