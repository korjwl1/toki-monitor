import Foundation
import Testing
@testable import TokiMonitor

/// `TokiReportClient` is a thin seam between two halves that can be tested and
/// one that cannot. What it delegates to is here:
///
///  - `CLIProcessRunner.run` — the transport. Every query in the app goes
///    through this one function, so a hang or a swallowed failure here is
///    every panel at once.
///  - `TokiReportParser` — the decode. The client's own `queryPromQL`,
///    `queryModelUsageByProvider` and `queryPromQL(query:time:)` all hand the
///    bytes straight to it.
///
/// What is NOT here is `TokiReportClient`'s own argument assembly. Executable
/// selection has a pure seam and is covered below, but covering the client's
/// full command still means running real `toki` against a live daemon.
///
/// The runner is driven with fixture executables written to a per-test
/// temporary directory — never `toki`, never the daemon socket.
@Suite("The toki CLI transport", .serialized)
struct CLIProcessRunnerTests {

    // MARK: - Fixtures

    /// Writes an executable shell script and returns its path.
    private func script(_ body: String) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toki-cli-fixture-\(UUID().uuidString.prefix(8)))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("fake-toki").path
        try ("#!/bin/bash\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    // MARK: - The happy path

    @Test("stdout comes back byte for byte")
    func stdoutVerbatim() async throws {
        let exe = try script(#"printf '{"providers":{}}'"#)
        let data = try await CLIProcessRunner.run(executable: exe, arguments: [])
        #expect(String(data: data, encoding: .utf8) == #"{"providers":{}}"#)
    }

    @Test("arguments reach the process in order")
    func argumentsArrive() async throws {
        let exe = try script(#"printf '%s\n' "$@""#)
        let data = try await CLIProcessRunner.run(
            executable: exe,
            arguments: ["query", "-z", "UTC", "--output-format", "json", "usage[1h] by (model)"]
        )
        let lines = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        #expect(lines == ["query", "-z", "UTC", "--output-format", "json", "usage[1h] by (model)"])
    }

    // MARK: - The daemon answers an error

    @Test("a refusal on stderr becomes the error's message, not the exit code")
    func refusalMessage() async throws {
        let exe = try script("""
        echo "Error: unexpected trailing input: 'by (region)'" >&2
        exit 1
        """)
        await #expect(throws: CLIRunnerError.self) {
            _ = try await CLIProcessRunner.run(executable: exe, arguments: [])
        }
        do {
            _ = try await CLIProcessRunner.run(executable: exe, arguments: [])
            Issue.record("a non-zero exit must throw")
        } catch let error as CLIRunnerError {
            #expect(error.errorDescription == "Error: unexpected trailing input: 'by (region)'")
        }
    }

    @Test("a silent failure still names its exit code")
    func silentFailure() async throws {
        let exe = try script("exit 3")
        do {
            _ = try await CLIProcessRunner.run(executable: exe, arguments: [])
            Issue.record("a non-zero exit must throw")
        } catch let error as CLIRunnerError {
            #expect(error.errorDescription == "toki exited with code 3")
        }
    }

    @Test("output already written before a failure is not what the caller gets")
    func failureBeatsPartialOutput() async throws {
        // A daemon that prints half a payload and then dies must not look like
        // a successful query that returned half a payload.
        let exe = try script("""
        printf '{"providers":{"claude_code":['
        echo "Error: connection reset" >&2
        exit 1
        """)
        do {
            _ = try await CLIProcessRunner.run(executable: exe, arguments: [])
            Issue.record("a non-zero exit must throw even when stdout has content")
        } catch let error as CLIRunnerError {
            #expect(error.errorDescription == "Error: connection reset")
        }
    }

    // MARK: - The daemon is not there

    @Test("a missing executable throws rather than hanging")
    func missingExecutable() async throws {
        let missing = NSTemporaryDirectory() + "toki-does-not-exist-\(UUID().uuidString)"
        await #expect(throws: (any Error).self) {
            _ = try await CLIProcessRunner.run(executable: missing, arguments: ["query"])
        }
    }

    @Test("a file that exists but is not executable throws rather than hanging")
    func notExecutable() async throws {
        let path = NSTemporaryDirectory() + "toki-not-exec-\(UUID().uuidString)"
        try "not a program".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        await #expect(throws: (any Error).self) {
            _ = try await CLIProcessRunner.run(executable: path, arguments: [])
        }
    }

    // MARK: - Size and deadlock

    @Test("a payload far larger than the pipe buffer arrives whole")
    func largeStdout() async throws {
        // The runner reads stdout before waitUntilExit for exactly this case:
        // a child that fills the 64 KiB pipe blocks forever if the parent is
        // waiting on exit instead of reading.
        let exe = try script(#"for i in $(seq 1 20000); do printf '0123456789012345678901234567890123456789012345678901234567890123\n'; done"#)
        let data = try await CLIProcessRunner.run(executable: exe, arguments: [], timeout: 20)
        #expect(data.count == 20000 * 65, "expected 1.3 MB whole, got \(data.count) bytes")
    }

    @Test("a child that floods stdout and stderr at once does not deadlock")
    func bothPipesFlooded() async throws {
        // stderr is drained on its own queue. Draining them in sequence
        // deadlocks whenever the child fills the pipe nobody is reading yet.
        let exe = try script("""
        for i in $(seq 1 5000); do printf '0123456789012345678901234567890123456789012345678901234567890123\\n'; done
        for i in $(seq 1 5000); do printf 'noise noise noise noise noise noise noise noise\\n' >&2; done
        exit 1
        """)
        do {
            _ = try await CLIProcessRunner.run(executable: exe, arguments: [], timeout: 20)
            Issue.record("a non-zero exit must throw")
        } catch let error as CLIRunnerError {
            // The point is that it returned at all. The last stderr line is
            // noise, and being noise it is under the 300-character cap.
            #expect(error.errorDescription?.hasPrefix("noise") == true)
        }
    }

    // MARK: - Timeout

    @Test("a child that never finishes is cut off, and the call returns")
    func timeoutFires() async throws {
        let exe = try script("sleep 30")
        let started = Date()
        do {
            _ = try await CLIProcessRunner.run(executable: exe, arguments: [], timeout: 0.4)
            Issue.record("a hung child must time out")
        } catch let error as CLIRunnerError {
            guard case .timeout = error else {
                Issue.record("expected .timeout, got \(error)")
                return
            }
            #expect(error.errorDescription == "toki CLI timed out")
        }
        #expect(Date().timeIntervalSince(started) < 10, "the timeout must not wait for the child")
    }

    @Test("a child that finishes inside the timeout is not cut off")
    func timeoutDoesNotFireEarly() async throws {
        let exe = try script("printf 'ok'")
        let data = try await CLIProcessRunner.run(executable: exe, arguments: [], timeout: 10)
        #expect(String(data: data, encoding: .utf8) == "ok")
    }
}

@Suite("Runtime integration isolation")
struct RuntimeIsolationTests {
    @Test("An explicit source binary wins over installed toki copies")
    func sourceBinaryOverrideWins() {
        let resolved = TokiPath.resolve(
            environment: ["TOKI_EXECUTABLE": "/workspace/toki/target/debug/toki"],
            homeDirectory: "/test-home",
            isExecutable: { path in
                path == "/workspace/toki/target/debug/toki"
                    || path == "/opt/homebrew/bin/toki"
            }
        )

        #expect(resolved == "/workspace/toki/target/debug/toki")
    }

    @Test("A missing override falls back to the first executable install path")
    func missingOverrideFallsBack() {
        let resolved = TokiPath.resolve(
            environment: ["TOKI_EXECUTABLE": "/missing/toki"],
            homeDirectory: "/test-home",
            isExecutable: { $0 == "/opt/homebrew/bin/toki" }
        )

        #expect(resolved == "/opt/homebrew/bin/toki")
    }

    @Test("Keychain isolation is opt-in and blank overrides are ignored")
    @MainActor
    func keychainServiceResolution() {
        #expect(SyncClient.keychainService(environment: [:]) == "toki-sync")
        #expect(SyncClient.keychainService(environment: ["TOKI_SYNC_KEYRING_SERVICE": "  "]) == "toki-sync")
        #expect(
            SyncClient.keychainService(
                environment: ["TOKI_SYNC_KEYRING_SERVICE": "toki-sync-integration"]
            ) == "toki-sync-integration"
        )
    }
}

/// The decode half of every `toki query` in the app.
@Suite("toki query output → summaries")
struct TokiReportDecodeTests {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    private static let v2 = """
    {"information":{"type":"query","timezone":"UTC"},
     "providers":{"claude_code":[
       {"period":"2026-03-21T14:00:00","usage_per_models":[
         {"model":"claude-opus-4-6","input_tokens":100,"output_tokens":50,"total_tokens":150,"events":2,"cost_usd":0.25}
       ]}
     ]}}
    """

    @Test("a V2 payload becomes one dated point per period")
    func v2Payload() {
        let points = TokiReportParser.parseReport(data(Self.v2))
        #expect(points.count == 1)
        let models = points.values.first ?? []
        #expect(models.map(\.model) == ["claude-opus-4-6"])
        #expect(models.first?.totalTokens == 150)
        #expect(models.first?.costUsd == 0.25)
    }

    @Test("the period is read as UTC, not as local time")
    func periodIsUTC() {
        let points = TokiReportParser.parseReport(data(Self.v2))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = try! #require(points.keys.first)
        #expect(utc.component(.hour, from: date) == 14)
        #expect(utc.component(.year, from: date) == 2026)
    }

    @Test("providerEntries keeps the provider key that parseReport merges away")
    func providerKeyKept() {
        let both = """
        {"providers":{
          "claude_code":[{"period":"2026-03-21T14:00:00","usage_per_models":[
            {"model":"claude-opus-4-6","input_tokens":1,"output_tokens":1,"total_tokens":2,"events":1,"cost_usd":0.1}]}],
          "codex":[{"period":"2026-03-21T14:00:00","usage_per_models":[
            {"model":"gpt-5.4","input_tokens":1,"output_tokens":1,"total_tokens":2,"events":1,"cost_usd":0.2}]}]
        }}
        """
        let byProvider = TokiReportParser.providerEntries(data(both))
        #expect(Set(byProvider.keys) == ["claude_code", "codex"])

        // parseReport folds them into one dated bucket — which is why the
        // plan-fit path uses providerEntries instead.
        let merged = TokiReportParser.parseReport(data(both))
        #expect(merged.count == 1)
        #expect(merged.values.first?.count == 2)
    }

    @Test("legacy concatenated objects still decode, under no provider name")
    func legacyPayload() {
        let legacy = """
        {"type":"every 1h","data":[{"period":"2026-03-21T14:00:00","usage_per_models":[
          {"model":"claude-opus-4-6","input_tokens":10,"output_tokens":5,"total_tokens":15,"events":1,"cost_usd":0.01}]}]}
        {"type":"every 1h","data":[{"period":"2026-03-21T15:00:00","usage_per_models":[
          {"model":"claude-opus-4-6","input_tokens":20,"output_tokens":5,"total_tokens":25,"events":1,"cost_usd":0.02}]}]}
        """
        let points = TokiReportParser.parseReport(data(legacy))
        #expect(points.count == 2)

        let byProvider = TokiReportParser.providerEntries(data(legacy))
        #expect(Array(byProvider.keys) == [""], "inventing a provider name would be worse than leaving it off")
        #expect(byProvider[""]?.count == 2)
    }

    @Test("[toki] log lines on stdout do not stop the payload decoding")
    func logLinesStripped() {
        let noisy = "[toki] connecting to daemon\n" + Self.v2 + "\n[toki] done\n"
        #expect(TokiReportParser.parseReport(data(noisy)).count == 1)
    }

    @Test("a truncated payload yields nothing rather than a partial answer")
    func truncatedPayload() {
        let cut = String(Self.v2.prefix(Self.v2.count / 2))
        #expect(TokiReportParser.parseReport(data(cut)).isEmpty)
        #expect(TokiReportParser.providerEntries(data(cut)).isEmpty)
    }

    @Test("empty output yields nothing")
    func emptyOutput() {
        #expect(TokiReportParser.parseReport(Data()).isEmpty)
        #expect(TokiReportParser.parseFlatSummaries(Data()).isEmpty)
        #expect(TokiReportParser.providerEntries(Data()).isEmpty)
    }

    @Test("an entry whose period will not parse is skipped, and its neighbours survive")
    func unparseablePeriodSkipped() {
        let mixed = """
        {"providers":{"claude_code":[
          {"period":"not-a-date","usage_per_models":[
            {"model":"a","input_tokens":1,"output_tokens":1,"total_tokens":2,"events":1,"cost_usd":0.1}]},
          {"period":"2026-03-21T14:00:00","usage_per_models":[
            {"model":"b","input_tokens":1,"output_tokens":1,"total_tokens":2,"events":1,"cost_usd":0.1}]}
        ]}}
        """
        let points = TokiReportParser.parseReport(data(mixed))
        #expect(points.count == 1)
        #expect(points.values.first?.map(\.model) == ["b"])
    }

    @Test("a `sum by (model)` total recovers its real name from the period label")
    func totalRecoversLabel() {
        let aggregated = """
        {"providers":{"claude_code":[
          {"period":"2026-03-21T14:00:00|claude-opus-4-6","usage_per_models":[
            {"model":"(total)","input_tokens":1,"output_tokens":1,"total_tokens":2,"events":1,"cost_usd":0.1}]}
        ]}}
        """
        let points = TokiReportParser.parseReport(data(aggregated))
        #expect(points.values.first?.map(\.model) == ["claude-opus-4-6"],
                "leaving it as (total) collapses every series into one")
    }

    @Test("all three period precisions are accepted")
    func periodPrecisions() {
        for period in ["2026-03-21", "2026-03-21T14:00", "2026-03-21T14:00:00"] {
            #expect(TokiReportParser.parseDate(period) != nil, "\(period) must parse")
        }
        #expect(TokiReportParser.parseDate("2026-03-21T14:00:00.123Z") == nil)
    }

    @Test("cost missing from the CLI is estimated, not dropped to zero")
    func costEstimatedWhenAbsent() {
        let noCost = """
        {"providers":{"claude_code":[
          {"period":"2026-03-21T14:00:00","usage_per_models":[
            {"model":"claude-opus-4-6","input_tokens":1000000,"output_tokens":1000000,"total_tokens":2000000,"events":1}]}
        ]}}
        """
        let cost = TokiReportParser.parseReport(data(noCost)).values.first?.first?.costUsd
        #expect((cost ?? 0) > 0, "a million tokens must not report as free")
    }

    @Test("the label is taken from the period, and an empty one is not a label")
    func labelExtraction() {
        #expect(TokiReportParser.extractLabel(from: "2026-03-21T14:00|gpt-5.4") == "gpt-5.4")
        #expect(TokiReportParser.extractLabel(from: "2026-03-21T14:00") == nil)
        #expect(TokiReportParser.extractLabel(from: "2026-03-21T14:00|") == nil)
        #expect(TokiReportParser.extractDateString(from: "2026-03-21T14:00|gpt-5.4") == "2026-03-21T14:00")
    }

    @Test("nested braces do not split one object into two")
    func splitRespectsNesting() {
        let objects = TokiReportParser.splitJsonObjects(#"{"a":{"b":1}}{"c":2}"#)
        #expect(objects == [#"{"a":{"b":1}}"#, #"{"c":2}"#])
    }
}
