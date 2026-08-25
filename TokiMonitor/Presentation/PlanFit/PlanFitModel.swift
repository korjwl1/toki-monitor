import Foundation

// MARK: - What the page draws, as one value
//
// The page presents; it does not calculate. Every number below is lifted from
// `WindowStats`, `PlanFitVerdict` or `PeriodAggregation` — this file's whole
// job is to choose what gets said, in what order, and with which provenance,
// and to freeze that choice into a value a snapshot can render without a
// daemon, a network, or a clock.
//
// Two rules are enforced here by *shape* rather than by review:
//
// - `HeadroomNote` cannot be constructed without its caveat (T051 / contract
//   V8). There is no code path that renders "you have room to grow" alone,
//   because the type that carries the sentence carries the qualifier too.
// - Every figure that is a floor travels with `Provenance.lowerBound`
//   attached (T052 / FR-049), so "at least" is data rather than a caption
//   someone remembered to write.

// MARK: - Headroom, inseparable from its caveat

/// A statement about room to grow, and the sentence that stops it from being
/// read as a guarantee.
///
/// Contract V8: two reported limits have been observed with slack while the
/// account was blocked anyway, so a provider can enforce a limit it does not
/// report. The single initialiser takes the domain's `SensitivityStatement`,
/// whose qualifier is non-optional — which is what makes "slack shown without
/// the caveat" unrepresentable rather than merely discouraged.
struct HeadroomNote: Equatable, Hashable, Sendable {
    let sensitivity: String
    let caveat: String

    init(_ statement: SensitivityStatement) {
        self.sensitivity = statement.sensitivity
        self.caveat = statement.qualifier
    }
}

// MARK: - The lede

/// The conclusion, rendered larger than anything else on the page (T049).
struct PlanFitLede: Equatable, Hashable, Sendable {

    /// What kind of conclusion this is. Drives the symbol and the word beside
    /// the headline — never colour on its own (FR-058).
    enum Kind: String, Equatable, Hashable, Sendable {
        /// A verdict was withheld. **This is a normal result**, and the most
        /// common one: the whole recorded history at measurement time was 21
        /// window rows.
        case withheld
        case fits
        case considerUpgrade
        case considerDowngrade
        /// No window rows at all — day one.
        case noData
        /// Every source failed. Distinct from `noData`: masking a dead daemon
        /// as "no data yet" hides the problem.
        case loadFailed
        case loading

        var badge: String {
            switch self {
            case .withheld: return L.tr("판정 보류", "Verdict withheld")
            case .fits: return L.tr("판정", "Verdict")
            case .considerUpgrade: return L.tr("판정", "Verdict")
            case .considerDowngrade: return L.tr("판정", "Verdict")
            case .noData: return L.tr("수집 시작 전", "Nothing collected yet")
            case .loadFailed: return L.tr("불러오지 못함", "Could not load")
            case .loading: return L.tr("불러오는 중", "Loading")
            }
        }

        var symbolName: String {
            switch self {
            case .withheld: return "hourglass"
            case .fits: return "checkmark.circle"
            case .considerUpgrade: return "arrow.up.circle"
            case .considerDowngrade: return "arrow.down.circle"
            case .noData: return "tray"
            case .loadFailed: return "exclamationmark.triangle"
            case .loading: return "clock"
            }
        }
    }

    let kind: Kind
    /// The one sentence. Comes from `PlanFitVerdict.statement()` whenever a
    /// verdict exists, so the page cannot phrase a conclusion the domain did
    /// not reach.
    let headline: String
    /// Which limit the conclusion is about. A page with eight segments must
    /// not leave the reader guessing which one just spoke.
    let scope: String?
    /// Sensitivity and its inseparable caveat.
    let headroom: HeadroomNote?
    /// Lookback, sample size, statistic — attached to every verdict (V3).
    let basis: String?
    /// Present only when withheld: when a verdict becomes possible.
    let availability: String?
    /// Extra guidance for the empty and failed screens.
    let detail: String?
}

// MARK: - Period trend

/// The weekly/monthly trend (T045, T046).
///
/// The quantity trended is RECORDED WORK TIME, summed from `activeMs` over the
/// windows the page already holds. That is a lower bound — the daemon
/// accumulates it in memory and the accumulation restarts with the daemon — so
/// the section carries `Provenance.lowerBound` and says so. Trending a
/// percentage instead would have been dishonest in a different way: peaks are
/// relative to a tier's limit and do not add up across periods.
struct PeriodTrendModel: Equatable, Sendable {

    struct Bar: Equatable, Sendable, Identifiable {
        let id: Date
        let label: String
        /// Recorded work time in the bucket, hours. A floor.
        let hours: Double
        /// Per observed day. nil under one observed day — a period a few hours
        /// old has no daily rate yet.
        let dailyAverageHours: Double?
        let isComplete: Bool
        /// "진행 중 · 3/31일". Present exactly when `isComplete` is false.
        let incompleteNote: String?
        /// Rate of change against the previous period, percent.
        let changeRatePct: Double?
        /// True when the rate above is the daily-average one. Monthly mode
        /// leads with that: February beside March on totals alone shows a
        /// ~10% decline that is three missing days.
        let changeIsDailyAverage: Bool
        /// Exhaustions that ended inside this bucket.
        let exhaustions: Int
        /// 0…1 against the tallest bar. Zero-height bars still draw a baseline
        /// so an empty period reads as an observed zero, not as absence.
        let heightFraction: Double
        let accessibilityLabel: String
    }

    let unit: PeriodUnit
    let bars: [Bar]
    /// Total across every bucket. Preserved across a unit switch (FR-003) —
    /// the same samples, partitioned differently.
    let totalHours: Double
    let spanNote: String
    /// `.lowerBound`: the quantity is `activeMs`.
    let provenance: Provenance = .lowerBound

    var isEmpty: Bool { bars.isEmpty }

    static let empty = PeriodTrendModel(
        unit: .weekly, bars: [], totalHours: 0,
        spanNote: L.tr("추이를 그릴 기간이 없습니다", "No period to trend yet")
    )
}

// MARK: - Limit status

/// One limit's exhaustion status (T047).
struct LimitStatusModel: Equatable, Sendable, Identifiable {
    let id: String
    /// "5시간", "주간 · Opus".
    let title: String
    /// The tier the percentages are relative to. Percentages from different
    /// tiers are not the same measurement, which is why it is on the card.
    let planLabel: String?
    /// This segment belongs to a tier or account the user has left. Its
    /// numbers stand; no advice is drawn from them.
    let isHistorical: Bool

    /// "p50 42% · p90 71% · p95 ≥100%" — a distribution, never a lone mean
    /// (FR-009).
    let distribution: String
    let distributionProvenance: Provenance
    /// p50 and p95 as fractions of the limit, for the meter. nil when the
    /// sample could not support percentiles.
    let meterP50: Double?
    let meterP95: Double?
    let meterIsCensored: Bool

    /// "완료 창 46개 · 분포 표본 41개".
    let sampleText: String
    /// "리셋 직전을 관측하지 못한 5개는 분포에서 제외" (FR-012, FR-051).
    let excludedText: String?
    /// "소진 12회 — 하드 스톱 9회 · 크레딧 초과 3회" (FR-010).
    let exhaustionText: String
    let hasExhaustions: Bool
    let paidOverflowCredits: Bool
    /// The in-progress window, kept out of the statistics and shown apart
    /// (FR-011).
    let openWindowText: String?
    /// Sensitivity plus its caveat, or nothing at all. Never a bare "has
    /// headroom" (T051).
    let headroom: HeadroomNote?
    /// Why no verdict, when there is none.
    let withheldText: String?
}

/// Limits grouped under their provider (T050): eight limit cards in one flat
/// list is 32 numbers with nothing to hang them on.
struct LimitProviderGroup: Equatable, Sendable, Identifiable {
    let id: String
    let providerTitle: String
    let limits: [LimitStatusModel]
}

// MARK: - Active use

/// One limit's active/idle split and its exhaustion timing (T048).
struct ActiveUseLimitModel: Equatable, Sendable, Identifiable {

    /// One of the three sets. They are separated, never merged and never
    /// dropped: the idle windows are the honest answer to "how much of the
    /// plan goes unused", and folding them into the headroom sample is the
    /// exact inversion this feature exists to stop.
    struct Split: Equatable, Sendable, Hashable, Identifiable {
        let id: String
        let title: String
        let count: Int
        let distribution: String
        let provenance: Provenance
        /// The set a plan verdict is allowed to read headroom from (V4).
        let isHeadroomSource: Bool
        let note: String?
    }

    /// One exhaustion, placed by how much of the cycle was still to run.
    struct Tick: Equatable, Sendable, Hashable, Identifiable {
        let id: Int64
        /// 0…1 of the cycle left when the limit was hit. nil = never sampled.
        let fractionLeft: Double?
        let severity: Severity
    }

    /// A single exhaustion spelled out.
    struct Event: Equatable, Sendable, Hashable, Identifiable {
        let id: Int64
        let day: String
        /// "리셋까지 2시간 45분 남기고 소진".
        let text: String
        let severity: Severity
        let hitCredits: Bool
    }

    /// How much of an interruption an exhaustion was. Ordered by the domain's
    /// weight, not by a second copy of the rule.
    enum Severity: String, Equatable, Hashable, Sendable {
        /// Weight 1 with timing known: most of the cycle was spent blocked.
        case interrupting
        /// Between the two thresholds.
        case partial
        /// Weight 0: the reset was minutes away.
        case harmless
        /// Maxed with no timestamped 100% sample. Counts in full — there is no
        /// evidence it was harmless — but says that it is unknown.
        case unknownTiming

        var label: String {
            switch self {
            case .interrupting: return L.tr("이른 소진", "early")
            case .partial: return L.tr("중간 소진", "mid-cycle")
            case .harmless: return L.tr("리셋 직전", "just before reset")
            case .unknownTiming: return L.tr("시점 불명", "timing unknown")
            }
        }
    }

    let id: String
    let title: String
    let splits: [Split]
    /// "소진 20회 · 이른 소진 20 · 리셋 직전 0 · 시점 불명 0".
    let exhaustionBreakdown: String
    /// "중앙값 2시간 45분 남기고 소진" — the heart of the feature.
    let medianTimeLeftText: String?
    /// Per-week interruption rate, weighted by how much cycle was left.
    let interruptionRateText: String?
    let ticks: [Tick]
    /// The most recent handful, spelled out. Bounded so eight segments cannot
    /// turn the page into a log.
    let recentEvents: [Event]
    /// The two thresholds, on screen where the numbers are (FR-021).
    let thresholdNote: String
}

// MARK: - The page

/// Everything the page draws.
struct PlanFitModel: Equatable, Sendable {
    let unit: PeriodUnit
    let lede: PlanFitLede
    let trend: PeriodTrendModel
    let limitGroups: [LimitProviderGroup]
    let activeUse: [ActiveUseLimitModel]
    /// Limits with neither an exhaustion nor a worked window, named in one
    /// line instead of getting a card each (T050).
    let quietLimitsNote: String?
    /// "동기화 서버 데이터 (전체 디바이스 병합)".
    let sourceNote: String?

    var hasSegments: Bool { !limitGroups.isEmpty }
}

// MARK: - Building it

@MainActor
enum PlanFitModelBuilder {

    /// At most this many exhaustions are spelled out per limit. The tick strip
    /// above them carries the whole distribution, so the list is a sample for
    /// recognition, not the record.
    static let spelledOutEventLimit = 4

    /// The page's model from the rows it fetched.
    ///
    /// - Parameters:
    ///   - rows: everything both sources returned, open windows included.
    ///   - loadFailed: every source failed. Distinct from "no rows".
    static func build(
        rows: [(provider: String, row: WindowRow)],
        unit: PeriodUnit,
        nowMs: Int64,
        usingServerData: Bool = false,
        loadFailed: Bool = false,
        isLoading: Bool = false
    ) -> PlanFitModel {
        let segments = WindowStats.segments(rows: rows, nowMs: nowMs)
        let verdicts = PlanFitVerdict.evaluateAll(segments: segments)
        let paired = Array(zip(segments, verdicts))

        let lede: PlanFitLede
        if isLoading && rows.isEmpty {
            lede = loadingLede()
        } else if loadFailed && rows.isEmpty {
            lede = failedLede()
        } else if paired.isEmpty {
            lede = noDataLede()
        } else {
            lede = verdictLede(paired)
        }

        return PlanFitModel(
            unit: unit,
            lede: lede,
            trend: trend(rows: rows, unit: unit, nowMs: nowMs),
            limitGroups: limitGroups(paired, rows: rows, nowMs: nowMs),
            activeUse: activeUse(paired),
            quietLimitsNote: quietLimitsNote(paired),
            sourceNote: usingServerData
                ? L.tr("동기화 서버 데이터 · 전체 디바이스 병합", "Sync-server data · all devices merged")
                : nil
        )
    }

    // MARK: Lede

    /// Rank for choosing which segment speaks for the page.
    ///
    /// A page with eight limits has eight verdicts and one lede. An
    /// interruption outranks slack because being cut off is the thing the
    /// reader is here about; withholding ranks last not because it matters
    /// least but because a real verdict elsewhere on the page is more
    /// informative than a refusal.
    static func ledeRank(_ verdict: PlanFitVerdict) -> Int {
        switch verdict.outcome {
        case .considerUpgrade: return 0
        case .considerDowngrade: return 1
        case .fits: return 2
        case .withheld: return 3
        }
    }

    static func primary(_ paired: [(WindowStatsSegment, PlanFitVerdict)])
        -> (WindowStatsSegment, PlanFitVerdict)?
    {
        paired.min { a, b in
            let ra = ledeRank(a.1), rb = ledeRank(b.1)
            if ra != rb { return ra < rb }
            // More worked windows = more to say. Then a total order on the
            // segment identity, so the same data always elects the same lede.
            if a.0.activeUse.activeCount != b.0.activeUse.activeCount {
                return a.0.activeUse.activeCount > b.0.activeUse.activeCount
            }
            return (a.0.provider, a.0.kind, a.0.limitId) < (b.0.provider, b.0.kind, b.0.limitId)
        }
    }

    static func verdictLede(_ paired: [(WindowStatsSegment, PlanFitVerdict)]) -> PlanFitLede {
        guard let (segment, verdict) = primary(paired) else { return noDataLede() }
        let statement = verdict.statement()
        let kind: PlanFitLede.Kind = {
            switch verdict.outcome {
            case .withheld: return .withheld
            case .fits: return .fits
            case .considerUpgrade: return .considerUpgrade
            case .considerDowngrade: return .considerDowngrade
            }
        }()
        let scope = "\(PlanFitFormat.providerTitle(segment.provider)) · "
            + PlanFitFormat.limitTitle(
                provider: segment.provider, kind: segment.kind, limitId: segment.limitId
            )
        let others = paired.count - 1
        let detail = others > 0
            ? L.tr(
                "다른 한도 \(others)개의 상태는 아래에 따로 있습니다 — 한 한도의 판정이 나머지를 대신하지 않습니다.",
                "\(others) other limits are reported separately below — one limit's verdict does not stand in for the rest."
            )
            : nil
        return PlanFitLede(
            kind: kind,
            headline: statement.headline,
            scope: scope,
            headroom: statement.sensitivity.map(HeadroomNote.init),
            basis: statement.basis,
            availability: statement.availability,
            detail: detail
        )
    }

    static func noDataLede() -> PlanFitLede {
        PlanFitLede(
            kind: .noData,
            headline: L.tr("아직 판정할 근거가 없습니다", "There is nothing to judge from yet"),
            scope: nil,
            headroom: nil,
            basis: nil,
            availability: nil,
            detail: L.tr(
                "toki 데몬(v2.3+)이 사용량 윈도우를 기록하기 시작하면 여기에 쌓입니다. Codex는 과거 세션에서 즉시 복원되고, Claude는 수집 시작 후 4주에 걸쳐 채워집니다. 이것은 오류가 아니라 1일차의 정상 상태입니다.",
                "Windows accumulate here once the toki daemon (v2.3+) records them. Codex history backfills immediately; Claude fills in over about four weeks from the start of collection. This is day one, not a failure."
            )
        )
    }

    static func failedLede() -> PlanFitLede {
        PlanFitLede(
            kind: .loadFailed,
            headline: L.tr("윈도우 데이터를 불러오지 못했습니다", "Window data could not be loaded"),
            scope: nil,
            headroom: nil,
            basis: nil,
            availability: nil,
            detail: L.tr(
                "로컬 데몬과 동기화 서버 양쪽이 응답하지 않았습니다. 데이터가 없는 것과는 다른 상태라 빈 화면 대신 이렇게 알립니다 — toki 데몬(v2.3+)과 동기화 연결을 확인하세요.",
                "Neither the local daemon nor the sync server answered. That is a different state from having no data, which is why this is not an empty screen — check the toki daemon (v2.3+) and the sync connection."
            )
        )
    }

    static func loadingLede() -> PlanFitLede {
        PlanFitLede(
            kind: .loading,
            headline: L.tr("윈도우 기록을 읽는 중입니다", "Reading the window history"),
            scope: nil, headroom: nil, basis: nil, availability: nil, detail: nil
        )
    }

    // MARK: Trend

    static func trend(
        rows: [(provider: String, row: WindowRow)],
        unit: PeriodUnit,
        nowMs: Int64
    ) -> PeriodTrendModel {
        let finalized = rows.map(\.row).filter(\.finalized)
        guard !finalized.isEmpty else { return .empty }

        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        let samples = finalized.map {
            UsageSample(
                date: Date(timeIntervalSince1970: Double($0.windowEndMs) / 1000),
                amount: Double($0.activeMs) / 3_600_000
            )
        }
        let periods = PeriodAggregation.aggregate(samples: samples, unit: unit, now: now)
        guard !periods.isEmpty else { return .empty }

        // Exhaustions are counted into the bucket their window closed in, on
        // the same boundaries — a second bucketing rule here is how the two
        // rows of the same chart start disagreeing.
        let exhaustionDates = finalized.filter(\.maxedOut).map {
            Date(timeIntervalSince1970: Double($0.windowEndMs) / 1000)
        }

        let tallest = periods.map(\.total).max() ?? 0
        let bars = periods.map { period -> PeriodTrendModel.Bar in
            let exhaustions = exhaustionDates.filter { $0 >= period.start && $0 < period.end }.count
            // Monthly mode leads with the length-neutral rate; weekly buckets
            // are all seven days long, so the total-based rate is honest there
            // and is the more direct reading.
            let useDaily = unit == .monthly || period.totalChangeRatePct == nil
            let rate = useDaily ? period.dailyAverageChangeRatePct : period.totalChangeRatePct
            return PeriodTrendModel.Bar(
                id: period.start,
                label: period.displayLabel(),
                hours: period.total,
                dailyAverageHours: period.dailyAverage,
                isComplete: period.isComplete,
                incompleteNote: period.incompleteNote,
                changeRatePct: rate,
                changeIsDailyAverage: useDaily && rate != nil,
                exhaustions: exhaustions,
                heightFraction: tallest > 0 ? min(1, max(0, period.total / tallest)) : 0,
                accessibilityLabel: barAccessibilityLabel(
                    period: period, exhaustions: exhaustions, rate: rate, rateIsDaily: useDaily
                )
            )
        }

        let total = periods.reduce(0) { $0 + $1.total }
        return PeriodTrendModel(
            unit: unit,
            bars: bars,
            totalHours: total,
            spanNote: L.tr(
                "최근 \(Int(WindowStats.lookbackDays))일 · 기록된 실사용 시간 \(PlanFitFormat.hours(total)) 이상",
                "Trailing \(Int(WindowStats.lookbackDays)) days · at least \(PlanFitFormat.hours(total)) of recorded work"
            )
        )
    }

    static func barAccessibilityLabel(
        period: Period, exhaustions: Int, rate: Double?, rateIsDaily: Bool
    ) -> String {
        var parts = [period.displayLabel()]
        parts.append(L.tr(
            "기록된 실사용 \(PlanFitFormat.hours(period.total)) 이상",
            "at least \(PlanFitFormat.hours(period.total)) of recorded work"
        ))
        if let average = period.dailyAverage {
            parts.append(L.tr(
                "일평균 \(PlanFitFormat.hours(average))",
                "\(PlanFitFormat.hours(average)) per day"
            ))
        }
        if let change = PlanFitFormat.changeRate(rate) {
            parts.append(rateIsDaily
                ? L.tr("일평균 대비 \(change)", "\(change) on the daily average")
                : L.tr("총량 대비 \(change)", "\(change) on the total"))
        }
        if exhaustions > 0 {
            parts.append(L.tr("소진 \(exhaustions)회", "\(exhaustions) exhaustions"))
        }
        if let note = period.incompleteNote { parts.append(note) }
        return parts.joined(separator: ", ")
    }

    // MARK: Limit status

    static func limitGroups(
        _ paired: [(WindowStatsSegment, PlanFitVerdict)],
        rows: [(provider: String, row: WindowRow)],
        nowMs: Int64
    ) -> [LimitProviderGroup] {
        var open: [String: [WindowRow]] = [:]
        for (provider, row) in rows where row.isOpen(nowMs: nowMs) {
            open["\(provider)|\(row.kind)|\(row.limitId)", default: []].append(row)
        }

        var byProvider: [String: [LimitStatusModel]] = [:]
        var order: [String] = []
        for (segment, verdict) in paired {
            if byProvider[segment.provider] == nil { order.append(segment.provider) }
            byProvider[segment.provider, default: []].append(
                limitStatus(
                    segment: segment,
                    verdict: verdict,
                    openWindows: open["\(segment.provider)|\(segment.kind)|\(segment.limitId)"] ?? []
                )
            )
        }
        return order.map { provider in
            LimitProviderGroup(
                id: provider,
                providerTitle: PlanFitFormat.providerTitle(provider),
                limits: byProvider[provider] ?? []
            )
        }
    }

    static func limitStatus(
        segment: WindowStatsSegment,
        verdict: PlanFitVerdict,
        openWindows: [WindowRow]
    ) -> LimitStatusModel {
        let censored = segment.p95IsCensored
        let distribution = segment.p50Peak == nil
            ? L.tr("분포를 낼 표본이 없습니다", "no sample to distribute")
            : [
                "p50 \(PlanFitFormat.pct(segment.p50Peak))",
                "p90 \(PlanFitFormat.pct(segment.p90Peak))",
                "p95 \(PlanFitFormat.pctAtLeast(segment.p95Peak, isLowerBound: censored))",
            ].joined(separator: " · ")

        let excluded = segment.activeWindowCount - segment.coveredCount
        let hardStops = segment.maxedCount - (segment.sawCreditOverflow ? creditOverflowCount(segment) : 0)

        var exhaustion: String
        if segment.maxedCount == 0 {
            exhaustion = L.tr("소진 0회", "never ran out")
        } else if segment.sawCreditOverflow {
            exhaustion = L.tr(
                "소진 \(segment.maxedCount)회 — 하드 스톱 \(hardStops)회 · 크레딧 초과 \(creditOverflowCount(segment))회",
                "\(segment.maxedCount) exhaustions — \(hardStops) hard stops · \(creditOverflowCount(segment)) continued on credits"
            )
        } else {
            exhaustion = L.tr(
                "소진 \(segment.maxedCount)회 — 전부 하드 스톱",
                "\(segment.maxedCount) exhaustions — all hard stops"
            )
        }
        if let median = segment.medianTimeTo100Sec {
            exhaustion += L.tr(
                " · 중앙값 \(PlanFitFormat.duration(seconds: median))만에 도달",
                " · median \(PlanFitFormat.duration(seconds: median)) to reach the limit"
            )
        }

        let statement = verdict.statement()
        let withheld: String? = verdict.isWithheld
            ? [statement.headline, statement.availability].compactMap { $0 }.joined(separator: " ")
            : nil

        return LimitStatusModel(
            id: "\(segment.provider)|\(segment.kind)|\(segment.limitId)|\(segment.plan)|\(segment.account)",
            title: PlanFitFormat.limitTitle(
                provider: segment.provider, kind: segment.kind, limitId: segment.limitId
            ),
            planLabel: segment.plan.isEmpty ? nil : segment.plan,
            isHistorical: segment.advice == .historical,
            distribution: distribution,
            // A censored percentile is a floor on demand, not an observation
            // of it.
            distributionProvenance: censored ? .lowerBound : .observed,
            meterP50: segment.p50Peak,
            meterP95: segment.p95Peak,
            meterIsCensored: censored,
            sampleText: L.tr(
                "완료 창 \(segment.activeWindowCount)개 · 분포 표본 \(segment.coveredCount)개",
                "\(segment.activeWindowCount) finished windows · \(segment.coveredCount) in the distribution"
            ),
            excludedText: excluded > 0
                ? L.tr(
                    "리셋 직전을 관측하지 못한 \(excluded)개는 분포에서 제외했습니다 — 기기가 자고 있었다면 그 창의 peak은 하한입니다.",
                    "\(excluded) windows were not observed through to their reset and are out of the distribution — with the machine asleep their peak is only a floor."
                )
                : nil,
            exhaustionText: exhaustion,
            hasExhaustions: segment.maxedCount > 0,
            paidOverflowCredits: segment.sawCreditOverflow,
            openWindowText: openWindowText(openWindows),
            headroom: statement.sensitivity.map(HeadroomNote.init),
            withheldText: withheld
        )
    }

    /// The segment records only whether credit overflow was seen at all, so
    /// the count is the exhaustions the breakdown can attribute to it.
    static func creditOverflowCount(_ segment: WindowStatsSegment) -> Int {
        segment.activeUse.exhaustions.filter(\.hitCredits).count
    }

    static func openWindowText(_ open: [WindowRow]) -> String? {
        guard !open.isEmpty else { return nil }
        let live = open.map(\.livePct).max() ?? 0
        return L.tr(
            "진행 중인 창 \(open.count)개 · 현재 \(PlanFitFormat.pct(live)) — 완료 통계의 표본에는 들어가지 않습니다",
            "\(open.count) window(s) still running · currently \(PlanFitFormat.pct(live)) — kept out of the finished-window sample"
        )
    }

    // MARK: Active use

    static func activeUse(_ paired: [(WindowStatsSegment, PlanFitVerdict)]) -> [ActiveUseLimitModel] {
        paired.compactMap { segment, _ in
            let breakdown = segment.activeUse
            guard breakdown.activeCount > 0 || !breakdown.exhaustions.isEmpty else { return nil }
            return activeUseModel(segment)
        }
    }

    static func quietLimitsNote(_ paired: [(WindowStatsSegment, PlanFitVerdict)]) -> String? {
        let quiet = paired.filter { segment, _ in
            segment.activeUse.activeCount == 0 && segment.activeUse.exhaustions.isEmpty
        }
        guard !quiet.isEmpty else { return nil }
        let names = quiet.map { segment, _ in
            PlanFitFormat.limitTitle(
                provider: segment.provider, kind: segment.kind, limitId: segment.limitId
            )
        }
        return L.tr(
            "확인된 실사용도 소진도 없는 한도: \(names.joined(separator: ", ")) — 소진 현황에는 그대로 있습니다.",
            "No confirmed work and no exhaustion on: \(names.joined(separator: ", ")) — their status is still above."
        )
    }

    static func activeUseModel(_ segment: WindowStatsSegment) -> ActiveUseLimitModel {
        let breakdown = segment.activeUse
        let id = "\(segment.provider)|\(segment.kind)|\(segment.limitId)"
        let title = "\(PlanFitFormat.providerTitle(segment.provider)) · "
            + PlanFitFormat.limitTitle(
                provider: segment.provider, kind: segment.kind, limitId: segment.limitId
            )

        let splits = [
            split(
                id: "\(id)|active",
                title: L.tr("실사용이 확인된 창", "Worked in"),
                distribution: breakdown.active,
                isHeadroomSource: true,
                note: L.tr(
                    "여유폭은 이 집합에서만 계산합니다.",
                    "Headroom is read from this set and no other."
                )
            ),
            split(
                id: "\(id)|idle",
                title: L.tr("사용이 없었던 창", "Confirmed unused"),
                distribution: breakdown.noActiveUse,
                isHeadroomSource: false,
                note: L.tr(
                    "여유의 근거로 쓰지 않습니다 — 자느라 못 쓴 시간은 남는 한도가 아닙니다.",
                    "Never counted as headroom — a limit you were asleep through is not a limit you had to spare."
                )
            ),
            split(
                id: "\(id)|unknown",
                title: L.tr("판단 불가", "Cannot tell"),
                distribution: breakdown.cannotTell,
                isHeadroomSource: false,
                note: L.tr(
                    "실사용 시간이 하한이라 '사용 없음'으로 단정하지 않습니다 — 데몬이 재시작하면 누적이 0부터 다시 시작합니다.",
                    "Recorded work time is a floor, so these are not called unused — the daemon's accumulation restarts with the daemon."
                )
            ),
        ]

        let ticks = breakdown.exhaustions.map { event in
            ActiveUseLimitModel.Tick(
                id: event.windowEndMs,
                fractionLeft: event.fractionLeft,
                severity: severity(event)
            )
        }

        let recent = breakdown.exhaustions.suffix(spelledOutEventLimit).reversed().map { event in
            ActiveUseLimitModel.Event(
                id: event.windowEndMs,
                day: PlanFitFormat.day(event.windowEndMs),
                text: eventText(event),
                severity: severity(event),
                hitCredits: event.hitCredits
            )
        }

        let breakdownText: String
        if breakdown.exhaustions.isEmpty {
            breakdownText = L.tr("이 한도에서는 소진이 없었습니다", "This limit never ran out")
        } else {
            breakdownText = L.tr(
                "소진 \(breakdown.exhaustions.count)회 — 방해로 집계 \(breakdown.interruptingExhaustionCount)회 · 리셋 직전 \(breakdown.harmlessExhaustionCount)회 · 시점 불명 \(breakdown.unknownTimingExhaustionCount)회",
                "\(breakdown.exhaustions.count) exhaustions — \(breakdown.interruptingExhaustionCount) counted as interruptions · \(breakdown.harmlessExhaustionCount) just before a reset · \(breakdown.unknownTimingExhaustionCount) of unknown timing"
            )
        }

        return ActiveUseLimitModel(
            id: id,
            title: title,
            splits: splits,
            exhaustionBreakdown: breakdownText,
            medianTimeLeftText: breakdown.medianTimeLeftMs.map {
                L.tr(
                    "중앙값 \(PlanFitFormat.duration(ms: $0))을 남기고 소진했습니다",
                    "median exhaustion left \(PlanFitFormat.duration(ms: $0)) on the clock"
                )
            },
            interruptionRateText: breakdown.exhaustions.isEmpty
                ? nil
                : L.tr(
                    "잔여 시간으로 가중한 방해 빈도 주당 \(String(format: "%.1f", breakdown.interruptionsPerWeek))회",
                    "\(String(format: "%.1f", breakdown.interruptionsPerWeek)) interruptions per week, weighted by time left"
                ),
            ticks: ticks,
            recentEvents: Array(recent),
            thresholdNote: thresholdNote()
        )
    }

    static func split(
        id: String,
        title: String,
        distribution: UtilisationDistribution,
        isHeadroomSource: Bool,
        note: String
    ) -> ActiveUseLimitModel.Split {
        let text: String
        if distribution.count == 0 {
            text = L.tr("해당 없음", "none")
        } else if distribution.p50 == nil {
            text = L.tr("표본이 분포를 내기에 부족합니다", "too few samples to distribute")
        } else {
            text = "p50 \(PlanFitFormat.pct(distribution.p50)) · "
                + "p95 \(PlanFitFormat.pctAtLeast(distribution.p95, isLowerBound: distribution.isCensored))"
        }
        var fullNote = note
        if distribution.excludedForCoverage > 0 {
            fullNote += L.tr(
                " 리셋 미관측 \(distribution.excludedForCoverage)개는 분포에서 제외했습니다.",
                " \(distribution.excludedForCoverage) not observed through to reset are out of the distribution."
            )
        }
        return ActiveUseLimitModel.Split(
            id: id,
            title: title,
            count: distribution.count,
            distribution: text,
            provenance: distribution.isCensored ? .lowerBound : .observed,
            isHeadroomSource: isHeadroomSource,
            note: fullNote
        )
    }

    static func severity(_ event: ExhaustionEvent) -> ActiveUseLimitModel.Severity {
        guard event.fractionLeft != nil else { return .unknownTiming }
        let weight = event.interruptionWeight
        if weight <= 0 { return .harmless }
        if weight >= 1 { return .interrupting }
        return .partial
    }

    static func eventText(_ event: ExhaustionEvent) -> String {
        guard let left = event.timeLeftMs else {
            return L.tr(
                "소진 시점이 기록되지 않았습니다 — 남은 시간을 알 수 없어 방해로 집계합니다",
                "The moment it ran out was never sampled — with no time-left to read, it counts as an interruption"
            )
        }
        return L.tr(
            "리셋까지 \(PlanFitFormat.duration(ms: left)) 남기고 소진",
            "ran out with \(PlanFitFormat.duration(ms: left)) still on the clock"
        )
    }

    /// FR-021: the two thresholds that decide the split, where the numbers
    /// they produced are.
    static func thresholdNote() -> String {
        let floor = PlanFitFormat.duration(ms: WindowStats.activeUseFloorMs)
        let harmless = Int(WindowStats.harmlessExhaustionFractionLeft * 100)
        let full = Int(WindowStats.fullInterruptionFractionLeft * 100)
        return L.tr(
            "기준: 기록된 실사용 \(floor) 이상이면 '실사용', 주기의 \(harmless)% 이하를 남기고 소진하면 방해로 세지 않고, \(full)% 이상 남기고 소진하면 온전히 셉니다.",
            "Thresholds: \(floor) or more of recorded work counts as worked; running out with \(harmless)% or less of the cycle left counts as no interruption, and with \(full)% or more it counts in full."
        )
    }
}
