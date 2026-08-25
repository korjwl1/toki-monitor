import Foundation

// MARK: - Window statistics (plan-fit analytics)
//
// Pure functions over [WindowRow]. Statistical choices follow cloud
// right-sizing practice (see the design plan §2/§7):
// - trailing 28 days (4 weekly cycles), finalized windows only
// - percentile-of-peaks, never means-of-means
// - 100% windows are right-censored: the recorded 100 is a lower bound on the
//   demand that would have been used. They are counted, and their implied
//   demand is extrapolated from time-to-100. They DO enter the means — a mean
//   that dropped them would understate exactly the heaviest usage — so any
//   mean over a segment with max-outs is itself a lower bound, and is labelled
//   as one in the UI. Percentiles carry the same caveat via `p95IsCensored`.
// - low-coverage windows (big gap between last sample and reset) are lower
//   bounds — they count toward maxed-out but are excluded from percentiles
// - statistics are segmented by plan tier and account: a peak percentage is
//   relative to the tier's limit, so mixing tiers corrupts every number

// MARK: - Active use and exhaustion timing
//
// Two axes decide whether a plan actually fits, and neither of them is the
// overall average a naive reading reaches for first.
//
// 1. Was the window WORKED IN? LLM work does not run until the limit is
//    exhausted — people sleep. Most windows are barely used, so an average
//    over every window reports "plenty of headroom" to someone who is blocked
//    every single time they actually sit down to work.
// 2. WHEN did it exhaust? Being cut off with three hours left is not the same
//    event as topping out ten minutes before the reset. Only the first one
//    interrupted anything.

/// Whether a window contained real work.
///
/// `activeMs` is a LOWER BOUND — the daemon accumulates it in memory and the
/// accumulation restarts with the daemon — so a small value does not prove the
/// window was unused. That is why *absence of work* is a separate state from
/// *inability to tell*: collapsing the two would let a daemon restart
/// masquerade as a night's sleep, and idle windows are exactly what must not
/// dilute the distribution a plan recommendation rests on.
enum ActiveUseClass: String, Equatable, Hashable, Sendable, CaseIterable {
    /// `activeMs` alone clears the floor. Since it only ever understates, this
    /// is proof rather than inference.
    case active
    /// The provider reported zero utilisation across a well-covered window.
    /// `peakPct` is a provider-reported value persisted on the row, so unlike
    /// `activeMs` it survives a daemon restart: a covered zero really is a
    /// window in which nothing was consumed.
    case noActiveUse
    /// Everything else — including a small-but-nonzero `activeMs`. Not "no
    /// use": unknown.
    case cannotTell
}

/// One window that reached 100%, with how much of the cycle was left when it
/// happened.
struct ExhaustionEvent: Equatable, Hashable, Sendable {
    let windowEndMs: Int64
    let windowLengthMs: Int64
    /// `windowMinutes × 60000 − timeToOneHundredMs`, clamped to the window.
    /// nil when the row is maxed but carries no timestamped first-100% sample
    /// (`timeTo100Ms == -1`) — that is unknown timing, NOT zero time left.
    let timeLeftMs: Int64?
    let activeUse: ActiveUseClass
    let hitCredits: Bool

    /// Share of the cycle still to run when the limit was hit, 0…1.
    var fractionLeft: Double? {
        guard let timeLeftMs, windowLengthMs > 0 else { return nil }
        return Double(timeLeftMs) / Double(windowLengthMs)
    }

    /// Contract V5: how much this exhaustion counts as real interruption.
    var interruptionWeight: Double { WindowStats.interruptionWeight(fractionLeft: fractionLeft) }
}

/// Peak-utilisation percentiles over one set of windows.
///
/// Kept as a value so the same shape can describe the active set, the
/// idle set, and the undecidable set side by side — the sets that are not
/// used for headroom are *separated*, never dropped.
struct UtilisationDistribution: Equatable, Hashable, Sendable {
    /// Windows in this set.
    let count: Int
    /// Of those, how many backed the percentiles. Low-coverage windows (the
    /// machine slept through the reset) are lower bounds of unknown looseness
    /// and stay out, but every maxed window is exact at ">=100" regardless.
    let sampledCount: Int
    let p50: Double?
    let p90: Double?
    let p95: Double?
    /// Mean peak over the whole set. A lower bound whenever `isCensored`.
    let mean: Double?
    /// Some samples were clipped at 100%, so the percentiles are floors.
    let isCensored: Bool

    var excludedForCoverage: Int { count - sampledCount }

    static let empty = UtilisationDistribution(
        count: 0, sampledCount: 0, p50: nil, p90: nil, p95: nil,
        mean: nil, isCensored: false
    )
}

/// The active-use split of one segment, plus its exhaustion timing.
struct ActiveUseBreakdown: Equatable, Hashable, Sendable {
    /// Peaks of windows that were actually worked in. **This is the
    /// distribution a plan verdict may use for headroom** (contract V4).
    let active: UtilisationDistribution
    /// Windows positively known to be unused. Separated, not discarded — they
    /// are the honest answer to "how much of the plan goes unused".
    let noActiveUse: UtilisationDistribution
    /// Windows whose `activeMs` was too small to confirm work and whose peak
    /// was not a covered zero. Neither set gets to claim them.
    let cannotTell: UtilisationDistribution

    /// Every exhaustion in the segment, newest last.
    let exhaustions: [ExhaustionEvent]
    /// Σ interruption weight over `exhaustions` (contract V5).
    let interruptionScore: Double
    /// `interruptionScore` per observed week — the rate a verdict compares
    /// against a threshold.
    let interruptionsPerWeek: Double
    /// Exhaustions that weigh at all (weight > 0).
    let interruptingExhaustionCount: Int
    /// Exhaustions inside the last tenth of their cycle — reset was imminent.
    let harmlessExhaustionCount: Int
    /// Maxed windows with no timestamped 100% sample.
    let unknownTimingExhaustionCount: Int
    /// Median time left at exhaustion, ms. nil when no timing is known.
    let medianTimeLeftMs: Int64?

    var activeCount: Int { active.count }
    var noActiveUseCount: Int { noActiveUse.count }
    var cannotTellCount: Int { cannotTell.count }

    static let empty = ActiveUseBreakdown(
        active: .empty, noActiveUse: .empty, cannotTell: .empty,
        exhaustions: [], interruptionScore: 0, interruptionsPerWeek: 0,
        interruptingExhaustionCount: 0, harmlessExhaustionCount: 0,
        unknownTimingExhaustionCount: 0, medianTimeLeftMs: nil
    )
}

/// One statistics segment: same provider, window kind, tier, and account.
struct WindowStatsSegment: Equatable, Hashable {
    let provider: String
    let kind: String            // "session" | "weekly"
    /// Provider limit id ("five_hour", "seven_day", "seven_day_sonnet",
    /// "codex", ...). Segments never mix limit ids: seven_day and
    /// seven_day_sonnet are both "weekly" but measure different limits —
    /// blending them corrupts counts and percentiles alike.
    let limitId: String
    let plan: String
    let account: String

    let activeWindowCount: Int
    let maxedCount: Int
    /// Median time-to-100 of maxed windows, seconds. nil when never maxed.
    let medianTimeTo100Sec: Double?
    /// Peak percentiles over well-covered finalized windows.
    let p50Peak: Double?
    let p90Peak: Double?
    let p95Peak: Double?
    /// p95 is a floor, not an exact value (some windows were censored at 100%).
    let p95IsCensored: Bool
    /// Mean peak over active windows ("사용 중 평균"). A LOWER BOUND whenever
    /// `maxedCount > 0`: censored windows contribute their capped 100, not the
    /// demand they actually had.
    let meanPeakActive: Double?
    /// Calendar-slot approximation of the overall mean for session windows
    /// (28d ≈ 134 five-hour slots; idle slots count as 0). nil for weekly
    /// (weekly windows always exist — meanPeakActive is already the overall mean).
    let approxOverallMean: Double?
    /// Σactive_ms / wall-clock, 0…1.
    let dutyCycle: Double
    /// p90 of implied demand (100 × window / time_to_100) over maxed windows.
    let impliedDemandP90: Double?
    /// Any window continued past 100% on credits/extra usage.
    let sawCreditOverflow: Bool
    /// Days between the oldest and newest finalized window in this segment.
    let observedDays: Double
    /// How many windows actually backed the percentiles. Low-coverage windows
    /// (asleep at reset) are excluded from `peaks`, so this can be far below
    /// `activeWindowCount` — and a percentile over two samples is not evidence
    /// for the one recommendation that costs the user money if wrong.
    let coveredCount: Int
    /// Anchor of the newest window (current-segment detection).
    let newestWindowEndMs: Int64

    /// The two axes a plan verdict actually stands on: which windows were
    /// worked in, and how much of the cycle was left when one ran out.
    /// `activeWindowCount` above is a row-survival count, not this — it means
    /// "rows that were not dropped as noise", and includes windows nobody
    /// touched.
    let activeUse: ActiveUseBreakdown

    let advice: TierAdvice

    func replacingAdvice(_ advice: TierAdvice) -> WindowStatsSegment {
        WindowStatsSegment(
            provider: provider, kind: kind, limitId: limitId, plan: plan, account: account,
            activeWindowCount: activeWindowCount, maxedCount: maxedCount,
            medianTimeTo100Sec: medianTimeTo100Sec,
            p50Peak: p50Peak, p90Peak: p90Peak, p95Peak: p95Peak,
            p95IsCensored: p95IsCensored,
            meanPeakActive: meanPeakActive, approxOverallMean: approxOverallMean,
            dutyCycle: dutyCycle, impliedDemandP90: impliedDemandP90,
            sawCreditOverflow: sawCreditOverflow, observedDays: observedDays,
            coveredCount: coveredCount,
            newestWindowEndMs: newestWindowEndMs, activeUse: activeUse, advice: advice
        )
    }
}

enum TierAdvice: Equatable, Hashable {
    /// Fewer than 14 days observed on this tier — evidence only, no call.
    case collecting(days: Int)
    case upgrade(reason: String)
    case downgrade(reason: String)
    case keep(reason: String)
    /// Plan string unknown/absent: no tier catalog entry to advise against.
    case evidenceOnly
    /// A tier/account the user has since left: numbers stand, advice doesn't.
    case historical
}

enum WindowStats {

    static let lookbackDays: Double = 28
    /// A last-sample gap beyond this means the recorded peak is a lower bound
    /// (machine asleep at reset) — excluded from percentiles.
    static let coverageGapLimitMs: Int64 = 30 * 60_000

    /// Recorded active time at or above which a window counts as worked in.
    ///
    /// The daemon accumulates active time under a 30-minute gap rule, so a
    /// genuine work session registers in minutes, not seconds — and because
    /// `activeMs` only ever understates, clearing this floor is proof. Below
    /// it we cannot separate "one stray background request" from "a long
    /// session the daemon forgot when it restarted", which is exactly what
    /// `.cannotTell` is for.
    ///
    /// The error this floor makes is deliberate. Wrongly admitting an idle
    /// window drags the active distribution down and reports headroom that
    /// isn't there — the failure this whole split exists to prevent. Wrongly
    /// excluding a worked window leaves a smaller sample of worked windows,
    /// which is still a sample of worked windows.
    static let activeUseFloorMs: Int64 = 5 * 60_000

    /// At or below this share of the cycle remaining, an exhaustion carries no
    /// interruption weight: the reset was about to happen anyway.
    static let harmlessExhaustionFractionLeft: Double = 0.10
    /// At or above this share remaining, it counts in full — the rest of the
    /// cycle was spent blocked.
    static let fullInterruptionFractionLeft: Double = 0.50

    // MARK: Active use (contract W1, V4)

    /// Whether one window contained real work.
    ///
    /// Note what is NOT here: no inference from `peakPct` upward. A high peak
    /// with a tiny `activeMs` stays `.cannotTell` rather than being promoted
    /// to `.active`, because the thing we would be inferring — that a human
    /// was working — is the thing `activeMs` exists to report.
    static func activeUse(_ row: WindowRow) -> ActiveUseClass {
        if row.activeMs >= activeUseFloorMs { return .active }
        // A covered zero peak is provider-reported and row-persisted: it
        // outlives the daemon restart that would have zeroed `activeMs`, so
        // it is the one thing that can positively establish absence of work.
        if row.peakPct == 0, row.nSamples > 0, row.lastSampleGapMs <= coverageGapLimitMs {
            return .noActiveUse
        }
        return .cannotTell
    }

    // MARK: Time left at exhaustion (contract V5)

    /// Milliseconds between the first 100% sample and the reset.
    ///
    /// nil when the window never maxed out, and also when it maxed out with
    /// `timeTo100Ms == -1` — no timestamped 100% sample exists, and that is
    /// unknown timing, not zero time left.
    static func timeLeftAtExhaustionMs(_ row: WindowRow) -> Int64? {
        guard row.maxedOut, row.timeTo100Ms >= 0 else { return nil }
        let windowMs = Int64(row.windowMinutes) * 60_000
        guard windowMs > 0 else { return nil }
        return max(0, min(windowMs, windowMs - row.timeTo100Ms))
    }

    static func exhaustionEvent(_ row: WindowRow) -> ExhaustionEvent? {
        guard row.maxedOut else { return nil }
        return ExhaustionEvent(
            windowEndMs: row.windowEndMs,
            windowLengthMs: Int64(row.windowMinutes) * 60_000,
            timeLeftMs: timeLeftAtExhaustionMs(row),
            activeUse: activeUse(row),
            hitCredits: row.limitReachedKind == 2
        )
    }

    /// Contract V5. Linear ramp between the two fractions above.
    static func interruptionWeight(fractionLeft: Double?) -> Double {
        // Unknown timing is a confirmed exhaustion with no evidence that it
        // was harmless. A row goes maxed-without-timing when the first sample
        // we ever took already read 100%, which if anything points at an early
        // exhaustion — so it counts in full rather than being written off.
        guard let fractionLeft else { return 1 }
        let span = fullInterruptionFractionLeft - harmlessExhaustionFractionLeft
        guard span > 0 else { return fractionLeft > harmlessExhaustionFractionLeft ? 1 : 0 }
        return min(1, max(0, (fractionLeft - harmlessExhaustionFractionLeft) / span))
    }

    // MARK: Distributions

    /// Peak percentiles over one set of windows.
    ///
    /// Sampling rule matches the segment-wide one: well-covered windows plus
    /// every maxed window (a maxed row is exact at ">=100" no matter how large
    /// its sample gap).
    static func distribution(_ rows: [WindowRow]) -> UtilisationDistribution {
        guard !rows.isEmpty else { return .empty }
        let sampled = rows.filter { $0.lastSampleGapMs <= coverageGapLimitMs || $0.maxedOut }
        let peaks = sampled.map(\.peakPct).sorted()
        let maxedCount = rows.filter(\.maxedOut).count
        return UtilisationDistribution(
            count: rows.count,
            sampledCount: sampled.count,
            p50: percentile(peaks, 0.5),
            p90: percentile(peaks, 0.9),
            p95: percentile(peaks, 0.95),
            mean: rows.map(\.peakPct).reduce(0, +) / Double(rows.count),
            isCensored: Double(maxedCount) / Double(rows.count) > 0.05
        )
    }

    /// Split one segment's windows by active use and score its exhaustions.
    ///
    /// The three sets partition the input: nothing is dropped. The verdict
    /// layer reads `active` for headroom (V4); the other two exist so the page
    /// can say how much of the plan went unused and how much we could not
    /// account for, which is a different question from the same rows.
    static func activeUseBreakdown(rows: [WindowRow], observedDays: Double) -> ActiveUseBreakdown {
        guard !rows.isEmpty else { return .empty }

        var active: [WindowRow] = []
        var idle: [WindowRow] = []
        var unclear: [WindowRow] = []
        for row in rows {
            switch activeUse(row) {
            case .active: active.append(row)
            case .noActiveUse: idle.append(row)
            case .cannotTell: unclear.append(row)
            }
        }

        // Exhaustion is scored over EVERY maxed window, not only the active
        // ones. Reaching 100% of a rate limit is provider-reported consumption
        // — it is itself evidence that work happened — so filtering exhaustions
        // by the lower-bound `activeMs` would discard real interruptions on the
        // strength of a number we already know understates. (A maxed window can
        // never classify as `.noActiveUse` anyway: that requires a zero peak.)
        let exhaustions = rows
            .sorted { $0.windowEndMs < $1.windowEndMs }
            .compactMap(exhaustionEvent)

        let score = exhaustions.reduce(0.0) { $0 + $1.interruptionWeight }
        let weeks = max(observedDays / 7, 1)
        let timesLeft = exhaustions.compactMap(\.timeLeftMs).sorted()
        let medianLeft = percentile(timesLeft.map(Double.init), 0.5).map { Int64($0) }

        return ActiveUseBreakdown(
            active: distribution(active),
            noActiveUse: distribution(idle),
            cannotTell: distribution(unclear),
            exhaustions: exhaustions,
            interruptionScore: score,
            interruptionsPerWeek: score / weeks,
            interruptingExhaustionCount: exhaustions.filter { $0.interruptionWeight > 0 }.count,
            harmlessExhaustionCount: exhaustions.filter { $0.interruptionWeight == 0 }.count,
            unknownTimingExhaustionCount: exhaustions.filter { $0.timeLeftMs == nil }.count,
            medianTimeLeftMs: medianLeft
        )
    }

    /// Compute all segments from raw rows (any providers/kinds mixed).
    /// `nowMs` is injectable for tests.
    static func segments(
        rows: [(provider: String, row: WindowRow)],
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> [WindowStatsSegment] {
        let cutoff = nowMs - Int64(lookbackDays * 86_400_000)
        let eligible = rows.filter { $0.row.finalized && $0.row.windowEndMs >= cutoff }

        // Current tier/account per (provider, kind, limit) — considers OPEN
        // rows too: right after a plan change the newest finalized row still
        // belongs to the old tier (for weekly limits up to 7 days), and advice
        // against an abandoned tier is noise.
        // Keyed on the last time a row was actually SAMPLED, not on its
        // anchor: after an account switch both accounts have open rows with
        // independent anchors, and the abandoned one's anchor can be later —
        // which would emit advice for the account the user just left.
        // observedTsMs freezes for the abandoned account, so it discriminates.
        var currentSegmentKey: [String: (plan: String, account: String, seenMs: Int64)] = [:]
        for (provider, row) in rows where row.windowEndMs >= cutoff {
            let key = [provider, row.kind, row.limitId].joined(separator: "|")
            if row.observedTsMs > (currentSegmentKey[key]?.seenMs ?? 0) {
                currentSegmentKey[key] = (row.plan, row.account, row.observedTsMs)
            }
        }

        var groups: [String: [(String, WindowRow)]] = [:]
        for (provider, row) in eligible {
            let key = [provider, row.kind, row.limitId, row.plan, row.account].joined(separator: "|")
            groups[key, default: []].append((provider, row))
        }

        var segments = groups.values.compactMap { group -> WindowStatsSegment? in
            guard let first = group.first else { return nil }
            let rows = group.map(\.1)
            return segment(
                provider: first.0,
                kind: first.1.kind,
                limitId: first.1.limitId,
                plan: first.1.plan,
                account: first.1.account,
                rows: rows,
                nowMs: nowMs
            )
        }

        // Advice applies only to the CURRENT tier/account segment (the one
        // containing the newest window per provider+kind); historical segments
        // keep their numbers but show evidence only — recommending against a
        // tier the user already left is noise (plan §2 tier gating).
        segments = segments.map { s in
            let key = "\(s.provider)|\(s.kind)|\(s.limitId)"
            if let current = currentSegmentKey[key],
               s.plan != current.plan || s.account != current.account {
                // Historical, not unknown — the plan is right there on the card.
                return s.replacingAdvice(.historical)
            }
            return s
        }
        return segments.sorted { ($0.provider, $0.kind, $0.limitId) < ($1.provider, $1.kind, $1.limitId) }
    }

    static func segment(
        provider: String,
        kind: String,
        limitId: String,
        plan: String,
        account: String,
        rows: [WindowRow],
        nowMs: Int64
    ) -> WindowStatsSegment? {
        // Sample definition differs by kind. Session windows only exist while
        // used, so zero rows are noise. Weekly windows always exist — the
        // Claude poller records genuine zero-use weeks, and DROPPING them
        // biases the weekly mean and percentiles upward (a fully idle account
        // would lose its segment entirely).
        let active = kind == "weekly"
            ? rows
            : rows.filter { $0.activeMs > 0 || $0.peakPct > 0 }
        guard !active.isEmpty else { return nil }

        let maxed = active.filter(\.maxedOut)
        // Percentile sample: well-covered windows PLUS every maxed window —
        // a maxed row is exact at \">=100\" no matter how large its sample
        // gap (dropping 100% rows for low coverage computed p95=30 against a
        // true p95 of 100). Low-coverage non-maxed rows stay excluded: their
        // peaks are lower bounds of unknown looseness.
        let wellCovered = active.filter { $0.lastSampleGapMs <= coverageGapLimitMs || $0.maxedOut }
        let peaks = wellCovered.map(\.peakPct).sorted()
        let censoredFraction = Double(maxed.count) / Double(active.count)

        let t100s = maxed
            .map { Double($0.timeTo100Ms) / 1000 }
            .filter { $0 > 0 }
            .sorted()
        let implied = maxed.compactMap { row -> Double? in
            guard row.timeTo100Ms > 0 else { return nil }
            let windowMs = Double(row.windowMinutes) * 60_000
            return 100.0 * windowMs / Double(row.timeTo100Ms)
        }.sorted()

        let oldest = active.map(\.windowEndMs).min() ?? nowMs
        let newest = active.map(\.windowEndMs).max() ?? nowMs
        // End-anchor span PLUS one window length: four weekly windows covering
        // 28 days have anchors only 21 days apart, which under-counted the
        // observation period (and delayed the 28-day downgrade gate).
        let windowLenMs = Int64((active.first?.windowMinutes ?? 0)) * 60_000
        // Capped at the lookback: a boundary weekly anchor plus one window
        // length can read 35 days, deflating per-week rates by ~20%.
        let observedDays = min(
            Double(newest - oldest + windowLenMs) / 86_400_000,
            lookbackDays
        )

        let meanPeakActive = active.isEmpty
            ? nil
            : active.map(\.peakPct).reduce(0, +) / Double(active.count)

        // Session windows exist only while used; approximate the overall mean
        // against the calendar slot count. Weekly windows always exist, so the
        // active mean IS the overall mean (approx nil to avoid double-reporting).
        // Calendar-slot approximation. Sessions only exist while used, so the
        // slot count comes from the calendar. Weekly rows are usually
        // complete — but a passive provider (Codex) never records a zero-use
        // week, so when fewer rows exist than the calendar implies, report the
        // same approximation instead of an active-only mean masquerading as
        // the overall one.
        var approxOverall: Double? = nil
        if let windowMinutes = active.first?.windowMinutes, windowMinutes > 0 {
            // Slots span what was actually OBSERVED, not always 28 days: a
            // fresh install with two consecutive weekly rows covers 14 days,
            // and dividing by four slots halved its overall mean (a 3-day-old
            // install's session mean was diluted ~9×).
            let spanDays = max(min(lookbackDays, observedDays), 0)
            let slots = max(spanDays * 24 * 60 / Double(windowMinutes), 1)
            let peakSum = active.reduce(0.0) { $0 + $1.peakPct }
            if kind == "session" || Double(active.count) < slots - 0.5 {
                approxOverall = peakSum / slots
            }
        }

        // Wall clock from the OLDEST WINDOW'S START (not its end): dividing
        // four windows' activity by an end-to-now span overstated duty cycle
        // by up to one window length.
        // Anchored to the segment's own end, not `now`: an abandoned tier's
        // duty cycle was diluted by every idle day since the switch.
        let wallMs = min(
            Int64(lookbackDays * 86_400_000),
            max(min(nowMs, newest) - (oldest - windowLenMs), 1)
        )
        // Double accumulation: Int64 summation of wire-supplied values can
        // trap on overflow, and a single bad row would then crash this view
        // every time it opened.
        let totalActiveMs = active.reduce(0.0) { $0 + Double($1.activeMs) }
        let dutyCycle = min(1.0, totalActiveMs / Double(wallMs))

        let medianT100 = percentile(t100s, 0.5)
        let breakdown = activeUseBreakdown(rows: active, observedDays: observedDays)
        let seg = WindowStatsSegment(
            provider: provider,
            kind: kind,
            limitId: limitId,
            plan: plan,
            account: account,
            activeWindowCount: active.count,
            maxedCount: maxed.count,
            medianTimeTo100Sec: medianT100,
            p50Peak: percentile(peaks, 0.5),
            p90Peak: percentile(peaks, 0.9),
            p95Peak: percentile(peaks, 0.95),
            p95IsCensored: censoredFraction > 0.05,
            meanPeakActive: meanPeakActive,
            approxOverallMean: approxOverall,
            dutyCycle: dutyCycle,
            impliedDemandP90: percentile(implied, 0.9),
            sawCreditOverflow: active.contains { $0.limitReachedKind == 2 },
            observedDays: observedDays,
            coveredCount: wellCovered.count,
            newestWindowEndMs: newest,
            activeUse: breakdown,
            advice: .evidenceOnly // placeholder, replaced below
        )
        return withAdvice(seg)
    }

    /// Advice rules mirror cloud right-sizing asymmetry: eager on upgrade
    /// evidence, deliberately conservative on downgrade (flap prevention).
    private static func withAdvice(_ s: WindowStatsSegment) -> WindowStatsSegment {
        var advice: TierAdvice

        if s.plan.isEmpty || s.plan == "unknown" {
            advice = .evidenceOnly
        } else if s.observedDays < 14 {
            advice = .collecting(days: Int(s.observedDays.rounded(.down)))
        } else {
            // Interruptions, not max-outs. A window that tops out ten
            // minutes before its reset blocked nothing, and counting it the
            // same as one that died with three hours left is what makes a
            // "hitting the limit constantly" reading out of a plan that fits.
            // Contract V5 weights each exhaustion by the time it cost.
            let interruptionsPerWeek = s.activeUse.interruptionsPerWeek
            let windowMinutes: Double = s.kind == "session" ? 300 : 10_080
            // "Chronic" requires recurrence: with one max-out the median IS
            // that single sample, and this branch bypassed the 2-per-week gate.
            let chronicEarlyExhaustion = s.activeUse.interruptingExhaustionCount >= 2
                && (s.medianTimeTo100Sec ?? .infinity) < windowMinutes * 60 * 0.6

            if s.sawCreditOverflow {
                advice = .upgrade(reason: L.tr(
                    "이미 한도 초과분을 크레딧으로 지불 중 — 초과 지출이 티어 차액보다 크면 업그레이드가 저렴합니다",
                    "Already paying overflow via credits — upgrading is cheaper if overflow spend exceeds the tier gap"
                ))
            } else if interruptionsPerWeek >= 2 {
                advice = .upgrade(reason: L.tr(
                    "주당 \(String(format: "%.1f", interruptionsPerWeek))회 작업 중단 (리셋까지 시간이 남은 소진)",
                    "Work cut short \(String(format: "%.1f", interruptionsPerWeek))×/week, with the cycle still to run"
                ))
            } else if let demand = s.impliedDemandP90, demand > 120, s.maxedCount >= 2 {
                // Margin + min-sample: implied demand is >=100 by construction
                // for ANY maxed window, so without these a single max-out in
                // 28 days would flip the advice (and make the deliberate
                // 2-per-week threshold above unreachable).
                advice = .upgrade(reason: L.tr(
                    "수요가 현재 한도의 ~\(Int(demand))%",
                    "Demand is ~\(Int(demand))% of the current limit"
                ))
            } else if chronicEarlyExhaustion {
                advice = .upgrade(reason: L.tr(
                    "윈도우 60% 지점 이전에 상습적으로 소진",
                    "Chronically exhausted before 60% of the window"
                ))
            } else if s.maxedCount == 0, s.observedDays >= 28 - 1,
                      s.coveredCount >= 3,
                      Double(s.coveredCount) >= 0.6 * Double(s.activeWindowCount),
                      let p95 = s.p95Peak, p95 < 40, !s.p95IsCensored,
                      // Contract V4: headroom is read off the windows the user
                      // actually worked in. The all-window p95 above can be low
                      // purely because most windows were slept through, and
                      // telling that user to pay less is the one recommendation
                      // that costs them when it is wrong.
                      // A nil active p95 is not a pass: it means no window
                      // the user worked in was sampled near its reset, so
                      // there is nothing to read headroom off at all.
                      let activeP95 = s.activeUse.active.p95, activeP95 < 40,
                      !s.activeUse.active.isCensored {
                // Downgrade is deliberately stricter than upgrade: it needs the
                // full 28-day lookback with zero exhaustion (plan §2) — and a
                // representative sample. Windows where the machine slept
                // through the reset are excluded from `peaks` as lower bounds
                // of unknown looseness, so without a coverage floor a segment
                // with 27 observed days and two usable windows could recommend
                // paying less on the strength of two numbers, while the
                // excluded windows' true peaks might have been anything.
                advice = .downgrade(reason: L.tr(
                    "28일간 소진 0회, p95 peak \(Int(p95))%",
                    "0 maxed windows in 28d, p95 peak \(Int(p95))%"
                ))
            } else {
                // The badge already states the verdict, so the reason must not
                // repeat it — "적정 — ... — 적정" was rendering verbatim.
                //
                // A nil p95 is not "unknown", it is "no window was sampled
                // close enough to its reset to bound the peak" (every row was
                // low-coverage). Printing a bare dash there made the card look
                // broken rather than under-sampled.
                if let p95 = s.p95Peak {
                    advice = .keep(reason: L.tr(
                        "p95 peak \(Int(p95))%, 소진 \(s.maxedCount)회",
                        "p95 peak \(Int(p95))%, \(s.maxedCount) maxed"
                    ))
                } else {
                    advice = .keep(reason: L.tr(
                        "소진 \(s.maxedCount)회 · peak 표본 부족(리셋 직전 관측 없음)",
                        "\(s.maxedCount) maxed · too few windows sampled near reset for a peak"
                    ))
                }
            }
        }

        return s.replacingAdvice(advice)
    }

    /// Nearest-rank percentile on a pre-sorted array.
    static func percentile(_ sorted: [Double], _ q: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((q * Double(sorted.count)).rounded(.up)) - 1
        return sorted[max(0, min(rank, sorted.count - 1))]
    }
}
