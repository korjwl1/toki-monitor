import Testing
import Foundation
@testable import TokiMonitor

/// The verdict layer recommends things about the user's money, so the tests
/// that matter here are the ones that prove it REFUSES: with a short history,
/// with a thin sample, across a tier change, and — the one V6 states outright —
/// on a percentile that was clipped at 100%.
///
/// `@MainActor` for the same reason the active-use suite carries it: the
/// wording reaches `L.tr`, which resolves the language through
/// `MainActor.assumeIsolated` and traps rather than fails off the main actor.
@Suite("Plan fit verdict")
@MainActor
struct PlanFitVerdictTests {

    private let nowMs = WindowFixtures.nowMs

    // MARK: - Local fixtures

    /// `count` windows evenly spread over `spanDays`, newest ending now.
    private func spread(
        count: Int,
        spanDays: Double,
        peakPct: Double,
        activeMs: Int64,
        kind: String = "session",
        coverageGapMs: Int64 = 60_000,
        plan: String = "max_5x",
        account: String = "acct-v",
        maxedOut: Bool = false,
        timeLeftFraction: Double? = nil
    ) -> [(provider: String, row: WindowRow)] {
        (0..<count).map { i in
            let offset = count > 1 ? spanDays * Double(count - 1 - i) / Double(count - 1) : 0
            return WindowFixtures.window(
                kind: kind,
                endOffsetDays: offset,
                peakPct: peakPct,
                activeMs: activeMs,
                maxedOut: maxedOut,
                timeLeftFractionAtExhaustion: timeLeftFraction,
                coverageGapMs: coverageGapMs,
                plan: plan,
                account: account,
                nowMs: nowMs
            )
        }
    }

    private func verdict(_ rows: [(provider: String, row: WindowRow)]) throws -> PlanFitVerdict {
        let verdicts = PlanFitVerdict.evaluateAll(segments: WindowStats.segments(rows: rows, nowMs: nowMs))
        return try #require(verdicts.first)
    }

    private func withheldReason(_ v: PlanFitVerdict) -> WithholdingReason? {
        if case .withheld(let reason, _) = v.outcome { return reason }
        return nil
    }

    private func availability(_ v: PlanFitVerdict) -> VerdictAvailability? {
        if case .withheld(_, let when) = v.outcome { return when }
        return nil
    }

    /// A hand-built segment, for the cases the upstream statistics layer
    /// refuses to produce. Used to prove the verdict layer holds its own bar
    /// rather than trusting `TierAdvice` — which is exactly what V6 asks of it.
    private func segment(
        advice: TierAdvice,
        activeDistribution: UtilisationDistribution,
        maxedCount: Int = 0,
        p95IsCensored: Bool = false,
        cannotTellCount: Int = 0,
        observedDays: Double = 27.5,
        kind: String = "session",
        plan: String = "max_5x"
    ) -> WindowStatsSegment {
        let breakdown = ActiveUseBreakdown(
            active: activeDistribution,
            noActiveUse: .empty,
            cannotTell: UtilisationDistribution(
                count: cannotTellCount, sampledCount: cannotTellCount,
                p50: 5, p90: 5, p95: 5, mean: 5, isCensored: false
            ),
            exhaustions: [],
            interruptionScore: 0,
            interruptionsPerWeek: 0,
            interruptingExhaustionCount: 0,
            harmlessExhaustionCount: 0,
            unknownTimingExhaustionCount: 0,
            medianTimeLeftMs: nil
        )
        return WindowStatsSegment(
            provider: "claude_code",
            kind: kind,
            limitId: kind == "weekly" ? "seven_day" : "five_hour",
            plan: plan,
            account: "acct-h",
            activeWindowCount: activeDistribution.count + cannotTellCount,
            maxedCount: maxedCount,
            medianTimeTo100Sec: nil,
            p50Peak: activeDistribution.p50,
            p90Peak: activeDistribution.p90,
            p95Peak: activeDistribution.p95,
            p95IsCensored: p95IsCensored,
            meanPeakActive: activeDistribution.mean,
            approxOverallMean: nil,
            dutyCycle: 0.3,
            impliedDemandP90: nil,
            sawCreditOverflow: false,
            observedDays: observedDays,
            coveredCount: activeDistribution.sampledCount + cannotTellCount,
            newestWindowEndMs: nowMs,
            activeUse: breakdown,
            advice: advice
        )
    }

    private func distribution(
        count: Int, sampled: Int, p50: Double, p95: Double, censored: Bool
    ) -> UtilisationDistribution {
        UtilisationDistribution(
            count: count, sampledCount: sampled,
            p50: p50, p90: p95, p95: p95, mean: (p50 + p95) / 2,
            isCensored: censored
        )
    }

    // MARK: - T034: history shorter than four cycles (contract V2.1)

    /// The state nearly every user is in today. Ten days of an account that is
    /// visibly being cut off five times a week still produces no verdict — and
    /// the refusal is not an empty value: it carries the reason, the facts we
    /// do have, and the date it stops applying.
    @Test("a history shorter than 28 days produces no verdict, whatever it shows")
    func shortHistoryWithholds() throws {
        // Twenty worked windows in ten days, every one of them running out
        // with most of the cycle still to go: as loud an upgrade signal as the
        // data can carry.
        let rows = spread(
            count: 20, spanDays: 10, peakPct: 100, activeMs: 3 * 3_600_000,
            maxedOut: true, timeLeftFraction: 0.7
        )
        let v = try verdict(rows)

        guard case .withheld(let reason, let when) = v.outcome else {
            Issue.record("ten days of history produced a verdict: \(v.outcome)")
            return
        }
        guard case .historyShorterThanFourCycles(let observed, let required) = reason else {
            Issue.record("wrong withholding reason: \(reason)")
            return
        }
        #expect(required == 28)
        #expect(observed < 11)

        // V1: it says when it stops being withheld.
        guard case .inDays(let days) = when else {
            Issue.record("no availability for a condition that time alone fixes: \(when)")
            return
        }
        #expect(days >= 17 && days <= 19)

        // V1 again: not an error and not empty. The interruptions are on the
        // basis, so the page can still show what was observed.
        #expect(v.basis.interruptionsPerWeek > 2)
        #expect(v.basis.activeWindowCount == 20)
        #expect(v.headroom == nil, "a withheld verdict must not carry a headroom claim")

        // And the refusal renders as a sentence, not a blank.
        let statement = v.statement()
        #expect(!statement.headline.isEmpty)
        #expect(statement.availability != nil)
        #expect(statement.sensitivity == nil)
    }

    /// The boundary: 28 days of the same account does produce one.
    @Test("the same account produces a verdict once the history is long enough")
    func fullHistoryProducesVerdict() throws {
        let v = try verdict(WindowFixtures.accountA(nowMs: nowMs))
        guard case .considerUpgrade(let evidence, let headroom) = v.outcome else {
            Issue.record("account A did not reach an upgrade verdict: \(v.outcome)")
            return
        }
        #expect(evidence.interruptionsPerWeek > 4)
        #expect(evidence.interruptingExhaustions == 20)
        // Every worked window is clipped at 100%: real demand is above the
        // limit, so there is no growth to promise.
        #expect(headroom.readsFromCensoredSample)
        #expect(headroom.isAtCeiling)
        #expect(v.basis.observedDays >= 27)
        #expect(v.basis.activeWindowCount == 30)
    }

    /// Account B runs out more often than A and is not interrupted by it.
    @Test("exhaustion just before the reset does not become an upgrade verdict")
    func lateExhaustionDoesNotUpgrade() throws {
        let v = try verdict(WindowFixtures.accountB(nowMs: nowMs))
        if case .considerUpgrade = v.outcome {
            Issue.record("25 harmless max-outs were read as interruptions")
        }
        guard case .fits = v.outcome else {
            Issue.record("expected the plan to be judged a fit: \(v.outcome)")
            return
        }
        #expect(v.basis.exhaustionCount == 25)
        #expect(v.basis.interruptingExhaustionCount == 0)
    }

    // MARK: - T035: tier or account changed inside the lookback (V2.3)

    @Test("a tier change inside the lookback withholds, and its windows stay out of the basis")
    func tierChangeWithholds() throws {
        // Twenty windows on the old tier, then ten on the new one.
        let old = spread(count: 20, spanDays: 13, peakPct: 30, activeMs: 2 * 3_600_000, plan: "max_5x")
            .map { (provider: $0.provider, row: shifted($0.row, byDays: 14)) }
        let new = spread(count: 10, spanDays: 13, peakPct: 30, activeMs: 2 * 3_600_000, plan: "max_20x")
        let segments = WindowStats.segments(rows: old + new, nowMs: nowMs)
        #expect(segments.count == 2, "a tier change must split the statistics in two")

        let verdicts = PlanFitVerdict.evaluateAll(segments: segments)
        #expect(verdicts.count == 2)
        for v in verdicts {
            guard case .tierOrAccountChanged = withheldReason(v) else {
                Issue.record("a segment survived the tier change: \(v.outcome)")
                continue
            }
        }

        // The old tier's twenty windows are not in the current tier's basis.
        // Percentages against two different limits cannot be one sample.
        let current = try #require(verdicts.first { $0.basis.limitId == "five_hour" && $0.basis.kind == "session" })
        #expect(verdicts.allSatisfy { $0.basis.windowCount == 20 || $0.basis.windowCount == 10 })
        #expect(current.basis.windowCount != 30, "the two tiers were merged into one sample")
    }

    /// An account switch is the same event: the denominator moved.
    @Test("an account switch inside the lookback withholds too")
    func accountSwitchWithholds() throws {
        let a = spread(count: 15, spanDays: 13, peakPct: 30, activeMs: 2 * 3_600_000, account: "acct-1")
            .map { (provider: $0.provider, row: shifted($0.row, byDays: 14)) }
        let b = spread(count: 15, spanDays: 13, peakPct: 30, activeMs: 2 * 3_600_000, account: "acct-2")
        let verdicts = PlanFitVerdict.evaluateAll(segments: WindowStats.segments(rows: a + b, nowMs: nowMs))
        #expect(verdicts.count == 2)
        #expect(verdicts.allSatisfy { if case .tierOrAccountChanged = withheldReason($0) { return true }; return false })
    }

    /// An unidentified plan is strictly worse than a changed one: we cannot
    /// even establish that the denominator held.
    @Test("an unidentified plan withholds and says so")
    func unknownPlanWithholds() throws {
        let rows = spread(count: 20, spanDays: 27, peakPct: 30, activeMs: 2 * 3_600_000, plan: "unknown")
        let v = try verdict(rows)
        #expect(withheldReason(v) == .planUnidentified)
        #expect(availability(v) == .notFromThisData)
    }

    // MARK: - T036: a censored percentile can never support a downgrade (V6)

    /// The statistics layer refuses to mark any of these segments `.downgrade`,
    /// so they are built by hand: the point is that the verdict layer holds the
    /// bar itself rather than trusting the advice it was handed.
    ///
    /// Each case isolates ONE route by which a clipped value could reach the
    /// recommendation, and the control at the end proves the bar is otherwise
    /// reachable — without it, a test like this passes on any implementation
    /// that never downgrades at all.
    @Test("a censored statistic cannot support a downgrade, by any route")
    func censoredStatisticNeverDowngrades() {
        func isDowngrade(_ v: PlanFitVerdict) -> Bool {
            if case .considerDowngrade = v.outcome { return true }
            return false
        }
        func verdictFor(
            _ d: UtilisationDistribution, maxedCount: Int = 0, p95IsCensored: Bool = false
        ) -> PlanFitVerdict {
            PlanFitVerdict.evaluate(
                segment: segment(
                    advice: .downgrade(reason: "handed down"),
                    activeDistribution: d,
                    maxedCount: maxedCount,
                    p95IsCensored: p95IsCensored
                ),
                peers: []
            )
        }

        // 1. The censoring FLAG alone, with a statistic that reads comfortably
        //    low. The flag is what says "every number below is a floor", so it
        //    has to block on its own — today the statistic happens to sit at
        //    100 whenever the flag is set, and a change of percentile would
        //    silently separate them.
        let flagged = distribution(count: 30, sampled: 30, p50: 20, p95: 30, censored: true)
        let flaggedVerdict = verdictFor(flagged)
        if isDowngrade(flaggedVerdict) {
            Issue.record("a distribution flagged as censored was used to recommend paying less")
        }
        #expect(flaggedVerdict.basis.statisticIsLowerBound)

        // 2. The statistic itself at the ceiling, with nothing flagged.
        let atCeiling = distribution(count: 30, sampled: 30, p50: 20, p95: 100, censored: false)
        if isDowngrade(verdictFor(atCeiling)) {
            Issue.record("a statistic clipped at 100% was used to recommend paying less")
        }

        // 3. A max-out anywhere in the segment, with a clean active set.
        let clean = distribution(count: 30, sampled: 30, p50: 20, p95: 30, censored: false)
        if isDowngrade(verdictFor(clean, maxedCount: 3)) {
            Issue.record("a segment that hit its limit was used to recommend paying less")
        }

        // 4. The all-window percentile censored, with a clean active set.
        if isDowngrade(verdictFor(clean, p95IsCensored: true)) {
            Issue.record("a censored all-window percentile was used to recommend paying less")
        }

        // Control: the bar is reachable, so the four cases above are measuring
        // the censoring and not an implementation that simply never downgrades.
        guard isDowngrade(verdictFor(clean)) else {
            Issue.record("the downgrade bar is unreachable, so the censoring cases prove nothing")
            return
        }
    }

    /// Downgrade is stricter than upgrade in ways the upstream gate does not
    /// cover: every worked window must have been observed to its reset, and
    /// the plan must absorb a doubling of the heaviest one.
    @Test("a downgrade needs full coverage of the worked windows and a doubling of margin")
    func downgradeBarIsStricter() {
        let partiallyCovered = distribution(count: 30, sampled: 24, p50: 20, p95: 30, censored: false)
        let a = PlanFitVerdict.evaluate(
            segment: segment(advice: .downgrade(reason: "handed down"), activeDistribution: partiallyCovered),
            peers: []
        )
        if case .considerDowngrade = a.outcome {
            Issue.record("six worked windows of unknown peak were treated as evidence for paying less")
        }

        // 60% of the limit leaves room to grow, but not a doubling.
        let thinMargin = distribution(count: 30, sampled: 30, p50: 40, p95: 60, censored: false)
        let b = PlanFitVerdict.evaluate(
            segment: segment(advice: .downgrade(reason: "handed down"), activeDistribution: thinMargin),
            peers: []
        )
        #expect(PlanFitVerdict.downgradeMinimumGrowthPct == 100)
        if case .considerDowngrade = b.outcome {
            Issue.record("a 67% margin passed a bar that asks for 100%")
        }

        // And an upgrade needs none of this: the same censoring that blocks a
        // downgrade is evidence FOR an upgrade.
        let censored = distribution(count: 30, sampled: 30, p50: 90, p95: 100, censored: true)
        let up = PlanFitVerdict.evaluate(
            segment: segment(advice: .upgrade(reason: "handed down"), activeDistribution: censored, maxedCount: 12),
            peers: []
        )
        guard case .considerUpgrade = up.outcome else {
            Issue.record("censored evidence blocked an upgrade: \(up.outcome)")
            return
        }
    }

    /// End to end, through the real statistics layer.
    @Test("a quiet 28 days of worked windows reaches a downgrade")
    func realDowngradePath() throws {
        let v = try verdict(spread(count: 12, spanDays: 27, peakPct: 30, activeMs: 2 * 3_600_000))
        guard case .considerDowngrade(let headroom) = v.outcome else {
            Issue.record("expected a downgrade: \(v.outcome)")
            return
        }
        #expect(headroom.conservativeGrowthPct > 200)
        #expect(!headroom.readsFromCensoredSample)

        // One max-out in the same 28 days removes it.
        var rows = spread(count: 11, spanDays: 27, peakPct: 30, activeMs: 2 * 3_600_000)
        rows.append(WindowFixtures.window(
            endOffsetDays: 3, peakPct: 100, activeMs: 2 * 3_600_000, maxedOut: true,
            timeLeftFractionAtExhaustion: 0.05, plan: "max_5x", account: "acct-v", nowMs: nowMs
        ))
        let after = try verdict(rows)
        if case .considerDowngrade = after.outcome {
            Issue.record("a segment that hit its limit was still told to pay less")
        }
    }

    // MARK: - T030: headroom comes from the worked windows (contract V4)

    /// The failure mode the whole feature exists to prevent, at the verdict
    /// layer. Read across every window this account has room to spare; read
    /// across the windows it worked in, it is nearly at the ceiling.
    @Test("headroom is read off the worked windows, not off every window")
    func headroomComesFromActiveWindows() throws {
        var rows = spread(count: 120, spanDays: 27, peakPct: 8, activeMs: 0)
        rows += spread(count: 11, spanDays: 26, peakPct: 55, activeMs: 2 * 3_600_000)
        rows.append(WindowFixtures.window(
            endOffsetDays: 1, peakPct: 92, activeMs: 2 * 3_600_000,
            plan: "max_5x", account: "acct-v", nowMs: nowMs
        ))

        let segments = WindowStats.segments(rows: rows, nowMs: nowMs)
        let s = try #require(segments.first)
        // The all-window statistic this must NOT use.
        #expect((s.p95Peak ?? 0) >= 50 && (s.p95Peak ?? 0) < 60)
        #expect(s.activeUse.activeCount == 12)

        let v = try #require(PlanFitVerdict.evaluateAll(segments: segments).first)
        let headroom = try #require(v.headroom)

        // From the worked windows: 92% of the limit, so ~9% of growth.
        #expect(headroom.statisticValue > 90)
        #expect(headroom.conservativeGrowthPct < 15)
        // The all-window reading would have been ~82%. An implementation that
        // used it fails here.
        #expect(headroom.conservativeGrowthPct < 40,
                "headroom was read off the windows nobody worked in")
        #expect(v.basis.activeWindowCount == 12)
        #expect(v.basis.undecidableWindowCount == 120)
    }

    // MARK: - T029: sensitivity, and what a thin sample does to it

    @Test("headroom is a growth band, and a thin sample buys less of it")
    func thinSampleShrinksHeadroom() throws {
        // Eight worked windows, the heaviest at 90% of the limit.
        var thin = spread(count: 7, spanDays: 27, peakPct: 30, activeMs: 2 * 3_600_000)
        thin.append(WindowFixtures.window(
            endOffsetDays: 2, peakPct: 90, activeMs: 2 * 3_600_000,
            plan: "max_5x", account: "acct-v", nowMs: nowMs
        ))
        // Forty worked windows of the same shape, same heaviest window.
        var thick = spread(count: 38, spanDays: 27, peakPct: 30, activeMs: 2 * 3_600_000)
        thick += spread(count: 2, spanDays: 2, peakPct: 90, activeMs: 2 * 3_600_000)

        let thinHeadroom = try #require(try verdict(thin).headroom)
        let thickHeadroom = try #require(try verdict(thick).headroom)

        // Fewer than 20 samples: nearest-rank "p95" IS the maximum, so it is
        // reported as the maximum and the headroom is read off 90%.
        #expect(thinHeadroom.statistic == .observedMaximum)
        #expect(thinHeadroom.statisticValue == 90)
        #expect(thickHeadroom.statistic == .p95)
        #expect(thickHeadroom.statisticValue == 30)
        #expect(thinHeadroom.conservativeGrowthPct < thickHeadroom.conservativeGrowthPct,
                "a thinner sample must not buy more headroom")

        // V3: a band, never a point estimate. The median worked window has
        // more room than the heaviest one.
        #expect(thinHeadroom.typicalGrowthPct > thinHeadroom.conservativeGrowthPct)
    }

    @Test("growth is a floor once it stops being informative")
    func growthIsCapped() {
        let (value, capped) = Headroom.growth(fromUtilisationPct: 0.5)
        #expect(capped)
        #expect(value == Headroom.maxReportableGrowthPct)
        #expect(Headroom.growth(fromUtilisationPct: 100).value == 0)
        #expect(Headroom.growth(fromUtilisationPct: 150).value == 0)
    }

    // MARK: - T031: sample size and coverage (V2.2, V2.4)

    @Test("too few worked windows withholds, and says what it is waiting for")
    func thinSampleWithholds() throws {
        let v = try verdict(spread(count: 5, spanDays: 27, peakPct: 30, activeMs: 2 * 3_600_000))
        guard case .activeSampleTooSmall(let n, let required) = withheldReason(v) else {
            Issue.record("five worked windows produced a verdict: \(v.outcome)")
            return
        }
        #expect(n == 5)
        #expect(required == 8)
        guard case .inDays(let days) = availability(v) else {
            Issue.record("expected an estimate from the observed rate: \(String(describing: availability(v)))")
            return
        }
        #expect(days > 0)
    }

    /// The requirement follows the limit's own cycle. A weekly limit yields
    /// four windows in 28 days and never more, so demanding eight would
    /// withhold the weekly verdict forever.
    @Test("a weekly limit's four windows are a full sample, not a thin one")
    func weeklyRequirementFollowsTheCycle() throws {
        #expect(PlanFitVerdict.requiredActiveWindows(windowMinutes: 10_080) == 4)
        #expect(PlanFitVerdict.requiredActiveWindows(windowMinutes: 300) == 8)

        let rows = spread(count: 4, spanDays: 21, peakPct: 40, activeMs: 10 * 3_600_000, kind: "weekly")
        let v = try verdict(rows)
        #expect(!v.isWithheld, "four complete weeks were treated as an insufficient sample: \(v.outcome)")
        #expect(v.basis.requiredActiveWindows == 4)
        #expect(v.basis.statistic == .observedMaximum)
    }

    @Test("worked windows that were never observed near their reset withhold")
    func lowCoverageMajorityWithholds() throws {
        var rows = spread(count: 5, spanDays: 27, peakPct: 30, activeMs: 2 * 3_600_000)
        rows += spread(count: 7, spanDays: 25, peakPct: 30, activeMs: 2 * 3_600_000,
                       coverageGapMs: 45 * 60_000)
        let v = try verdict(rows)
        guard case .lowCoverageMajority(let sampled, let total) = withheldReason(v) else {
            Issue.record("a sample that is mostly lower bounds produced a verdict: \(v.outcome)")
            return
        }
        #expect(total == 12)
        #expect(sampled == 5)
        #expect(availability(v) == .whenCoverageImproves)
    }

    // MARK: - T032: every verdict carries its basis

    @Test("every outcome, withheld included, carries lookback, sample and statistic")
    func everyVerdictCarriesItsBasis() throws {
        let cases: [[(provider: String, row: WindowRow)]] = [
            spread(count: 20, spanDays: 10, peakPct: 100, activeMs: 3 * 3_600_000,
                   maxedOut: true, timeLeftFraction: 0.7),          // withheld: short history
            spread(count: 5, spanDays: 27, peakPct: 30, activeMs: 2 * 3_600_000),  // withheld: thin
            spread(count: 12, spanDays: 27, peakPct: 30, activeMs: 2 * 3_600_000), // downgrade
            WindowFixtures.accountA(nowMs: nowMs),                                 // upgrade
            WindowFixtures.accountB(nowMs: nowMs)                                  // fits
        ]
        for rows in cases {
            let v = try verdict(rows)
            #expect(v.basis.lookbackDays == 28)
            #expect(v.basis.requiredObservedDays == 28)
            #expect(v.basis.observedDays > 0)
            #expect(v.basis.windowCount > 0)
            #expect(v.basis.requiredActiveWindows > 0)
            let summary = v.statement().basis
            #expect(summary.contains("28"))
            #expect(summary.contains(v.basis.statistic.label))
        }
    }

    // MARK: - V8: headroom is never a guarantee

    @Test("a headroom number cannot be rendered without the sentence that qualifies it")
    func headroomAlwaysCarriesItsCaveat() throws {
        let cases: [[(provider: String, row: WindowRow)]] = [
            spread(count: 12, spanDays: 27, peakPct: 30, activeMs: 2 * 3_600_000),
            WindowFixtures.accountA(nowMs: nowMs),
            WindowFixtures.accountB(nowMs: nowMs)
        ]
        for rows in cases {
            let v = try verdict(rows)
            let statement = v.statement()
            let sensitivity = try #require(statement.sensitivity,
                                           "a verdict with headroom rendered no sensitivity sentence")
            #expect(!sensitivity.sensitivity.isEmpty)
            #expect(!sensitivity.qualifier.isEmpty,
                    "the V8 caveat is separable from the number it qualifies")
            #expect(sensitivity.qualifier.contains("보증") || sensitivity.qualifier.contains("guarantee"))
        }
    }

    // MARK: - V7: no tier names, no prices

    @Test("no statement names a tier or a price")
    func noTierNamesOrPrices() throws {
        let cases: [[(provider: String, row: WindowRow)]] = [
            spread(count: 20, spanDays: 10, peakPct: 100, activeMs: 3 * 3_600_000,
                   maxedOut: true, timeLeftFraction: 0.7),
            spread(count: 12, spanDays: 27, peakPct: 30, activeMs: 2 * 3_600_000),
            WindowFixtures.accountA(nowMs: nowMs)
        ]
        for rows in cases {
            let s = try verdict(rows).statement()
            let text = [s.headline, s.basis, s.availability ?? "",
                        s.sensitivity?.sensitivity ?? "", s.sensitivity?.qualifier ?? ""]
                .joined(separator: " ")
            for forbidden in ["max_5x", "max_20x", "20x", "5x", "Pro", "$", "₩", "USD"] {
                #expect(!text.contains(forbidden), "\"\(forbidden)\" leaked into a verdict statement")
            }
        }
    }

    // MARK: - helpers

    /// Push a row further into the past without rebuilding it.
    private func shifted(_ row: WindowRow, byDays days: Double) -> WindowRow {
        let delta = Int64(days * 86_400_000)
        return WindowRow(
            kind: row.kind, limitId: row.limitId, account: row.account,
            windowEndMs: row.windowEndMs - delta,
            rawResetsAtMs: row.rawResetsAtMs - delta,
            windowMinutes: row.windowMinutes,
            peakPct: row.peakPct, lastPct: row.lastPct,
            observedTsMs: row.observedTsMs - delta,
            firstSeenMs: row.firstSeenMs - delta,
            finalized: row.finalized, maxedOut: row.maxedOut,
            limitReachedKind: row.limitReachedKind,
            timeTo100Ms: row.timeTo100Ms, activeMs: row.activeMs,
            lastSampleGapMs: row.lastSampleGapMs,
            sampledActiveFraction: row.sampledActiveFraction,
            nSamples: row.nSamples, plan: row.plan
        )
    }
}

// MARK: - Subscription comparison (T066…T070 / contract V9)

/// The comparison that mostly refuses itself.
///
/// The property under test is not "the numbers are right" — for every account
/// this product can see, there are no numbers. It is that **the money cannot
/// leave this layer on its own**, that a short lookback produces no
/// calculation at all, and that the refusal names every reason rather than
/// collapsing them into "not enough data".
@Suite("Subscription comparison")
@MainActor
struct SubscriptionComparisonTests {

    private let nowMs = WindowFixtures.nowMs

    private func segments(_ rows: [(provider: String, row: WindowRow)]) -> [WindowStatsSegment] {
        WindowStats.segments(rows: rows, nowMs: nowMs)
    }

    /// 28 days of real history, worked in, with exhaustions — an account that
    /// HAS observed its own limits.
    private var livedUnderLimits: [WindowStatsSegment] {
        segments(WindowFixtures.accountA(nowMs: nowMs))
    }

    // MARK: T068 — below the gate, nothing is calculated

    @Test("a lookback shorter than four cycles performs no calculation")
    func shortLookbackDoesNotCalculate() {
        let rows = (0..<20).map { i in
            WindowFixtures.window(
                endOffsetDays: Double(i) * 0.5, peakPct: 80,
                activeMs: 2 * 3_600_000, nowMs: nowMs
            )
        }
        let result = SubscriptionComparison.evaluate(
            SubscriptionComparison.Input(
                segments: segments(rows),
                // Both halves of the money offered, so the only thing that can
                // stop the calculation is the gate itself.
                notionalPerTokenCostUsd: 400,
                observedSubscriptionPriceUsd: 200,
                perTokenBillingConfirmed: true
            )
        )
        guard case .notCalculated(let reason) = result else {
            Issue.record("10 days of history produced \(result) instead of no calculation")
            return
        }
        guard case .lookbackShorterThanFourCycles(let observed, let required) = reason else {
            Issue.record("wrong reason: \(reason)")
            return
        }
        #expect(required == WindowStats.lookbackDays)
        #expect(observed < required)
    }

    @Test("an account with nothing at all is not calculated either")
    func noHistoryDoesNotCalculate() {
        let result = SubscriptionComparison.evaluate(
            SubscriptionComparison.Input(segments: [])
        )
        #expect(result == .notCalculated(.noHistoryAtAll))
    }

    // MARK: T067 — the refusal, with its reasons

    @Test("an account that never lived under a limit cannot be compared")
    func neverLivedUnderLimits() {
        // 28 days of per-token spend and not one window: the account this
        // question is actually about.
        let result = SubscriptionComparison.evaluate(
            SubscriptionComparison.Input(
                segments: [],
                notionalPerTokenCostUsd: 512.40
            )
        )
        // With no segments AND spend present, the gate is the lookback, which
        // no window history can satisfy — the calculation still never runs,
        // and it still never emits a figure.
        #expect(result != .determined(SubscriptionComparison.Determination(
            money: SubscriptionMoneyDifference(
                perTokenCostUsd: 512.40, subscriptionCostUsd: 0, spanDays: 28
            ),
            exposure: ObservedLimitExposure(
                interruptionCount: 0, harmlessCount: 0, totalWaitMs: 0,
                waitUnknownCount: 0, observedDays: 28, limitCount: 0
            ),
            observedDays: 28
        )))
        if case .determined = result {
            Issue.record("an account with no observed limits produced a determination")
        }
    }

    @Test("a full lookback with no confirmable billing is undeterminable, with every reason")
    func fullLookbackStillUndeterminable() {
        let result = SubscriptionComparison.evaluate(
            SubscriptionComparison.Input(
                segments: livedUnderLimits,
                notionalPerTokenCostUsd: 300
            )
        )
        guard case .undeterminable(let undeterminable) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        // The limits WERE observed here, so that reason must not be given —
        // a refusal that lists reasons it does not have is not a refusal a
        // reader can act on.
        #expect(!undeterminable.reasons.contains(.limitExposureNeverObserved))
        #expect(undeterminable.reasons.contains(.perTokenBillingNotConfirmed))
        #expect(undeterminable.reasons.contains(.subscriptionPriceNotObserved))
        #expect(!undeterminable.reasons.isEmpty)
        #expect(undeterminable.observedDays >= WindowStats.lookbackDays - 1)
        #expect(!undeterminable.whatWouldMakeItPossible.isEmpty)
    }

    @Test("every reason says what was never observed")
    func everyReasonHasWording() {
        for reason in SubscriptionComparison.Reason.allCases {
            #expect(reason.summary.count > 40, "\(reason) has no explanation worth reading")
        }
    }

    // MARK: T066 / T070 — the money never travels alone

    /// The structural claim, stated as a test over every reachable outcome:
    /// a monetary figure exists in exactly one case, and that case also stores
    /// the interruption count and the waiting time.
    @Test("no outcome carries money without the interruptions")
    func moneyNeverTravelsAlone() {
        let inputs: [SubscriptionComparison.Input] = [
            .init(segments: []),
            .init(segments: [], notionalPerTokenCostUsd: 900),
            .init(segments: livedUnderLimits),
            .init(segments: livedUnderLimits, notionalPerTokenCostUsd: 900),
            .init(segments: livedUnderLimits, observedSubscriptionPriceUsd: 200),
            .init(segments: livedUnderLimits, notionalPerTokenCostUsd: 900,
                  perTokenBillingConfirmed: true),
            .init(segments: livedUnderLimits, notionalPerTokenCostUsd: 900,
                  observedSubscriptionPriceUsd: 200),
        ]
        for input in inputs {
            switch SubscriptionComparison.evaluate(input) {
            case .notCalculated, .undeterminable:
                // Neither case has a field a figure could sit in. That is the
                // point: this is checked by the compiler, and asserted here so
                // that adding one to either case fails a test as well.
                continue
            case .determined(let determination):
                #expect(determination.exposure.interruptionCount >= 0)
                #expect(determination.money.perTokenCostUsd > 0)
                Issue.record("an input missing a half still produced a determination")
            }
        }
    }

    /// The one path that does produce a figure produces both halves.
    @Test("a determination carries the money and the interruptions together")
    func determinationCarriesBoth() {
        let result = SubscriptionComparison.evaluate(
            SubscriptionComparison.Input(
                segments: livedUnderLimits,
                notionalPerTokenCostUsd: 900,
                observedSubscriptionPriceUsd: 200,
                perTokenBillingConfirmed: true
            )
        )
        guard case .determined(let determination) = result else {
            Issue.record("expected a determination, got \(result)")
            return
        }
        #expect(determination.money.savingUsd == 700)
        // FR-045 is on the figure by construction.
        #expect(!determination.money.qualifier.isEmpty)
        // Account A ran out of its five-hour limit twenty times, early.
        #expect(determination.exposure.interruptionCount > 0)
        #expect(determination.exposure.totalWaitMs > 0)
        #expect(determination.exposure.interruptionsPerWeek > 0)
        #expect(determination.exposure.summary.contains(
            "\(determination.exposure.interruptionCount)"))
    }

    /// Account B ran out as often as account A but always at the reset, so the
    /// exposure it reports is not an interruption count (contract V5).
    @Test("exhaustions at the reset are not counted as interruptions")
    func resetEdgeExhaustionsAreNotInterruptions() throws {
        let a = try #require(ObservedLimitExposure.fromObservedHistory(
            segments(WindowFixtures.accountA(nowMs: nowMs))))
        let b = try #require(ObservedLimitExposure.fromObservedHistory(
            segments(WindowFixtures.accountB(nowMs: nowMs))))
        #expect(b.harmlessCount > 0)
        #expect(b.interruptionCount < a.interruptionCount,
                "B ran out more often than A and must still show fewer interruptions")
    }

    @Test("an account with no windows has no observed limit exposure")
    func noWindowsNoExposure() {
        #expect(ObservedLimitExposure.fromObservedHistory([]) == nil)
    }

    // MARK: T069 — the tier's size is never a number this code knows

    /// A tier's absolute limit, if one were hardcoded anywhere, would make a
    /// KNOWN tier behave differently from an invented one. Every figure the
    /// comparison and the verdict produce is identical across four plan
    /// strings — two the provider actually mints, one from the other provider,
    /// and one that does not exist.
    @Test("no plan string changes any number")
    func planStringChangesNothing() {
        let plans = ["max_5x", "max_20x", "codex_plus", "plan_that_does_not_exist"]
        var exposures: [ObservedLimitExposure] = []
        var headrooms: [Double] = []
        for plan in plans {
            let rows = WindowFixtures.accountA(nowMs: nowMs, plan: plan)
            let segs = segments(rows)
            exposures.append(ObservedLimitExposure.fromObservedHistory(segs)!)
            for verdict in PlanFitVerdict.evaluateAll(segments: segs) {
                headrooms.append(verdict.headroom?.conservativeGrowthPct ?? -1)
                headrooms.append(verdict.basis.statisticValue ?? -1)
                headrooms.append(Double(verdict.basis.activeWindowCount))
            }
        }
        #expect(Set(exposures).count == 1,
                "the observed exposure moved with the plan string: \(exposures)")
        #expect(Set(headrooms.map { Int($0 * 1000) }).count == headrooms.count / plans.count,
                "a verdict figure moved with the plan string")
    }
}
