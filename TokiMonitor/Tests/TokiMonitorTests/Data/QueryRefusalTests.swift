import Testing
import Foundation
@testable import TokiMonitor

/// Contract Q2: when a backend refuses a query, the reader sees the reason.
/// Before this, the sync client threw away the response body and raised
/// `HTTP 400`, and the local runner sent the daemon's stderr to `/dev/null` and
/// raised `toki exited with code 1`. In both cases the one sentence naming the
/// unsupported token — the entire point of the server-side fix — was discarded
/// between the socket and the screen.
@Suite("A refused query reaches the reader")
@MainActor
struct QueryRefusalTests {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - The sync server

    @Test("the server's reason survives the HTTP layer verbatim")
    func reasonIsVerbatim() {
        let reason = "unsupported query: `offset` is not supported by the sync backend"
        let error = ServerQueryError.from(
            status: 400, body: body("{\"error\":\"\(reason)\"}")
        )
        #expect(error == .rejected(status: 400, reason: reason))
        #expect(error.errorDescription == reason,
                "no wrapper of ours may replace or truncate the reason")
    }

    @Test("a refusal is not reported as a bare status code")
    func refusalIsNotJustAStatus() {
        let error = ServerQueryError.from(
            status: 400, body: body("{\"error\":\"unsupported query: unknown metric `usge`\"}")
        )
        #expect(error != .httpError(400))
        #expect(error.errorDescription?.contains("usge") == true)
    }

    @Test("a body with nothing to say falls back to the status, not to silence")
    func emptyBodyFallsBack() {
        #expect(ServerQueryError.from(status: 502, body: Data()) == .httpError(502))
        #expect(ServerQueryError.from(status: 500, body: body("{\"error\":\"\"}")) == .httpError(500))
    }

    @Test("an HTML error page from something in front of the server is not shown as a reason")
    func htmlIsNotAReason() {
        let error = ServerQueryError.from(
            status: 502, body: body("<html><body>Bad Gateway</body></html>")
        )
        #expect(error == .httpError(502))
    }

    @Test("a plain-text refusal is still a reason")
    func plainTextReason() {
        let error = ServerQueryError.from(status: 400, body: body("step 1s too small for range"))
        #expect(error == .rejected(status: 400, reason: "step 1s too small for range"))
    }

    // MARK: - The local daemon

    @Test("the daemon's own message is what the failure says")
    func daemonMessage() {
        let stderr = Data("Error: unexpected trailing input: 'by (region)'\n".utf8)
        let message = CLIProcessRunner.stderrMessage(stderr)
        #expect(message == "Error: unexpected trailing input: 'by (region)'")
        #expect(CLIRunnerError.exitCode(1, message: message).errorDescription == message)
    }

    @Test("a silent failure still says something")
    func silentFailure() {
        #expect(CLIProcessRunner.stderrMessage(Data()) == nil)
        #expect(CLIRunnerError.exitCode(1, message: nil).errorDescription == "toki exited with code 1")
    }

    @Test("a log dump is not mistaken for an explanation")
    func longStderrIsIgnored() {
        let noise = Data(String(repeating: "x", count: 400).utf8)
        #expect(CLIProcessRunner.stderrMessage(noise) == nil)
    }

    // MARK: - Refusal vs. failure

    /// The two need different next actions: a refusal is fixed by editing the
    /// query, a network error by trying again.
    @Test("a refusal is distinguishable from a transport failure")
    func refusalIsDistinguishable() {
        let refusal = ServerQueryError.rejected(status: 400, reason: "unsupported query: `avg`")
        #expect(DatasourceRefusal.isRefusal(refusal))
        #expect(DatasourceRefusal.reason(refusal) == "unsupported query: `avg`")

        for other: ServerQueryError in [.networkError("timed out"), .httpError(503), .tokenExpired] {
            #expect(!DatasourceRefusal.isRefusal(other), "\(other) is not the query's fault")
        }
        #expect(DatasourceRefusal.isRefusal(CLIRunnerError.exitCode(1, message: "Error: nope")))
        #expect(!DatasourceRefusal.isRefusal(CLIRunnerError.timeout))
    }
}
