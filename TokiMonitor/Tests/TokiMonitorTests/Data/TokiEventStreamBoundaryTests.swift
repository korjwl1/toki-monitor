import Foundation
import Testing
@testable import TokiMonitor

/// `TokiEventStream` is the boundary the subordinate constitution calls the
/// highest-risk one in the app: bytes arrive from `toki trace` over a unix
/// socket and become `TokenEvent`s. Nothing downstream can tell the difference
/// between "toki sent nothing" and "we dropped what toki sent", so the failure
/// mode here is silent data loss.
///
/// These tests drive the stream the way the socket does — through the
/// listener's `onData`/`onReady`/`onDisconnect` callbacks, which the stream
/// installs in its own `init` — and assert only on what comes out. The stream's
/// own `start()`/`stop()` are deliberately never called: they `pkill` by
/// command line, spawn a real `toki trace`, and write the process-wide PID file
/// at `/tmp/toki-monitor-trace.pid`, all of which belong to the running app.
@MainActor
@Suite("TokiEventStream — bytes in, events out")
struct TokiEventStreamBoundaryTests {

    // MARK: - Harness

    /// Records what the stream emits, in order.
    @MainActor
    final class Sink {
        var events: [TokenEvent] = []
        var connectedCount = 0
        var disconnectCount = 0
    }

    /// A stream wired to a listener that is never started, so no socket, no
    /// subprocess, and no shared path is involved.
    ///
    /// The stream is a stored property on purpose. Its listener callbacks
    /// capture it weakly, so a stream held only by a local that the optimiser
    /// can release early stops delivering halfway through a test — silently,
    /// which is the very failure these tests are about.
    private let listener: TokiTraceListener
    private let stream: TokiEventStream
    private let sink: Sink

    init() {
        listener = TokiTraceListener(socketPath: "/tmp/toki-monitor-test-\(UUID().uuidString.prefix(8)).sock")
        stream = TokiEventStream(listener: listener)
        sink = Sink()
        stream.onEvent = { [sink] in sink.events.append($0) }
        stream.onConnected = { [sink] in sink.connectedCount += 1 }
        stream.onDisconnect = { [sink] in sink.disconnectCount += 1 }
    }

    /// The stream hops every listener callback onto the main actor with a
    /// `Task`, so the effect is one scheduling turn away.
    private func settle() async {
        for _ in 0..<4 { await Task { @MainActor in }.value }
    }

    private func feed(_ text: String) async {
        listener.onData?(Data(text.utf8))
        await settle()
    }

    private static func line(model: String, source: String = "s1", input: Int = 100, output: Int = 50, cost: Double? = 0.01) -> String {
        var fields = """
        "model":"\(model)","source":"\(source)","input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0
        """
        if let cost { fields += ",\"cost_usd\":\(cost)" }
        return "{\"type\":\"event\",\"data\":{\(fields)}}"
    }

    // MARK: - Delivery

    @Test("A whole line delivers exactly one event, with its fields intact")
    func wholeLine() async {
        await feed(Self.line(model: "claude-opus-4-6", source: "abc123", input: 100, output: 50) + "\n")

        #expect(sink.events.count == 1)
        #expect(sink.events.first?.model == "claude-opus-4-6")
        #expect(sink.events.first?.source == "abc123")
        #expect(sink.events.first?.totalTokens == 150)
        #expect(stream.latestEvent?.model == "claude-opus-4-6")
    }

    @Test("Several lines in one read deliver in arrival order")
    func batchedLines() async {
        let chunk = [
            Self.line(model: "a"), Self.line(model: "b"), Self.line(model: "c"),
        ].joined(separator: "\n") + "\n"
        await feed(chunk)

        #expect(sink.events.map(\.model) == ["a", "b", "c"])
    }

    @Test("A line with no terminating newline is held, not delivered")
    func unterminatedLineIsHeld() async {
        await feed(Self.line(model: "a"))

        // Complete JSON, but the stream cannot know more of the line is not
        // coming until it sees the newline.
        #expect(sink.events.isEmpty)
    }

    // MARK: - Fragmentation

    @Test("A line split across two reads is reassembled")
    func splitAcrossTwoReads() async {
        let full = Self.line(model: "claude-opus-4-6", input: 700, output: 300) + "\n"
        let cut = full.index(full.startIndex, offsetBy: full.count / 2)

        await feed(String(full[full.startIndex..<cut]))
        #expect(sink.events.isEmpty, "half a line must not produce an event")

        await feed(String(full[cut...]))
        #expect(sink.events.count == 1)
        #expect(sink.events.first?.totalTokens == 1000)
    }

    @Test("A line delivered one byte at a time still produces exactly one event")
    func byteAtATime() async {
        let full = Self.line(model: "gpt-5.4", source: "codex-1") + "\n"

        for byte in Array(full.utf8) {
            listener.onData?(Data([byte]))
        }
        await settle()

        #expect(sink.events.count == 1)
        #expect(sink.events.first?.model == "gpt-5.4")
    }

    @Test("A chunk boundary that lands exactly on the newline loses nothing")
    func boundaryOnNewline() async {
        await feed(Self.line(model: "a"))
        await feed("\n" + Self.line(model: "b") + "\n")

        #expect(sink.events.map(\.model) == ["a", "b"])
    }

    @Test("A batch whose tail is a partial line delivers the whole lines and keeps the tail")
    func partialTailIsKept() async {
        let head = Self.line(model: "a") + "\n" + Self.line(model: "b") + "\n"
        let tail = Self.line(model: "c") + "\n"
        let cut = tail.index(tail.startIndex, offsetBy: 10)

        await feed(head + String(tail[tail.startIndex..<cut]))
        #expect(sink.events.map(\.model) == ["a", "b"])

        await feed(String(tail[cut...]))
        #expect(sink.events.map(\.model) == ["a", "b", "c"])
    }

    // MARK: - Bad input must not stop the stream

    @Test("A malformed line does not stop the events after it")
    func malformedLineMidStream() async {
        await feed(Self.line(model: "before") + "\n")
        await feed("{not json at all\n")
        await feed(Self.line(model: "after") + "\n")

        #expect(sink.events.map(\.model) == ["before", "after"])
    }

    @Test("A line with a missing required field is skipped, and the next line still arrives")
    func missingRequiredField() async {
        // No "source" — TokiEventData requires it, so decoding fails.
        await feed(#"{"type":"event","data":{"model":"x","input_tokens":1,"output_tokens":1}}"# + "\n")
        await feed(Self.line(model: "after") + "\n")

        #expect(sink.events.map(\.model) == ["after"])
    }

    @Test("A non-event envelope is ignored")
    func nonEventEnvelopeIgnored() async {
        let summary = Self.line(model: "x").replacingOccurrences(of: "\"type\":\"event\"", with: "\"type\":\"summary\"")
        await feed(summary + "\n")

        #expect(sink.events.isEmpty)
        #expect(stream.latestEvent == nil)
    }

    @Test("Blank lines are skipped without disturbing the stream")
    func blankLinesSkipped() async {
        await feed("\n\n" + Self.line(model: "a") + "\n\n\n" + Self.line(model: "b") + "\n")

        #expect(sink.events.map(\.model) == ["a", "b"])
    }

    @Test("CRLF-terminated lines are parsed")
    func crlfTerminated() async {
        await feed(Self.line(model: "a") + "\r\n" + Self.line(model: "b") + "\r\n")

        #expect(sink.events.map(\.model) == ["a", "b"])
    }

    @Test("A very long malformed run does not swallow the good line that follows it")
    func longGarbageRun() async {
        await feed(String(repeating: "x", count: 100_000) + "\n")
        await feed(Self.line(model: "after") + "\n")

        #expect(sink.events.map(\.model) == ["after"])
    }

    // MARK: - Connection lifecycle

    @Test("onReady from the listener surfaces as onConnected")
    func connectedCallback() async {
        listener.onReady?()
        await settle()

        #expect(sink.connectedCount == 1)
    }

    @Test("A disconnect is reported once")
    func disconnectReported() async {
        listener.onDisconnect?()
        await settle()

        #expect(sink.disconnectCount == 1)
    }

    @Test("A disconnect discards the half-line in flight, so the two halves never fuse")
    func disconnectDiscardsPartialLine() async {
        let full = Self.line(model: "claude-opus-4-6") + "\n"
        let cut = full.index(full.startIndex, offsetBy: full.count / 2)

        await feed(String(full[full.startIndex..<cut]))
        listener.onDisconnect?()
        await settle()
        #expect(sink.disconnectCount == 1)

        // Same bytes the old half was waiting for. If the buffer survived the
        // disconnect they would splice into one valid line — a record that was
        // never sent as such.
        await feed(String(full[cut...]))
        #expect(sink.events.isEmpty)
    }

    @Test("The stream keeps delivering after a reconnect")
    func deliversAfterReconnect() async {
        await feed(Self.line(model: "before") + "\n")

        listener.onDisconnect?()
        await settle()
        listener.onReady?()
        await settle()

        await feed(Self.line(model: "after") + "\n")

        #expect(sink.events.map(\.model) == ["before", "after"])
        #expect(sink.connectedCount == 1)
        #expect(sink.disconnectCount == 1)
    }

    @Test("Several disconnects each report, and delivery survives all of them")
    func repeatedDisconnects() async {
        for i in 0..<3 {
            await feed(Self.line(model: "m\(i)") + "\n")
            listener.onDisconnect?()
            await settle()
        }

        #expect(sink.events.map(\.model) == ["m0", "m1", "m2"])
        #expect(sink.disconnectCount == 3)
    }
}
