import Foundation
import Testing
@testable import TokiMonitor

/// The constitution asks for an integration test of the toki UDS link:
/// "connect, parse NDJSON events, handle disconnection". These tests do that
/// over a real unix socket — `TokiTraceListener` binds, a real client connects
/// and writes bytes, and the assertions are on the `TokenEvent`s that come out
/// of `TokiEventStream` at the far end.
///
/// Every listener here binds a per-test path under `/tmp/toki-monitor-uds-*`.
/// The app's own socket (`/tmp/toki-monitor.sock`) is never bound, and
/// `TokiEventStream.start()` — which pkills by command line and spawns a real
/// `toki trace` — is never called.
@MainActor
@Suite("toki UDS link — a real socket, end to end", .serialized)
struct TokiTraceSocketTests {

    // MARK: - Harness

    @MainActor
    final class Sink {
        var events: [TokenEvent] = []
        var connectedCount = 0
        var disconnectCount = 0
    }

    private static func socketPath() -> String {
        "/tmp/toki-monitor-uds-\(UUID().uuidString.prefix(8)).sock"
    }

    private static func eventLine(model: String, input: Int = 100, output: Int = 50) -> String {
        """
        {"type":"event","data":{"model":"\(model)","source":"s1","input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"cost_usd":0.01}}
        """
    }

    /// Connects a client to a bound unix socket, the way `toki trace --sink uds://…` does.
    private static func connectClient(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { strlcpy(ptr, $0, maxLen) }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return -1 }
        return fd
    }

    @discardableResult
    private static func write(_ text: String, to fd: Int32) -> Bool {
        var bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
            }
            guard n > 0 else { return false }
            written += n
        }
        return true
    }

    /// Polls until `condition` holds or the deadline passes. Socket reads land
    /// on the listener's own queue, so there is nothing to await directly.
    private func wait(upTo seconds: Double = 3.0, for condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Tests

    @Test("A client connects, writes NDJSON, and the events come out the other end")
    func endToEndDelivery() async throws {
        let path = Self.socketPath()
        let listener = TokiTraceListener(socketPath: path)
        let stream = TokiEventStream(listener: listener)
        let sink = Sink()
        stream.onEvent = { sink.events.append($0) }
        stream.onConnected = { sink.connectedCount += 1 }
        stream.onDisconnect = { sink.disconnectCount += 1 }
        defer { listener.stop() }
        defer { withExtendedLifetime(stream) {} }

        #expect(listener.start(), "listener must bind \(path)")
        await wait { sink.connectedCount == 1 }
        #expect(sink.connectedCount == 1)

        let client = Self.connectClient(to: path)
        try #require(client >= 0, "client must connect to \(path)")
        defer { close(client) }

        Self.write(Self.eventLine(model: "claude-opus-4-6", input: 700, output: 300) + "\n", to: client)
        await wait { sink.events.count == 1 }

        #expect(sink.events.count == 1)
        #expect(sink.events.first?.model == "claude-opus-4-6")
        #expect(sink.events.first?.totalTokens == 1000)
        #expect(stream.latestEvent?.model == "claude-opus-4-6")
    }

    @Test("Writes that arrive as separate packets are reassembled across the socket")
    func fragmentedOverSocket() async throws {
        let path = Self.socketPath()
        let listener = TokiTraceListener(socketPath: path)
        let stream = TokiEventStream(listener: listener)
        let sink = Sink()
        stream.onEvent = { sink.events.append($0) }
        defer { listener.stop() }
        defer { withExtendedLifetime(stream) {} }

        #expect(listener.start())
        let client = Self.connectClient(to: path)
        try #require(client >= 0)
        defer { close(client) }

        let full = Self.eventLine(model: "gpt-5.4") + "\n"
        let cut = full.index(full.startIndex, offsetBy: full.count / 2)
        Self.write(String(full[full.startIndex..<cut]), to: client)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(sink.events.isEmpty, "half a line must not produce an event")

        Self.write(String(full[cut...]), to: client)
        await wait { sink.events.count == 1 }
        #expect(sink.events.map(\.model) == ["gpt-5.4"])
    }

    @Test("A client that goes away is reported as a disconnect")
    func clientDisconnect() async throws {
        let path = Self.socketPath()
        let listener = TokiTraceListener(socketPath: path)
        let stream = TokiEventStream(listener: listener)
        let sink = Sink()
        stream.onEvent = { sink.events.append($0) }
        stream.onDisconnect = { sink.disconnectCount += 1 }
        defer { listener.stop() }
        defer { withExtendedLifetime(stream) {} }

        #expect(listener.start())
        let client = Self.connectClient(to: path)
        try #require(client >= 0)

        Self.write(Self.eventLine(model: "a") + "\n", to: client)
        await wait { sink.events.count == 1 }
        #expect(sink.events.count == 1)

        close(client)
        await wait { sink.disconnectCount >= 1 }
        #expect(sink.disconnectCount >= 1, "closing the client must surface as a disconnect")
    }

    @Test("A client reconnecting after a drop is served again")
    func reconnectDelivers() async throws {
        let path = Self.socketPath()
        let listener = TokiTraceListener(socketPath: path)
        let stream = TokiEventStream(listener: listener)
        let sink = Sink()
        stream.onEvent = { sink.events.append($0) }
        stream.onDisconnect = { sink.disconnectCount += 1 }
        defer { listener.stop() }
        defer { withExtendedLifetime(stream) {} }

        #expect(listener.start())

        let first = Self.connectClient(to: path)
        try #require(first >= 0)
        Self.write(Self.eventLine(model: "before") + "\n", to: first)
        await wait { sink.events.count == 1 }
        close(first)
        await wait { sink.disconnectCount >= 1 }

        let second = Self.connectClient(to: path)
        try #require(second >= 0, "the listener must still accept after a drop")
        defer { close(second) }
        Self.write(Self.eventLine(model: "after") + "\n", to: second)
        await wait { sink.events.count == 2 }

        #expect(sink.events.map(\.model) == ["before", "after"])
    }

    @Test("stop() unbinds the socket, and start() can bind it again")
    func stopUnbindsAndRebinds() async throws {
        let path = Self.socketPath()
        let listener = TokiTraceListener(socketPath: path)
        let stream = TokiEventStream(listener: listener)
        defer { withExtendedLifetime(stream) {} }

        #expect(listener.start())
        #expect(FileManager.default.fileExists(atPath: path))

        listener.stop()
        #expect(!FileManager.default.fileExists(atPath: path), "stop() must remove the socket file")
        #expect(Self.connectClient(to: path) < 0, "nothing may connect after stop()")

        #expect(listener.start(), "the same path must be bindable again")
        listener.stop()
    }
}
