import Foundation

// MARK: - Plan-fit verdict (contract V1–V8)
//
// This layer says something about the user's MONEY. Everything here exists to
// make an unfounded recommendation structurally impossible rather than merely
// discouraged:
//
// - There is no way to build a verdict without its basis: `basis` is a stored,
//   non-optional property of the verdict itself (V3/T032).
// - Withholding is one of the outcomes, in the same enum as the verdicts, not
//   an error path or an empty value (V1/V2). Reading a `PlanFitVerdict` forces
//   the caller to handle it.
// - Headroom is only ever a growth SENSITIVITY ("usage could grow by N% and
//   the current plan still absorbs it"), never a point estimate of how much
//   plan is left (V3), and it is read off the windows the user actually worked
//   in, never all windows (V4).
// - There is deliberately no `isSafe` / `willNotBeBlocked` accessor anywhere,
//   and the only text producer emits the V8 qualifier together with the
//   sensitivity sentence, in one value, so a caller cannot render one without
//   the other.
// - No tier names, no absolute limits, no prices (V7). Every statement is
//   about "the current plan".
//
// The statistics themselves are NOT recomputed here. `WindowStats` already
// owns the 28-day lookback, the percentile-of-peaks, right-censoring, the
// low-coverage exclusion, the active-use split, the V5 interruption weighting
// and the asymmetric upgrade/downgrade rule. This layer consumes that and adds
// the judgement — including the judgement to refuse.

// MARK: - Headroom

/// Which statistic of the active-use distribution the conservative end of the
/// headroom was read off.
///
/// This varies with the sample and is reported in the basis, because "p95" is
/// a claim about a sample that can support one. `WindowStats.percentile` is
/// nearest-rank, so for fewer than 20 samples the "p95" IS the maximum — and
/// calling the maximum a 95th percentile would overstate what was measured.
/// Below the threshold the maximum is used and labelled as the maximum, which
/// is also the more conservative reading: a thin sample buys less headroom,
/// exactly as it should (research §B-3).
enum HeadroomStatistic: String, Equatable, Hashable, Sendable, CaseIterable {
    /// 20+ active windows: the top 5% of worked windows are allowed to exceed
    /// this, in the same spirit as AWS Compute Optimizer's threshold
    /// percentile removing peaks above it (research §B-1).
    case p95
    /// Fewer than 20 active windows: nothing above the sample maximum can be
    /// bounded, so the maximum is what is used.
    case observedMaximum

    var label: String {
        switch self {
        case .p95: return "p95"
        case .observedMaximum: return "max"
        }
    }
}

/// Contract V3. How much the current plan absorbs, expressed as the growth in
/// usage it would still take — never as a point estimate of "capacity left".
///
/// Contract V8 is why there is no boolean here. "Has headroom" is not "will
/// not be blocked": two reported limits have been observed with slack while
/// the account was blocked anyway (research §A-1), so a provider can enforce
/// a limit it does not report. Nothing in this type answers "am I safe?",
/// and `sensitivityStatement()` is the only way to turn it into words —
/// it always emits the caveat alongside the number.
struct Headroom: Equatable, Hashable, Sendable {

    /// Above this the growth figure stops being informative and is reported as
    /// a floor instead of a value.
    static let maxReportableGrowthPct: Double = 1000

    let statistic: HeadroomStatistic
    /// Utilisation the conservative end was read off, as a percentage of the
    /// current plan's limit.
    let statisticValue: Double
    /// Growth the plan absorbs even at the heaviest worked windows the sample
    /// can bound. This is the number a verdict leads with.
    let conservativeGrowthPct: Double
    /// Growth the plan absorbs for a typical (median) worked window. Always
    /// >= `conservativeGrowthPct`; the pair is the band, and reporting only
    /// one end would be the point estimate V3 forbids.
    let typicalGrowthPct: Double
    /// The growth figure hit `maxReportableGrowthPct` and is a floor.
    let isCapped: Bool
    /// Some worked windows were clipped at 100%, so `statisticValue` is a
    /// LOWER bound on demand and this growth figure is therefore an UPPER
    /// bound on the headroom — the real headroom is smaller, possibly
    /// negative. A censored headroom can never support a downgrade (V6).
    let readsFromCensoredSample: Bool

    /// The windows the sample can bound already sit at the limit. Not "no
    /// slack in the plan" — "no growth this evidence can absorb".
    var isAtCeiling: Bool { conservativeGrowthPct <= 0 }

    /// Growth percentage from a utilisation percentage, clamped and flagged.
    static func growth(fromUtilisationPct pct: Double) -> (value: Double, isCapped: Bool) {
        guard pct > 0 else { return (maxReportableGrowthPct, true) }
        guard pct < 100 else { return (0, false) }
        let raw = (100.0 / pct - 1) * 100
        return raw >= maxReportableGrowthPct ? (maxReportableGrowthPct, true) : (raw, false)
    }

    /// Contract V4/V3: built from the ACTIVE-use distribution only. Passing
    /// the all-window distribution here would report the sleeping hours as
    /// headroom, which is the exact inversion this feature exists to stop —
    /// so the only caller is the evaluator below, and it passes
    /// `segment.activeUse.active`.
    static func fromActiveDistribution(_ d: UtilisationDistribution) -> Headroom? {
        // The percentiles are computed over the well-covered subset. When
        // nothing in the active set was observed near its reset there is no
        // statistic at all — which is a withholding condition, not a zero.
        guard let top = d.p95 else { return nil }
        let statistic: HeadroomStatistic = d.sampledCount >= largeSampleThreshold ? .p95 : .observedMaximum
        let conservative = growth(fromUtilisationPct: top)
        let typicalSource = d.p50 ?? top
        let typical = growth(fromUtilisationPct: typicalSource)
        return Headroom(
            statistic: statistic,
            statisticValue: top,
            conservativeGrowthPct: conservative.value,
            typicalGrowthPct: max(conservative.value, typical.value),
            isCapped: conservative.isCapped,
            readsFromCensoredSample: d.isCensored
        )
    }

    /// At and above this many well-covered active windows, the nearest-rank
    /// p95 is an order statistic below the maximum (20 × 0.05 = 1), so it can
    /// honestly be called a 95th percentile. Below it, it is the maximum.
    static let largeSampleThreshold = 20
}

/// Contract V3 + V8 in one value: the sensitivity sentence and the sentence
/// that stops it being read as a guarantee. There is no API that produces one
/// without the other.
struct SensitivityStatement: Equatable, Hashable, Sendable {
    let sensitivity: String
    let qualifier: String
}

// MARK: - Basis (contract V3 / T032)

/// What a verdict — including a withheld one — stands on. Stored on the
/// verdict, so no verdict can exist without it.
struct VerdictBasis: Equatable, Hashable, Sendable {
    let provider: String
    let kind: String
    let limitId: String

    /// The window that was looked at.
    let lookbackDays: Double
    /// How much of that lookback actually has data.
    let observedDays: Double
    /// Days of history a verdict requires (4 × the longest limit cycle).
    let requiredObservedDays: Double

    /// Every finalized window in the segment.
    let windowCount: Int
    /// Windows the user was proven to have worked in — the sample the headroom
    /// is read off (V4).
    let activeWindowCount: Int
    /// Of those, how many were observed close enough to their reset for the
    /// peak to be an upper bound rather than a floor.
    let sampledActiveWindowCount: Int
    /// Windows that could not be classified either way. Not "unused".
    let undecidableWindowCount: Int
    /// Windows positively known to have gone unused.
    let idleWindowCount: Int
    /// Active windows a verdict requires for this limit's cycle length.
    let requiredActiveWindows: Int

    /// Which statistic of the active distribution was used, and its value.
    let statistic: HeadroomStatistic
    let statisticValue: Double?
    /// The statistic is a floor: some worked windows were clipped at 100%.
    let statisticIsLowerBound: Bool

    let exhaustionCount: Int
    let interruptingExhaustionCount: Int
    let interruptionsPerWeek: Double
}

// MARK: - Withholding (contract V1 / V2)

/// Why no verdict was issued. Every case is a normal outcome, not a failure.
enum WithholdingReason: Equatable, Hashable, Sendable {
    /// V2.1 — completed history shorter than 4× the longest limit cycle.
    /// AWS recommends a 32-day lookback to capture a monthly cycle and Azure
    /// writes that 7 days is not enough (research §B-1, §B-2). Claude's
    /// longest cycle is 7 days, so 4 cycles is 28 days.
    case historyShorterThanFourCycles(observedDays: Double, requiredDays: Double)
    /// V2.2 — the active-use sample is too thin for a distribution.
    case activeSampleTooSmall(activeWindows: Int, required: Int)
    /// V2.3 — plan tier or account changed inside the lookback: the
    /// denominator of every percentage changed underneath the numbers.
    case tierOrAccountChanged(distinctSegments: Int)
    /// V2.4 — most of the worked windows were never observed near their reset,
    /// so most of the sample is a lower bound of unknown looseness.
    case lowCoverageMajority(sampledActive: Int, activeWindows: Int)
    /// The plan string is absent or unknown. Strictly worse than V2.3: there
    /// we know the denominator changed, here we cannot establish that it held.
    case planUnidentified
}

/// When a verdict becomes possible, where that is knowable (V1).
enum VerdictAvailability: Equatable, Hashable, Sendable {
    /// Keep collecting and it becomes possible in about this many days.
    case inDays(Int)
    /// Not a function of time — it depends on how much the user works.
    case whenUsageProducesWindows(needed: Int)
    /// The machine has to be awake near the resets.
    case whenCoverageImproves
    /// Nothing this data can grow into will answer it.
    case notFromThisData
}

// MARK: - Upgrade evidence

/// The facts behind an upgrade verdict. No tier names, no prices (V7): this
/// says the current plan interrupts the work, and nothing about what to buy.
struct UpgradeEvidence: Equatable, Hashable, Sendable {
    /// Σ V5-weighted exhaustions per observed week.
    let interruptionsPerWeek: Double
    /// Exhaustions that carried any weight at all.
    let interruptingExhaustions: Int
    /// Exhaustions that happened with the reset already imminent.
    let harmlessExhaustions: Int
    /// Median time still to run when the limit was hit.
    let medianTimeLeftMs: Int64?
    /// The user is already paying for overflow out of credits.
    let payingOverflowCredits: Bool
    /// p90 of implied demand as a percentage of the current limit, where the
    /// exhaustion timing allowed it to be extrapolated.
    let impliedDemandPct: Double?
    /// The wording `WindowStats` already produced for this segment. Carried
    /// rather than re-derived: re-deriving which rung of the ladder fired
    /// would be a second copy of the rule, free to drift from the first.
    let reason: String
}

// MARK: - The verdict

/// A plan-fit verdict for one segment, or the reasoned refusal to give one.
struct PlanFitVerdict: Equatable, Sendable {

    /// Contract V2's outcomes and the verdicts live in the same enum on
    /// purpose. Withholding is not an error the caller may forget to handle;
    /// it is one of the four things this can be.
    enum Outcome: Equatable, Sendable {
        /// V1. Not an error, not an empty value, not a weak recommendation.
        case withheld(WithholdingReason, possibleWhen: VerdictAvailability)
        /// The current plan matches the observed work.
        case fits(Headroom)
        /// The current plan interrupts the work.
        case considerUpgrade(UpgradeEvidence, headroom: Headroom)
        /// Passed a strictly higher bar than any upgrade (V6).
        case considerDowngrade(Headroom)
    }

    let outcome: Outcome
    /// V3/T032 — stored and non-optional. There is no verdict without a basis.
    let basis: VerdictBasis

    var isWithheld: Bool {
        if case .withheld = outcome { return true }
        return false
    }

    /// Headroom, where one was computed. nil while withheld — and note that
    /// nil is NOT "no headroom": it is "no statement about headroom".
    var headroom: Headroom? {
        switch outcome {
        case .fits(let h), .considerDowngrade(let h): return h
        case .considerUpgrade(_, let h): return h
        case .withheld: return nil
        }
    }

    // MARK: Thresholds

    /// 4 × the longest limit cycle (7 days for Claude) = the whole lookback.
    /// The tolerance matches the one `WindowStats` already applies to its
    /// downgrade gate: `observedDays` is derived from window anchors and, for
    /// a segment whose oldest window sits on the boundary, cannot reach a full
    /// 28 even when 28 days of history exist.
    static let requiredObservedDays: Double = WindowStats.lookbackDays
    static let observedDaysTolerance: Double = 1

    /// Active windows a verdict needs, at most. 20 would let the headroom be a
    /// true p95, but demanding 20 worked windows would silence the feature for
    /// anyone who works in bursts; 8 is the point at which the maximum of the
    /// sample stops being one person's one bad afternoon.
    static let preferredMinimumActiveWindows = 8
    /// Floor for limits whose cycle is long enough that the lookback cannot
    /// contain `preferredMinimumActiveWindows` of them. A weekly limit yields
    /// 4 windows in 28 days and no amount of waiting produces more inside the
    /// lookback, so requiring 8 would withhold the weekly verdict forever.
    /// Below 3 there is no distribution at all, only points.
    static let absoluteMinimumActiveWindows = 3

    /// A downgrade must survive a doubling of the heaviest worked window the
    /// sample can bound. AWS adds explicit utilisation headroom on top of its
    /// threshold percentile for the same reason (research §B-1); this is that
    /// headroom, sized for a recommendation whose failure mode is the user
    /// being cut off.
    static let downgradeMinimumGrowthPct: Double = 100

    /// How many active windows this limit's cycle can even produce inside the
    /// lookback, clamped to the range a verdict will accept.
    static func requiredActiveWindows(windowMinutes: Int) -> Int {
        guard windowMinutes > 0 else { return preferredMinimumActiveWindows }
        let cyclesInLookback = Int(WindowStats.lookbackDays * 1440 / Double(windowMinutes))
        return min(preferredMinimumActiveWindows, max(absoluteMinimumActiveWindows, cyclesInLookback))
    }

    // MARK: Evaluation

    /// Verdicts for every segment, with tier/account changes detected across
    /// the segments that share a limit.
    static func evaluateAll(segments: [WindowStatsSegment]) -> [PlanFitVerdict] {
        var peers: [String: [WindowStatsSegment]] = [:]
        for s in segments {
            peers["\(s.provider)|\(s.kind)|\(s.limitId)", default: []].append(s)
        }
        return segments.map { s in
            evaluate(segment: s, peers: peers["\(s.provider)|\(s.kind)|\(s.limitId)"] ?? [s])
        }
    }

    /// One segment's verdict.
    ///
    /// `peers` is every segment for the same provider + window kind + limit id
    /// inside the lookback, including `segment` itself. More than one means the
    /// tier or the account changed while the lookback was running, which is
    /// V2's third withholding condition — and it cannot be seen from a single
    /// segment, which is why it is a parameter rather than something this
    /// function digs out.
    static func evaluate(segment: WindowStatsSegment, peers: [WindowStatsSegment]) -> PlanFitVerdict {
        let active = segment.activeUse.active
        let required = requiredActiveWindows(windowMinutes: windowMinutes(of: segment))
        let headroom = Headroom.fromActiveDistribution(active)
        let basis = VerdictBasis(
            provider: segment.provider,
            kind: segment.kind,
            limitId: segment.limitId,
            lookbackDays: WindowStats.lookbackDays,
            observedDays: segment.observedDays,
            requiredObservedDays: requiredObservedDays,
            windowCount: segment.activeWindowCount,
            activeWindowCount: active.count,
            sampledActiveWindowCount: active.sampledCount,
            undecidableWindowCount: segment.activeUse.cannotTellCount,
            idleWindowCount: segment.activeUse.noActiveUseCount,
            requiredActiveWindows: required,
            statistic: headroom?.statistic
                ?? (active.sampledCount >= Headroom.largeSampleThreshold ? .p95 : .observedMaximum),
            statisticValue: headroom?.statisticValue,
            statisticIsLowerBound: active.isCensored,
            exhaustionCount: segment.activeUse.exhaustions.count,
            interruptingExhaustionCount: segment.activeUse.interruptingExhaustionCount,
            interruptionsPerWeek: segment.activeUse.interruptionsPerWeek
        )

        if let withheld = withholding(segment: segment, peers: peers, required: required, headroom: headroom) {
            return PlanFitVerdict(outcome: withheld, basis: basis)
        }
        // Unreachable: every path that leaves `headroom` nil is a withholding
        // condition above. Belt and braces — a missing statistic must never
        // fall through into a verdict.
        guard let headroom else {
            return PlanFitVerdict(
                outcome: .withheld(
                    .lowCoverageMajority(sampledActive: active.sampledCount, activeWindows: active.count),
                    possibleWhen: .whenCoverageImproves
                ),
                basis: basis
            )
        }

        switch segment.advice {
        case .upgrade(let reason):
            let breakdown = segment.activeUse
            let evidence = UpgradeEvidence(
                interruptionsPerWeek: breakdown.interruptionsPerWeek,
                interruptingExhaustions: breakdown.interruptingExhaustionCount,
                harmlessExhaustions: breakdown.harmlessExhaustionCount,
                medianTimeLeftMs: breakdown.medianTimeLeftMs,
                payingOverflowCredits: segment.sawCreditOverflow,
                impliedDemandPct: segment.impliedDemandP90,
                reason: reason
            )
            return PlanFitVerdict(outcome: .considerUpgrade(evidence, headroom: headroom), basis: basis)

        case .downgrade:
            return PlanFitVerdict(
                outcome: passesDowngradeBar(segment: segment, headroom: headroom)
                    ? .considerDowngrade(headroom)
                    : .fits(headroom),
                basis: basis
            )

        // `.collecting` (< 14 days), `.evidenceOnly` (no plan) and
        // `.historical` (a tier the user left) are all withheld above; if one
        // ever reaches here it means the plan says "no call", and a verdict
        // layer must not invent one.
        case .keep, .collecting, .evidenceOnly, .historical:
            return PlanFitVerdict(outcome: .fits(headroom), basis: basis)
        }
    }

    // MARK: Withholding conditions (contract V2)

    private static func withholding(
        segment: WindowStatsSegment,
        peers: [WindowStatsSegment],
        required: Int,
        headroom: Headroom?
    ) -> Outcome? {
        let active = segment.activeUse.active

        // The plan is the denominator of every percentage on the segment.
        // Without it we cannot even establish that the denominator held.
        if segment.plan.isEmpty || segment.plan.lowercased() == "unknown" {
            return .withheld(.planUnidentified, possibleWhen: .notFromThisData)
        }

        // V2.3, checked before V2.1 on purpose: after a tier change the new
        // segment's history is necessarily short too, and reporting the short
        // history would name the symptom while hiding the cause.
        let distinct = Set(peers.map { "\($0.plan)\u{1}\($0.account)" })
        var changed = distinct.count > 1
        // A segment `WindowStats` already demoted to `.historical` is a tier
        // the user has left, which is the same event seen from one side.
        if case .historical = segment.advice { changed = true }
        if changed {
            let daysLeft = max(0, requiredObservedDays - segment.observedDays)
            return .withheld(
                .tierOrAccountChanged(distinctSegments: max(distinct.count, 2)),
                possibleWhen: .inDays(Int(daysLeft.rounded(.up)))
            )
        }

        // V2.1
        if segment.observedDays < requiredObservedDays - observedDaysTolerance {
            let daysLeft = max(0, requiredObservedDays - segment.observedDays)
            return .withheld(
                .historyShorterThanFourCycles(
                    observedDays: segment.observedDays,
                    requiredDays: requiredObservedDays
                ),
                possibleWhen: .inDays(Int(daysLeft.rounded(.up)))
            )
        }

        // V2.2
        if active.count < required {
            let missing = required - active.count
            let perDay = segment.observedDays > 0 ? Double(active.count) / segment.observedDays : 0
            let availability: VerdictAvailability = perDay > 0
                ? .inDays(Int((Double(missing) / perDay).rounded(.up)))
                : .whenUsageProducesWindows(needed: missing)
            return .withheld(
                .activeSampleTooSmall(activeWindows: active.count, required: required),
                possibleWhen: availability
            )
        }

        // V2.4 — a strict majority of the worked windows were never observed
        // near their reset, so most of what the headroom would rest on is a
        // floor of unknown looseness. Also catches the case where nothing was
        // sampled at all and there is no statistic to read.
        if headroom == nil || 2 * active.sampledCount < active.count {
            return .withheld(
                .lowCoverageMajority(sampledActive: active.sampledCount, activeWindows: active.count),
                possibleWhen: .whenCoverageImproves
            )
        }

        return nil
    }

    // MARK: Downgrade bar (contract V6 / T033)

    /// Everything a downgrade needs on top of `WindowStats`'s already
    /// asymmetric rule.
    ///
    /// The gate itself is not reimplemented: `TierAdvice.downgrade` already
    /// requires the full 28 days, zero exhaustion, 60% coverage, p95 < 40 on
    /// both the all-window and the active distribution, and no censoring.
    /// This adds the bars that only make sense once a verdict is being spoken
    /// aloud — and it is the layer that enforces the one thing V6 states
    /// outright: **a censored statistic can never support a downgrade.**
    static func passesDowngradeBar(segment: WindowStatsSegment, headroom: Headroom) -> Bool {
        guard case .downgrade = segment.advice else { return false }
        let active = segment.activeUse.active

        // V6, said three ways because a value clipped at 100% is a LOWER bound
        // on demand and the real demand is above it — so every route by which
        // a clipped value could reach the headroom is closed, not just the one
        // `WindowStats` happens to close today.
        guard !headroom.readsFromCensoredSample else { return false }
        guard !active.isCensored, !segment.p95IsCensored else { return false }
        guard headroom.statisticValue < 100 else { return false }
        guard segment.maxedCount == 0 else { return false }

        // Every worked window was observed near its reset. `WindowStats` asks
        // for 60% coverage over all windows; a downgrade asks for all of the
        // ones it reads. An excluded window's true peak is unknown and could
        // have been 100.
        guard active.sampledCount == active.count else { return false }

        // The undecidable set must not outnumber the evidence. When more
        // windows could not be classified than could, what the user's real
        // work looked like is mostly unobserved — and the recommendation that
        // costs them if wrong is not the one to make from that.
        guard segment.activeUse.cannotTellCount <= active.count else { return false }

        // A doubling of the heaviest worked window must still fit.
        guard headroom.conservativeGrowthPct >= downgradeMinimumGrowthPct else { return false }

        return true
    }

    private static func windowMinutes(of segment: WindowStatsSegment) -> Int {
        if let first = segment.activeUse.exhaustions.first, first.windowLengthMs > 0 {
            return Int(first.windowLengthMs / 60_000)
        }
        return segment.kind == "weekly" ? 10_080 : 300
    }
}

// MARK: - Wording
//
// The only place a verdict becomes text. Both invariants that are easy to lose
// in a view live here instead: the basis travels with every statement (V3),
// and the V8 qualifier is emitted in the same value as the sensitivity
// sentence (V8), so there is no code path that renders "you have room to grow"
// on its own.

/// A verdict rendered for display. `sensitivity` is nil when no headroom was
/// stated; when it is present it carries its own qualifier.
struct VerdictStatement: Equatable, Hashable, Sendable {
    let headline: String
    let sensitivity: SensitivityStatement?
    /// Lookback, sample size and the statistic used (V3 / T032).
    let basis: String
    /// Present only when withheld: when a verdict becomes possible.
    let availability: String?
}

extension Headroom {
    /// Contract V3 + V8. The qualifier is not optional and not separable.
    func sensitivityStatement() -> SensitivityStatement {
        let qualifier = L.tr(
            "여유가 있다는 것은 차단되지 않는다는 보증이 아닙니다 — 공급자가 노출하지 않는 한도가 있을 수 있고, 표시된 한도가 모두 여유일 때 차단된 사례가 관측되어 있습니다.",
            "Headroom is not a guarantee against being cut off — a provider can enforce limits it does not report, and accounts have been blocked while every reported limit still showed slack."
        )
        if readsFromCensoredSample {
            return SensitivityStatement(
                sensitivity: L.tr(
                    "실사용 윈도우 일부가 한도에 걸려 실수요는 관측값보다 큽니다 — 늘어날 여유는 없다고 봅니다.",
                    "Some worked windows hit the limit, so real demand is above what was recorded — treat the room to grow as none."
                ),
                qualifier: qualifier
            )
        }
        if isAtCeiling {
            return SensitivityStatement(
                sensitivity: L.tr(
                    "실사용 중에는 이미 현재 요금제의 한도에 닿아 있습니다.",
                    "While actually working, usage is already at the current plan's limit."
                ),
                qualifier: qualifier
            )
        }
        let n = Int(conservativeGrowthPct.rounded())
        let typical = Int(typicalGrowthPct.rounded())
        let atLeast = isCapped
            ? L.tr("최소 ", "at least ")
            : ""
        let band = typical > n
            ? L.tr(" (보통의 작업 윈도우 기준으로는 \(typical)%)", " (\(typical)% for a typical worked window)")
            : ""
        return SensitivityStatement(
            sensitivity: L.tr(
                "사용량이 지금보다 \(atLeast)\(n)% 늘어도 현재 요금제로 감당됩니다\(band).",
                "Usage could grow by \(atLeast)\(n)% and the current plan would still absorb it\(band)."
            ),
            qualifier: qualifier
        )
    }
}

extension VerdictBasis {
    /// V3: lookback, sample size, percentile used — on every verdict.
    var summary: String {
        let value = statisticValue.map { "\(Int($0.rounded()))%" } ?? L.tr("표본 없음", "no sample")
        let bound = statisticIsLowerBound ? L.tr(" 이상", " or more") : ""
        return L.tr(
            "룩백 \(Int(lookbackDays))일 · 관측 \(Int(observedDays.rounded()))일 · 실사용 윈도우 \(activeWindowCount)개(표본 \(sampledActiveWindowCount)) · \(statistic.label) \(value)\(bound)",
            "\(Int(lookbackDays))d lookback · \(Int(observedDays.rounded()))d observed · \(activeWindowCount) worked windows (\(sampledActiveWindowCount) sampled) · \(statistic.label) \(value)\(bound)"
        )
    }
}

extension VerdictAvailability {
    var summary: String {
        switch self {
        case .inDays(let d) where d <= 0:
            return L.tr("다음 관측분부터 판정할 수 있습니다.", "A verdict becomes possible with the next observations.")
        case .inDays(let d):
            return L.tr("약 \(d)일 뒤부터 판정할 수 있습니다.", "A verdict becomes possible in about \(d) days.")
        case .whenUsageProducesWindows(let needed):
            return L.tr(
                "실사용 윈도우가 \(needed)개 더 쌓이면 판정할 수 있습니다 — 날짜가 아니라 사용량에 달려 있습니다.",
                "A verdict becomes possible after \(needed) more worked windows — that depends on usage, not on the calendar."
            )
        case .whenCoverageImproves:
            return L.tr(
                "리셋 시점에 기기가 깨어 있는 주기가 늘어나면 판정할 수 있습니다.",
                "A verdict becomes possible once more cycles are observed through to their reset."
            )
        case .notFromThisData:
            return L.tr("이 데이터로는 판정할 수 없습니다.", "This data cannot answer it.")
        }
    }
}

extension WithholdingReason {
    var summary: String {
        switch self {
        case .historyShorterThanFourCycles(let observed, let required):
            return L.tr(
                "판정하기에 이릅니다 — 관측 \(Int(observed.rounded()))일 / 필요 \(Int(required))일",
                "Too early to judge — \(Int(observed.rounded())) of the \(Int(required)) days needed"
            )
        case .activeSampleTooSmall(let n, let required):
            return L.tr(
                "실사용 윈도우가 \(n)개뿐입니다 — 판정에는 \(required)개가 필요합니다",
                "Only \(n) worked windows — a verdict needs \(required)"
            )
        case .tierOrAccountChanged:
            return L.tr(
                "룩백 기간 중 요금제나 계정이 바뀌었습니다 — 퍼센트의 분모가 달라졌습니다",
                "The plan or account changed inside the lookback — the denominator of every percentage moved"
            )
        case .lowCoverageMajority(let sampled, let total):
            return L.tr(
                "실사용 윈도우 \(total)개 중 \(total - sampled)개가 리셋 시점에 관측되지 않았습니다",
                "\(total - sampled) of \(total) worked windows were not observed through to their reset"
            )
        case .planUnidentified:
            return L.tr(
                "요금제를 확인할 수 없어 퍼센트의 분모가 서지 않습니다",
                "The plan is unidentified, so the denominator of every percentage is unknown"
            )
        }
    }
}

extension PlanFitVerdict {
    /// The one text producer. Basis always attached (V3); the V8 qualifier
    /// always attached to the sensitivity (V8); no tier names and no prices
    /// anywhere (V7).
    func statement() -> VerdictStatement {
        switch outcome {
        case .withheld(let reason, let possibleWhen):
            return VerdictStatement(
                headline: reason.summary,
                sensitivity: nil,
                basis: basis.summary,
                availability: possibleWhen.summary
            )
        case .fits(let headroom):
            return VerdictStatement(
                headline: L.tr("현재 요금제가 실사용 패턴에 맞습니다", "The current plan matches how you actually work"),
                sensitivity: headroom.sensitivityStatement(),
                basis: basis.summary,
                availability: nil
            )
        case .considerUpgrade(let evidence, let headroom):
            let perWeek = String(format: "%.1f", evidence.interruptionsPerWeek)
            let headline = evidence.payingOverflowCredits
                ? L.tr(
                    "현재 요금제의 한도를 넘어 크레딧으로 채우고 있습니다",
                    "Work is already running past the current plan's limit and onto credits"
                )
                : L.tr(
                    "현재 요금제로는 작업이 자주 끊깁니다 — 주당 \(perWeek)회",
                    "The current plan interrupts your work \(perWeek)×/week"
                )
            return VerdictStatement(
                headline: headline,
                sensitivity: headroom.sensitivityStatement(),
                basis: basis.summary,
                availability: nil
            )
        case .considerDowngrade(let headroom):
            return VerdictStatement(
                headline: L.tr(
                    "실사용 중에도 현재 요금제를 다 쓰지 않고 있습니다 — 하향을 검토할 수 있습니다",
                    "Even while working, the current plan goes unused — a lower limit is worth considering"
                ),
                sensitivity: headroom.sensitivityStatement(),
                basis: basis.summary,
                availability: nil
            )
        }
    }
}
