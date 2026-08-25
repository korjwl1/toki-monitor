import Testing
import Foundation
@testable import TokiMonitor

/// The user named this failure mode before the feature existed:
///
///   "10x 쓰는데 전체적으론 window를 많이 남기는 편이지만, 그게 잘 때 등등 못 써서
///    그런거고 윈도우 맨날 꽉꽉 채워 써서 작업이 자주 중단되는 사람이면 20x
///    고려해봐야할 수도 있잖아."
///
/// LLM work does not run until the limit is exhausted, because people sleep.
/// So an average over every window measures how much of the day someone spends
/// away from the keyboard and reports it as headroom. And running out ten
/// minutes before the reset is not the same event as being cut off with three
/// hours left.
///
/// Both halves are load-bearing here: account A must reach an upgrade signal
/// on numbers that look relaxed in aggregate, and account B must not reach one
/// on numbers that look alarming in aggregate.
// `@MainActor`: `WindowStats.segments` reaches `L.tr` for advice wording,
// and `L` resolves the language through `MainActor.assumeIsolated`. Swift
// Testing runs off the main actor, so a suite without this traps rather than
// fails — which takes the whole test process down with it.
@Suite("Active use and exhaustion timing")
@MainActor
struct WindowStatsActiveUseTests {

    private let nowMs = WindowFixtures.nowMs

    private func segment(_ rows: [(provider: String, row: WindowRow)]) throws -> WindowStatsSegment {
        try #require(WindowStats.segments(rows: rows, nowMs: nowMs).first)
    }

    private func isUpgrade(_ advice: TierAdvice) -> Bool {
        if case .upgrade = advice { return true }
        return false
    }

    // MARK: - Account A (T012)

    /// Account A leaves most of its plan unused and is still blocked five
    /// times a week, because the unused part is the part it was asleep for.
    @Test("an account that looks relaxed in aggregate still reaches upgrade")
    func accountAReachesUpgradeDespiteLowOverallUtilisation() throws {
        let s = try segment(WindowFixtures.accountA(nowMs: nowMs))

        // Precondition: read across every window, this account looks relaxed.
        // If this stops holding, the test has stopped testing anything.
        #expect((s.approxOverallMean ?? 999) < 40, "fixture no longer looks like an account with headroom")
        #expect((s.meanPeakActive ?? 999) < 45)

        // Conditioned on the windows it actually worked in, it sits on the
        // ceiling. This is the number a verdict is allowed to read (contract
        // V4), and it is where an all-window implementation diverges: the same
        // percentile over all 100 windows is the 12% trickle of a sleeping
        // machine.
        #expect(s.activeUse.activeCount == 30)
        #expect((s.activeUse.active.p50 ?? 0) >= 90)
        #expect(s.activeUse.active.isCensored, "two thirds of the worked windows are clipped at 100%")
        #expect((s.activeUse.cannotTell.p50 ?? 999) < 20,
                "the untouched windows are still here, just not in the active set")

        // The exhaustions cost real time — none of them are eve-of-reset.
        #expect(s.activeUse.exhaustions.count == 20)
        #expect(s.activeUse.harmlessExhaustionCount == 0)
        #expect(s.activeUse.interruptionsPerWeek >= 2)

        #expect(isUpgrade(s.advice),
                "an account blocked every time it works should not read as having headroom: \(s.advice)")
    }

    /// The distributions partition the segment: separating the windows nobody
    /// worked in is not the same as deleting them.
    @Test("the windows nobody worked in are separated, not discarded")
    func accountAKeepsUnworkedWindowsInTheirOwnSet() throws {
        let s = try segment(WindowFixtures.accountA(nowMs: nowMs))
        let breakdown = s.activeUse
        #expect(breakdown.activeCount + breakdown.noActiveUseCount + breakdown.cannotTellCount
                == s.activeWindowCount, "every window belongs to exactly one set")
        #expect(breakdown.cannotTellCount == 70)
        #expect(breakdown.cannotTell.count == 70)
    }

    // MARK: - Account B (T013)

    /// Account B runs out more often than account A and is interrupted less,
    /// because every one of its exhaustions lands minutes before the reset.
    @Test("exhaustion just before the reset is not an upgrade signal")
    func accountBDoesNotReachUpgrade() throws {
        let s = try segment(WindowFixtures.accountB(nowMs: nowMs))

        // Precondition: by raw count this account looks worse than A.
        #expect(s.maxedCount == 25)
        #expect(s.maxedCount > 20)

        // But nothing was actually cut short.
        #expect(s.activeUse.harmlessExhaustionCount == 25)
        #expect(s.activeUse.interruptingExhaustionCount == 0)
        #expect(s.activeUse.interruptionScore == 0)
        #expect(s.activeUse.interruptionsPerWeek == 0)

        #expect(!isUpgrade(s.advice),
                "exhaustion 15 minutes before reset is not interruption: \(s.advice)")
    }

    /// Same account, same number of max-outs, moved earlier in the cycle: now
    /// it is interruption. The only thing that changed is when.
    @Test("the same exhaustion count upgrades once it happens early")
    func timingAloneFlipsTheCall() throws {
        let rows = (0..<25).map { i in
            WindowFixtures.window(
                endOffsetDays: Double(i) * 27.0 / 24.0,
                peakPct: 100, activeMs: 4 * 3_600_000, maxedOut: true,
                timeLeftFractionAtExhaustion: 0.7, nowMs: nowMs
            )
        }
        let s = try segment(rows)
        #expect(s.maxedCount == 25)
        #expect(s.activeUse.interruptingExhaustionCount == 25)
        #expect(isUpgrade(s.advice), "expected upgrade, got \(s.advice)")
    }

    // MARK: - activeMs is a lower bound (T014, contract W1)

    /// The daemon accumulates active time in memory and restarts lose it, so a
    /// small `activeMs` is a floor on the real thing. Asserting "no active
    /// use" from it would let a daemon restart look like a night's sleep.
    @Test("a small activeMs is undecided, never asserted as no active use")
    func smallActiveMsIsNotAssertedAsIdle() throws {
        let barelyRecorded = WindowFixtures.window(endOffsetDays: 1, peakPct: 40, activeMs: 30_000).row
        #expect(WindowStats.activeUse(barelyRecorded) == .cannotTell)

        let nothingRecorded = WindowFixtures.window(endOffsetDays: 1, peakPct: 40, activeMs: 0).row
        #expect(WindowStats.activeUse(nothingRecorded) == .cannotTell,
                "zero recorded active time against a non-zero peak is unknown, not idle")

        // And undecided windows must not be counted into the idle set either —
        // "we could not tell" has to survive all the way to the caller.
        let rows = (0..<20).map { i in
            WindowFixtures.window(endOffsetDays: Double(i), peakPct: 40, activeMs: 30_000, nowMs: nowMs)
        }
        let s = try segment(rows)
        #expect(s.activeUse.cannotTellCount == 20)
        #expect(s.activeUse.noActiveUseCount == 0)
        #expect(s.activeUse.activeCount == 0)
    }

    /// The one thing that CAN establish absence: a provider-reported zero peak
    /// across a well-covered window. That value is persisted on the row, so it
    /// outlives the restart that zeroes `activeMs`.
    @Test("a covered zero peak is the only positive evidence of no use")
    func coveredZeroPeakEstablishesAbsence() {
        let idle = WindowFixtures.window(kind: "weekly", endOffsetDays: 8, peakPct: 0, activeMs: 0).row
        #expect(WindowStats.activeUse(idle) == .noActiveUse)

        // Same zero peak, but the machine slept through most of the cycle: the
        // zero only bounds the part we watched.
        let unobserved = WindowFixtures.window(
            kind: "weekly", endOffsetDays: 8, peakPct: 0, activeMs: 0,
            coverageGapMs: 6 * 3_600_000
        ).row
        #expect(WindowStats.activeUse(unobserved) == .cannotTell)

        // A window with no samples at all establishes nothing.
        let unsampled = WindowFixtures.window(
            kind: "weekly", endOffsetDays: 8, peakPct: 0, activeMs: 0, nSamples: 0
        ).row
        #expect(WindowStats.activeUse(unsampled) == .cannotTell)
    }

    /// Recorded active time above the floor settles it on its own: the value
    /// only ever understates, so clearing the bar is proof.
    @Test("activeMs above the floor is proof of work")
    func activeMsAboveFloorIsProof() {
        let worked = WindowFixtures.window(
            endOffsetDays: 1, peakPct: 3, activeMs: WindowStats.activeUseFloorMs
        ).row
        #expect(WindowStats.activeUse(worked) == .active)
    }

    // MARK: - Time left at exhaustion (T009)

    @Test("time left at exhaustion, and the difference between unknown and zero")
    func timeLeftAtExhaustion() throws {
        let windowMs = Int64(WindowFixtures.fiveHourMinutes) * 60_000

        // Ran out at the 40% mark: 60% of the cycle spent blocked.
        let early = WindowFixtures.window(
            endOffsetDays: 1, peakPct: 100, activeMs: 3_600_000,
            maxedOut: true, timeLeftFractionAtExhaustion: 0.6
        ).row
        #expect(WindowStats.timeLeftAtExhaustionMs(early) == Int64(0.6 * Double(windowMs)))

        // Never reached 100%: there is no such moment.
        let calm = WindowFixtures.window(endOffsetDays: 1, peakPct: 55, activeMs: 3_600_000).row
        #expect(WindowStats.timeLeftAtExhaustionMs(calm) == nil)
        #expect(WindowStats.exhaustionEvent(calm) == nil)

        // Maxed, but no timestamped 100% sample. `timeTo100Ms == -1` means the
        // timing is unknown — reading it as zero would claim the window was
        // exhausted the instant it opened.
        let untimed = WindowFixtures.window(
            endOffsetDays: 1, peakPct: 100, activeMs: 3_600_000,
            maxedOut: true, timeLeftFractionAtExhaustion: nil
        ).row
        #expect(untimed.timeTo100Ms == -1)
        #expect(WindowStats.timeLeftAtExhaustionMs(untimed) == nil)
        let event = try #require(WindowStats.exhaustionEvent(untimed))
        #expect(event.timeLeftMs == nil)
        #expect(event.fractionLeft == nil)
        // It is still a confirmed exhaustion with no evidence it was harmless.
        #expect(event.interruptionWeight == 1)
    }

    // MARK: - Interruption weighting (T011, contract V5)

    @Test("interruption weight ramps with the time the exhaustion cost")
    func interruptionWeightRamp() {
        #expect(WindowStats.interruptionWeight(fractionLeft: 0.0) == 0)
        #expect(WindowStats.interruptionWeight(fractionLeft: 0.10) == 0)
        #expect(abs(WindowStats.interruptionWeight(fractionLeft: 0.30) - 0.5) < 0.0001)
        #expect(WindowStats.interruptionWeight(fractionLeft: 0.50) == 1)
        #expect(WindowStats.interruptionWeight(fractionLeft: 0.95) == 1)
        #expect(WindowStats.interruptionWeight(fractionLeft: nil) == 1,
                "unknown timing is not evidence of a harmless exhaustion")
    }

    // MARK: - In-progress windows (T015, contract W5)

    /// A window still filling has no final peak, no final exhaustion timing
    /// and no settled active time. Letting it into the completed-window
    /// statistics makes today's half-finished cycle look like a completed one
    /// that only ever reached 20%.
    @Test("an in-progress window stays out of the completed-window statistics")
    func inProgressWindowExcluded() throws {
        var rows = (0..<20).map { i in
            WindowFixtures.window(
                endOffsetDays: Double(i) + 1, peakPct: 60, activeMs: 2 * 3_600_000, nowMs: nowMs
            )
        }
        let closedOnly = try segment(rows)

        // The open window is heavy AND exhausted — the shape most likely to
        // move every number if it leaked in.
        rows.append(WindowFixtures.window(
            endOffsetDays: 0, peakPct: 100, activeMs: 4 * 3_600_000,
            maxedOut: true, timeLeftFractionAtExhaustion: 0.8,
            finalized: false, nowMs: nowMs
        ))
        let withOpen = try segment(rows)

        #expect(withOpen.activeWindowCount == closedOnly.activeWindowCount)
        #expect(withOpen.maxedCount == 0)
        #expect(withOpen.activeUse.exhaustions.isEmpty)
        #expect(withOpen.activeUse.interruptionScore == 0)
        #expect(withOpen.activeUse.activeCount == closedOnly.activeUse.activeCount)
        #expect(withOpen.activeUse.active.p95 == closedOnly.activeUse.active.p95)
        #expect(!withOpen.activeUse.active.isCensored)
    }
}
