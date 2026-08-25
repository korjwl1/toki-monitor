import Foundation
@testable import TokiMonitor

// MARK: - Window row fixtures
//
// The knobs that matter for plan-fit analysis are active time, exhaustion
// timing, coverage and tier — every one of them is a separate axis of the
// verdict, and every one of them is settable here. Exhaustion timing is
// expressed as TIME LEFT rather than time-to-100 on purpose: "ran out with
// 70% of the cycle to go" is the thing under test, and making the caller do
// the subtraction is how a fixture ends up encoding the same off-by-one the
// implementation has.

enum WindowFixtures {

    /// Fixed clock so every fixture is deterministic.
    static let nowMs: Int64 = 1_786_000_000_000

    static let fiveHourMinutes = 300
    static let weeklyMinutes = 10_080

    /// One window row.
    ///
    /// - Parameters:
    ///   - endOffsetDays: how long ago the window ended.
    ///   - activeMs: recorded active time. A LOWER BOUND in production — pass
    ///     0 for "the daemon recorded nothing", which is not the same claim as
    ///     "nothing happened".
    ///   - timeLeftFractionAtExhaustion: share of the cycle still to run when
    ///     the limit was hit. 0.7 = ran out early and spent most of the cycle
    ///     blocked; 0.05 = topped out just before the reset. nil on a maxed
    ///     row means the exhaustion happened but its timing was never sampled
    ///     (`timeTo100Ms == -1`).
    ///   - coverageGapMs: gap between the last sample and the reset. Above
    ///     `WindowStats.coverageGapLimitMs` the peak is a lower bound.
    static func window(
        provider: String = "claude_code",
        kind: String = "session",
        limitId: String? = nil,
        endOffsetDays: Double,
        peakPct: Double,
        activeMs: Int64 = 0,
        maxedOut: Bool = false,
        timeLeftFractionAtExhaustion: Double? = nil,
        finalized: Bool = true,
        coverageGapMs: Int64 = 60_000,
        nSamples: Int = 60,
        plan: String = "max_5x",
        account: String = "acct-1",
        onCredits: Bool = false,
        windowMinutes: Int? = nil,
        nowMs: Int64 = WindowFixtures.nowMs
    ) -> (provider: String, row: WindowRow) {
        let minutes = windowMinutes ?? (kind == "weekly" ? weeklyMinutes : fiveHourMinutes)
        let windowMs = Int64(minutes) * 60_000
        let end = nowMs - Int64(endOffsetDays * 86_400_000)

        let timeTo100: Int64
        if maxedOut, let fraction = timeLeftFractionAtExhaustion {
            timeTo100 = max(0, min(windowMs, windowMs - Int64(fraction * Double(windowMs))))
        } else {
            // -1 is "never reached", and on a maxed row "reached, but we never
            // caught the moment". Neither of those is zero.
            timeTo100 = -1
        }

        let row = WindowRow(
            kind: kind,
            limitId: limitId ?? (kind == "weekly" ? "seven_day" : "five_hour"),
            account: account,
            windowEndMs: end,
            rawResetsAtMs: end,
            windowMinutes: minutes,
            peakPct: peakPct,
            lastPct: peakPct,
            observedTsMs: end - coverageGapMs,
            firstSeenMs: end - windowMs,
            finalized: finalized,
            maxedOut: maxedOut,
            limitReachedKind: maxedOut ? (onCredits ? 2 : 1) : 0,
            timeTo100Ms: timeTo100,
            activeMs: activeMs,
            lastSampleGapMs: coverageGapMs,
            sampledActiveFraction: 1000,
            nSamples: nSamples,
            plan: plan
        )
        return (provider, row)
    }

    // MARK: - The two synthetic accounts from quickstart.md

    /// **Account A — the failure mode this feature exists to prevent.**
    ///
    /// A heavy user whose overall numbers look relaxed. 100 five-hour windows
    /// over 28 days: 70 of them recorded no active time at all (asleep, or the
    /// tail of a session that ran into the night), 30 were worked in, and 20 of
    /// those 30 ran out — mostly EARLY, so most of the cycle was spent blocked.
    ///
    /// Averaged over all 100 windows this account looks like it has room to
    /// spare. Conditioned on the windows it actually worked in, it sits on the
    /// ceiling and gets cut off five times a week.
    static func accountA(
        nowMs: Int64 = WindowFixtures.nowMs,
        provider: String = "claude_code",
        plan: String = "max_5x",
        account: String = "acct-a"
    ) -> [(provider: String, row: WindowRow)] {
        var rows: [(provider: String, row: WindowRow)] = []
        func offset(_ i: Int) -> Double { Double(i) * 27.0 / 99.0 }
        var i = 0

        // 70 barely-touched windows. `activeMs` is 0 and the peak is a
        // trickle: this is what a night looks like, and it is precisely the
        // mass that drags an all-window average down.
        for _ in 0..<70 {
            rows.append(window(provider: provider, endOffsetDays: offset(i), peakPct: 12,
                               activeMs: 0, plan: plan, account: account, nowMs: nowMs))
            i += 1
        }
        // 10 worked windows that did not run out.
        for _ in 0..<10 {
            rows.append(window(provider: provider, endOffsetDays: offset(i), peakPct: 85,
                               activeMs: 2 * 3_600_000, plan: plan, account: account, nowMs: nowMs))
            i += 1
        }
        // 20 worked windows that ran out with most of the cycle still to run.
        for n in 0..<20 {
            rows.append(window(provider: provider, endOffsetDays: offset(i), peakPct: 100,
                               activeMs: 3 * 3_600_000, maxedOut: true,
                               // 0.55…0.74 of the cycle left: hours of being blocked.
                               timeLeftFractionAtExhaustion: 0.55 + Double(n % 20) * 0.01,
                               plan: plan, account: account, nowMs: nowMs))
            i += 1
        }
        return rows
    }

    /// **Account B — the control.**
    ///
    /// Runs out often, but always in the last few minutes of the cycle. The
    /// raw max-out count is higher than account A's; the interruption is not.
    static func accountB(
        nowMs: Int64 = WindowFixtures.nowMs,
        provider: String = "claude_code",
        plan: String = "max_5x",
        account: String = "acct-b"
    ) -> [(provider: String, row: WindowRow)] {
        var rows: [(provider: String, row: WindowRow)] = []
        func offset(_ i: Int) -> Double { Double(i) * 27.0 / 29.0 }
        var i = 0

        for _ in 0..<5 {
            rows.append(window(provider: provider, endOffsetDays: offset(i), peakPct: 90,
                               activeMs: 3 * 3_600_000, plan: plan, account: account, nowMs: nowMs))
            i += 1
        }
        for _ in 0..<25 {
            rows.append(window(provider: provider, endOffsetDays: offset(i), peakPct: 100,
                               activeMs: 4 * 3_600_000, maxedOut: true,
                               // 5% of a five-hour cycle = 15 minutes to reset.
                               timeLeftFractionAtExhaustion: 0.05,
                               plan: plan, account: account, nowMs: nowMs))
            i += 1
        }
        return rows
    }
}
