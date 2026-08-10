import Testing
import Foundation
@testable import TokiMonitor

/// The wire contract with the daemon, and the pure logic layered on top of it.
///
/// A field-name or nullability mismatch here does not crash — it decodes to
/// nothing and the UI silently shows "no data yet", which is why every payload
/// below is a VERBATIM daemon response rather than something hand-written to
/// match the decoder.
@Suite("Windows wire contract")
struct WindowsWireTests {

    /// Captured from `WINDOWS` on a real daemon (2026-08-10). Keep it verbatim:
    /// hand-editing it to match the decoder is how a contract test stops
    /// testing the contract.
    static let realResponse = """
    {"now_ms":1786170000000,"ok":true,"refreshing":false,"schema":1,"providers":{\
    "claude_code":{"auth_status":"ok","current_account":"1b6d3f16bc014a26",\
    "extra_usage_enabled":false,"last_poll_ms":1786169900000,"last_success_ms":1786169900000,\
    "plan":"default_claude_max_5x","polling_enabled":true,"source":"active-poll","windows":[]},\
    "codex":{"auth_status":"ok","current_account":"5f207238e606dac8","source":"passive-extract",\
    "windows":[{"account":"5f207238e606dac8","active_ms":11621999,"finalized":true,\
    "first_seen_ms":1785666092191,"kind":"weekly","last_pct":23.0,"last_sample_gap_ms":239050214,\
    "limit_id":"codex","limit_reached_kind":0,"maxed_out":false,"n_samples":506,\
    "observed_ts_ms":1785921640786,"peak_pct":23.0,"plan":"prolite",\
    "raw_resets_at_ms":1786160691000,"sampled_active_fraction":1000,"time_to_100_ms":-1,\
    "window_end_ms":1786160640000,"window_minutes":10080}]}}}
    """

    @Test("a real daemon response decodes end to end")
    func decodesRealResponse() throws {
        let data = Self.realResponse.data(using: .utf8)!
        let resp = try JSONDecoder().decode(WindowsResponse.self, from: data)

        #expect(resp.ok == true)
        #expect(resp.schema == 1)
        #expect(resp.nowMs == 1_786_170_000_000)

        let codex = try #require(resp.providers?["codex"])
        #expect(codex.authStatus == "ok")
        #expect(codex.currentAccount == "5f207238e606dac8")
        #expect(codex.error == nil)
        #expect(codex.windows.count == 1)

        let row = codex.windows[0]
        #expect(row.limitId == "codex")
        #expect(row.kind == "weekly")
        #expect(row.windowMinutes == 10080)
        #expect(row.peakPct == 23.0)
        #expect(row.lastPct == 23.0)
        #expect(row.finalized == true)
        #expect(row.maxedOut == false)
        #expect(row.activeMs == 11_621_999)
        #expect(row.nSamples == 506)
        #expect(row.plan == "prolite")
        #expect(row.timeTo100Ms == -1)

        // Claude carries the poller-only fields; Codex omits them entirely, so
        // they must be optional rather than defaulted.
        let claude = try #require(resp.providers?["claude_code"])
        #expect(claude.plan == "default_claude_max_5x")
        #expect(claude.pollingEnabled == true)
        #expect(claude.lastSuccessMs == 1_786_169_900_000)
        #expect(codex.pollingEnabled == nil)
        #expect(codex.lastSuccessMs == nil)
    }

    /// A failed keyspace scan arrives as an empty `windows` array PLUS an
    /// error. Without decoding the error the client reads a broken store as an
    /// empty one and paints a full quota bar over it.
    @Test("a storage error is decoded, not mistaken for an empty store")
    func decodesStorageError() throws {
        let json = """
        {"ok":true,"schema":1,"now_ms":1786170000000,"providers":{"codex":{\
        "auth_status":"ok","windows":[],"error":"fjall read failed: io error"}}}
        """
        let resp = try JSONDecoder().decode(WindowsResponse.self, from: json.data(using: .utf8)!)
        let codex = try #require(resp.providers?["codex"])
        #expect(codex.windows.isEmpty)
        #expect(codex.error == "fjall read failed: io error")
    }

    /// Unknown keys must be ignored: the daemon adds response fields (`source`
    /// was added after the client shipped) and an older monitor has to keep
    /// working against a newer daemon.
    @Test("unknown response fields do not break decoding")
    func toleratesUnknownFields() throws {
        let json = """
        {"ok":true,"schema":1,"now_ms":1,"some_future_field":{"a":1},"providers":{"codex":{\
        "auth_status":"ok","windows":[],"another_new_field":"x"}}}
        """
        let resp = try JSONDecoder().decode(WindowsResponse.self, from: json.data(using: .utf8)!)
        #expect(resp.providers?["codex"]?.authStatus == "ok")
    }

    /// `last_pct` postdates the first daemons; a row without it must fall back
    /// to the peak rather than decode-fail or read as zero.
    @Test("livePct falls back to the peak when last_pct is absent")
    func livePctFallsBack() throws {
        let json = """
        {"account":"a","active_ms":0,"finalized":false,"first_seen_ms":0,"kind":"session",\
        "last_sample_gap_ms":0,"limit_id":"five_hour","limit_reached_kind":0,"maxed_out":false,\
        "n_samples":1,"observed_ts_ms":0,"peak_pct":41.5,"plan":"p","raw_resets_at_ms":0,\
        "sampled_active_fraction":1000,"time_to_100_ms":-1,"window_end_ms":0,"window_minutes":300}
        """
        let row = try JSONDecoder().decode(WindowRow.self, from: json.data(using: .utf8)!)
        #expect(row.lastPct == nil)
        #expect(row.livePct == 41.5)
    }

    /// `isOpen` gates the live gauges. A finalized row is never open, and an
    /// unfinalized row whose reset has passed is not open either — otherwise a
    /// stale pre-reset percentage stays frozen on screen after the window
    /// actually reset.
    @Test("isOpen requires both unfinalized and a future reset")
    func isOpenSemantics() {
        let now: Int64 = 1_786_170_000_000
        func row(finalized: Bool, resetsAt: Int64) -> WindowRow {
            WindowRow(
                kind: "session", limitId: "five_hour", account: "a",
                windowEndMs: resetsAt, rawResetsAtMs: resetsAt, windowMinutes: 300,
                peakPct: 10, lastPct: 10, observedTsMs: 0, firstSeenMs: 0,
                finalized: finalized, maxedOut: false, limitReachedKind: 0,
                timeTo100Ms: -1, activeMs: 0, lastSampleGapMs: 0,
                sampledActiveFraction: 1000, nSamples: 1, plan: "p"
            )
        }
        #expect(row(finalized: false, resetsAt: now + 60_000).isOpen(nowMs: now))
        #expect(!row(finalized: true, resetsAt: now + 60_000).isOpen(nowMs: now))
        #expect(!row(finalized: false, resetsAt: now - 60_000).isOpen(nowMs: now))
    }
}

/// Codex reports `primary`/`secondary` as kind SLOTS, not roles: a weekly-first
/// plan puts the 7-day window in `primary`. Consumers treat primary=session and
/// secondary=weekly, so the direct path normalizes — otherwise the HP bar shows
/// the 5-hour window under a "7일" label and one window raises alerts under two
/// different bucket keys depending on which path served it.
@Suite("Codex window slot normalization")
struct CodexSlotNormalizationTests {

    private func window(_ seconds: Int, _ pct: Int) -> CodexUsageWindow {
        CodexUsageWindow(
            usedPercent: pct, limitWindowSeconds: seconds,
            resetAfterSeconds: 60, resetAt: 1_786_170_000
        )
    }

    private func limit(primary: CodexUsageWindow?, secondary: CodexUsageWindow?) -> CodexRateLimit {
        CodexRateLimit(allowed: true, limitReached: false,
                       primaryWindow: primary, secondaryWindow: secondary)
    }

    @Test("a weekly-first plan is swapped so session lands in primary")
    func weeklyFirstIsSwapped() {
        let raw = limit(primary: window(604_800, 30), secondary: window(18_000, 70))
        let n = raw.normalizedBySpan()
        #expect(n.primaryWindow?.limitWindowSeconds == 18_000, "session must be primary")
        #expect(n.secondaryWindow?.limitWindowSeconds == 604_800, "weekly must be secondary")
        #expect(n.primaryWindow?.usedPercent == 70)
        #expect(n.secondaryWindow?.usedPercent == 30)
    }

    @Test("an already-correct plan is left alone")
    func sessionFirstIsUntouched() {
        let raw = limit(primary: window(18_000, 70), secondary: window(604_800, 30))
        let n = raw.normalizedBySpan()
        #expect(n.primaryWindow?.limitWindowSeconds == 18_000)
        #expect(n.secondaryWindow?.limitWindowSeconds == 604_800)
    }

    /// The live case on this machine: Codex stopped issuing the 5-hour window,
    /// so only a weekly one exists. With nothing to compare against, swapping
    /// would move the only window out of `primary` and hide it.
    @Test("a single window is never moved")
    func singleWindowIsNotMoved() {
        let only = limit(primary: window(604_800, 30), secondary: nil)
        #expect(only.normalizedBySpan().primaryWindow?.limitWindowSeconds == 604_800)
        #expect(only.normalizedBySpan().secondaryWindow == nil)

        let onlySecondary = limit(primary: nil, secondary: window(604_800, 30))
        #expect(onlySecondary.normalizedBySpan().primaryWindow == nil)
    }

    @Test("equal spans are left alone rather than swapped arbitrarily")
    func equalSpansAreStable() {
        let raw = limit(primary: window(604_800, 11), secondary: window(604_800, 22))
        let n = raw.normalizedBySpan()
        #expect(n.primaryWindow?.usedPercent == 11)
        #expect(n.secondaryWindow?.usedPercent == 22)
    }
}

/// The scoped weekly limit is per model and its span comes from the data, so
/// the label is built rather than constant. A hardcoded "Sonnet" mislabels
/// every account whose scoped limit is a different model, and a hardcoded
/// "7일" would lie if the endpoint ever scopes a limit to another span.
/// @MainActor because these labels go through `L.tr`, whose `L.code` uses
/// `MainActor.assumeIsolated` — calling it from Swift Testing's default
/// off-main context traps at runtime rather than failing an expectation.
@Suite("Scoped weekly label")
@MainActor
struct ScopedWeeklyLabelTests {

    @Test("model name and span are both taken from the data")
    func labelsFromData() {
        #expect(ScopedWeeklyLabel.make(model: "weekly_fable", windowMinutes: 10080) == "Fable 7일"
             || ScopedWeeklyLabel.make(model: "weekly_fable", windowMinutes: 10080) == "Fable 7d")
        // A multi-word model id keeps its words.
        let two = ScopedWeeklyLabel.make(model: "weekly_claude_next", windowMinutes: 10080)
        #expect(two.hasPrefix("Claude Next"))
    }

    /// The legacy key must still read as Sonnet rather than "Seven Day Sonnet".
    @Test("the legacy seven_day_sonnet key keeps its name")
    func legacyKeyIsHandled() {
        let label = ScopedWeeklyLabel.make(model: "seven_day_sonnet", windowMinutes: 10080)
        #expect(label.hasPrefix("Sonnet"))
    }

    @Test("spans other than a week are rendered honestly")
    func spanVaries() {
        #expect(ScopedWeeklyLabel.span(minutes: 10080) == "7일"
             || ScopedWeeklyLabel.span(minutes: 10080) == "7d")
        #expect(ScopedWeeklyLabel.span(minutes: 300) == "5시간"
             || ScopedWeeklyLabel.span(minutes: 300) == "5h")
        #expect(ScopedWeeklyLabel.span(minutes: 90) == "90분"
             || ScopedWeeklyLabel.span(minutes: 90) == "90m")
    }
}
