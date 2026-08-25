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

    /// The badge vocabulary for a domain outcome. One mapping, used by the
    /// lede and by every other limit's row, so the same outcome cannot pick up
    /// two different words on one screen.
    static func kind(for outcome: PlanFitVerdict.Outcome) -> Kind {
        switch outcome {
        case .withheld: return .withheld
        case .fits: return .fits
        case .considerUpgrade: return .considerUpgrade
        case .considerDowngrade: return .considerDowngrade
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

// MARK: - Every other limit's verdict

/// One segment's verdict as a row (T053).
///
/// The page elects one verdict to lead and has up to seven more. They are
/// carried individually rather than summarised, because "four fit and one
/// interrupts you" is a different account from "five fit" and the difference
/// is the whole reason the reader opened the page.
struct SegmentVerdictModel: Equatable, Sendable, Identifiable {
    let id: String
    /// The same badge vocabulary the lede uses.
    let kind: PlanFitLede.Kind
    /// "Claude Code · 주간 · Opus".
    let scope: String
    let headline: String
    /// Sensitivity and its inseparable caveat (V8). nil while withheld.
    let headroom: HeadroomNote?
    /// Present exactly when withheld: when a verdict becomes possible (V1).
    let availability: String?
    /// Lookback, sample size, statistic — on every row, withheld included (V3).
    let basis: String
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

// MARK: - Provider comparison (T054, T055 / contract W2, FR-022…FR-025)

/// Claude against Codex, on the axes where that means something.
///
/// Two facts make this harder than putting two numbers side by side, and both
/// of them are on screen rather than in a comment:
///
/// 1. **The two histories do not start at the same time.** Codex windows are
///    recovered retroactively from rollout files, so they reach back as far as
///    the files do; Claude windows exist only from the moment active polling
///    began. Comparing over each provider's own span would credit Codex with
///    weeks Claude was never watched for, so the comparison is computed on the
///    OVERLAP and the overlap is named.
/// 2. **The limit systems differ.** Claude splits its weekly limit by model;
///    every Codex window carries `limit_id="codex"`. Neither provider
///    publishes the absolute size of a limit, so 40% of one is not 40% of the
///    other — utilisation is reported per provider and never put on a shared
///    axis.
struct ProviderComparisonModel: Equatable, Sendable {

    enum State: Equatable, Sendable {
        /// Both providers have history and the spans overlap.
        case comparable
        /// Only one provider has any window history (T055).
        case singleProvider
        /// Both have history, but not at the same time — there is no period
        /// both were observed in, so there is nothing to compare over.
        case noOverlap
        /// No provider has history.
        case none
    }

    /// One comparable figure. Same unit on both sides or it does not belong
    /// here.
    struct Metric: Equatable, Sendable, Hashable, Identifiable {
        let id: String
        let label: String
        let value: String
        let provenance: Provenance
    }

    struct Side: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        /// This provider's own history, start to end.
        let historySpan: String
        /// How that history was obtained — retroactive recovery or live
        /// polling. This is why the two spans differ.
        let collectionNote: String
        /// Figures computed inside the common period only.
        let metrics: [Metric]
        /// The limit system, spelled out. Deliberately NOT a metric: it is the
        /// thing that makes the utilisation figures incomparable.
        let limitSystem: String
        /// Windows this provider has outside the common period, left out.
        let excludedNote: String?
    }

    let state: State
    /// "공통 기간 8월 8일 – 8월 26일 · 18일" — present whenever the state is
    /// `.comparable`, and required by FR-024.
    let commonPeriodNote: String?
    let sides: [Side]
    /// Why utilisation is not on one axis (FR-023).
    let incomparableNote: String
    /// Present on `.singleProvider` and `.noOverlap`: what is missing and why
    /// that is not evidence of anything.
    let unavailableNote: String?

    static let none = ProviderComparisonModel(
        state: .none, commonPeriodNote: nil, sides: [],
        incomparableNote: "", unavailableNote: nil
    )

    var isPresentable: Bool { state != .none }
}

// MARK: - The page

/// Everything the page draws.
struct PlanFitModel: Equatable, Sendable {
    let unit: PeriodUnit
    let lede: PlanFitLede
    /// The verdicts the lede did not speak for — one row per remaining limit.
    let otherVerdicts: [SegmentVerdictModel]
    let trend: PeriodTrendModel
    let limitGroups: [LimitProviderGroup]
    let activeUse: [ActiveUseLimitModel]
    /// Claude against Codex on the overlap of their histories (T054, T055).
    let comparison: ProviderComparisonModel
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
            otherVerdicts: otherVerdicts(paired),
            trend: trend(rows: rows, unit: unit, nowMs: nowMs),
            limitGroups: limitGroups(paired, rows: rows, nowMs: nowMs),
            activeUse: activeUse(paired),
            comparison: comparison(rows: rows, nowMs: nowMs),
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
        let kind = PlanFitLede.kind(for: verdict.outcome)
        let scope = scopeLabel(segment)
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

    /// "Claude Code · 주간 · Opus". Provider first because two providers'
    /// limits can carry the same name and mean different systems.
    static func scopeLabel(_ segment: WindowStatsSegment) -> String {
        "\(PlanFitFormat.providerTitle(segment.provider)) · "
            + PlanFitFormat.limitTitle(
                provider: segment.provider, kind: segment.kind, limitId: segment.limitId
            )
    }

    /// Every verdict except the one that leads the page (T053).
    ///
    /// Ordered the way the lede was elected — an interruption first, a
    /// withholding last — so a reader scanning down meets the limits that have
    /// something to say before the ones that are still collecting.
    static func otherVerdicts(
        _ paired: [(WindowStatsSegment, PlanFitVerdict)]
    ) -> [SegmentVerdictModel] {
        guard let (ledeSegment, _) = primary(paired) else { return [] }
        let ledeId = segmentKey(ledeSegment)
        return paired
            .filter { segmentKey($0.0) != ledeId }
            .sorted { a, b in
                let ra = ledeRank(a.1), rb = ledeRank(b.1)
                if ra != rb { return ra < rb }
                return segmentKey(a.0) < segmentKey(b.0)
            }
            .map { segment, verdict in
                let statement = verdict.statement()
                return SegmentVerdictModel(
                    id: segmentKey(segment),
                    kind: PlanFitLede.kind(for: verdict.outcome),
                    scope: scopeLabel(segment),
                    headline: statement.headline,
                    headroom: statement.sensitivity.map(HeadroomNote.init),
                    availability: statement.availability,
                    basis: statement.basis
                )
            }
    }

    /// Identity of a segment on this page. Plan and account are part of it:
    /// the same limit under two tiers is two segments, and merging them would
    /// blend percentages whose denominators differ.
    static func segmentKey(_ segment: WindowStatsSegment) -> String {
        "\(segment.provider)|\(segment.kind)|\(segment.limitId)|\(segment.plan)|\(segment.account)"
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

    /// Finished windows to read recorded work time off, one series per
    /// provider.
    ///
    /// A provider reports several OVERLAPPING window series: Claude's
    /// five-hour windows sit inside its weekly ones, and its model-scoped
    /// weekly limits cover the same days again. Every one of those rows
    /// accumulates its own `activeMs` over the same work, so summing every row
    /// reports the same afternoon once per limit the account happens to have —
    /// four times over on a Claude account, and the figure grows when a
    /// provider adds a limit rather than when the user works more.
    ///
    /// Within one series windows do not overlap, so this picks one per
    /// provider — the series with the most finished windows, which is the
    /// finest-grained one and therefore the one that resolves the work best —
    /// and reads only that. Session before weekly on a tie for the same
    /// reason.
    static func workTimeRows(_ rows: [(provider: String, row: WindowRow)]) -> [WindowRow] {
        var series: [String: [String: [WindowRow]]] = [:]
        for (provider, row) in rows where row.finalized {
            series[provider, default: [:]]["\(row.kind)|\(row.limitId)", default: []].append(row)
        }
        return series.keys.sorted().flatMap { provider -> [WindowRow] in
            let byLimit = series[provider] ?? [:]
            let chosen = byLimit.max { a, b in
                if a.value.count != b.value.count { return a.value.count < b.value.count }
                let aSession = a.key.hasPrefix("session|"), bSession = b.key.hasPrefix("session|")
                if aSession != bSession { return bSession }
                return a.key > b.key
            }
            return chosen?.value ?? []
        }
    }

    static func trend(
        rows: [(provider: String, row: WindowRow)],
        unit: PeriodUnit,
        nowMs: Int64
    ) -> PeriodTrendModel {
        let finalized = workTimeRows(rows)
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
        //
        // Counted over EVERY limit, not just the series the hours came from:
        // overlapping series double-count the same hour of work, but running
        // out of the weekly limit and running out of the five-hour limit are
        // two separate times the user was stopped.
        let exhaustionDates = rows.map(\.row).filter { $0.finalized && $0.maxedOut }.map {
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
        // `maxedCount` and the exhaustion list are counted over the same rows,
        // but the subtraction is clamped anyway: a negative "hard stops" would
        // be a arithmetic artefact printed as a fact about the account.
        let hardStops = max(0, segment.maxedCount - creditOverflowCount(segment))

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
            id: segmentKey(segment),
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

// MARK: - Provider comparison (T054, T055)

extension PlanFitModelBuilder {

    /// The two providers, compared only where comparing means something.
    ///
    /// Everything below the common period is computed by handing the domain a
    /// row set already clipped to the overlap — `WindowStats.segments` does the
    /// statistics, this decides what may be put beside what.
    static func comparison(
        rows: [(provider: String, row: WindowRow)],
        nowMs: Int64
    ) -> ProviderComparisonModel {
        var byProvider: [String: [WindowRow]] = [:]
        for (provider, row) in rows where row.finalized {
            byProvider[provider, default: []].append(row)
        }
        let providers = byProvider.keys.sorted()
        guard !providers.isEmpty else { return .none }

        // T055 — one provider is not a comparison. Say what is missing and,
        // importantly, that its absence proves nothing about usage.
        guard providers.count > 1 else {
            let present = providers[0]
            return ProviderComparisonModel(
                state: .singleProvider,
                commonPeriodNote: nil,
                sides: [
                    side(
                        provider: present,
                        allRows: byProvider[present] ?? [],
                        inCommon: byProvider[present] ?? [],
                        nowMs: nowMs
                    ),
                ],
                incomparableNote: incomparableNote,
                unavailableNote: missingProviderNote(present: present)
            )
        }

        // Each provider's own span, then the intersection.
        var spans: [String: (start: Int64, end: Int64)] = [:]
        for provider in providers {
            let ends = (byProvider[provider] ?? []).map(\.windowEndMs)
            guard let first = ends.min(), let last = ends.max() else { continue }
            spans[provider] = (first, last)
        }
        let commonStart = spans.values.map(\.start).max() ?? 0
        let commonEnd = spans.values.map(\.end).min() ?? 0

        // Disjoint histories. This is a real state — a user who stopped using
        // one provider before starting the other — and inventing an overlap
        // for it would compare two different months.
        guard commonEnd > commonStart else {
            return ProviderComparisonModel(
                state: .noOverlap,
                commonPeriodNote: nil,
                sides: providers.map {
                    side(provider: $0, allRows: byProvider[$0] ?? [], inCommon: [], nowMs: nowMs)
                },
                incomparableNote: incomparableNote,
                unavailableNote: L.tr(
                    "두 공급자의 기록이 겹치는 기간이 없습니다. 같은 기간을 관측한 적이 없어 나란히 놓을 수 없고, 각자의 기간을 그대로 비교하면 서로 다른 달을 비교하게 됩니다.",
                    "The two histories never overlap. There is no period both were observed in, and comparing each provider's own span would be comparing different months."
                )
            )
        }

        let days = max(1, Int(((commonEnd - commonStart) / 86_400_000)))
        return ProviderComparisonModel(
            state: .comparable,
            commonPeriodNote: L.tr(
                "공통 기간 \(PlanFitFormat.day(commonStart)) – \(PlanFitFormat.day(commonEnd)) · \(days)일. 아래 수치는 전부 이 기간 안에서만 셌습니다.",
                "Common period \(PlanFitFormat.day(commonStart)) – \(PlanFitFormat.day(commonEnd)) · \(days) days. Every figure below is counted inside it and nowhere else."
            ),
            sides: providers.map { provider in
                let all = byProvider[provider] ?? []
                return side(
                    provider: provider,
                    allRows: all,
                    inCommon: all.filter { $0.windowEndMs >= commonStart && $0.windowEndMs <= commonEnd },
                    nowMs: nowMs
                )
            },
            incomparableNote: incomparableNote,
            unavailableNote: nil
        )
    }

    /// FR-023. The one sentence that stops the two columns being read as one
    /// scale.
    static var incomparableNote: String {
        L.tr(
            "소진율은 한 축에 올리지 않습니다. 퍼센트의 분모는 각 공급자가 공개하지 않는 자기 한도라서, 한쪽의 40%와 다른 쪽의 40%는 같은 양이 아닙니다. 위의 수치는 시간과 횟수 — 두 공급자에서 같은 단위인 것 — 뿐입니다.",
            "Utilisation is not put on a shared axis. Each percentage is relative to that provider's own undisclosed limit, so 40% on one side is not the same quantity as 40% on the other. What is compared above is time and counts — the units that mean the same thing on both sides."
        )
    }

    static func missingProviderNote(present: String) -> String {
        let missing: String
        switch present {
        case "codex": missing = PlanFitFormat.providerTitle("claude_code")
        case "claude_code": missing = PlanFitFormat.providerTitle("codex")
        default: missing = L.tr("다른 공급자", "the other provider")
        }
        return L.tr(
            "\(missing) 쪽에는 윈도우 기록이 없어 비교 대신 단독 표시로 줄였습니다. 쓰지 않았을 수도 있고, 폴링이 꺼져 있거나 로그인이 만료됐을 수도 있습니다 — 기록이 없다는 것은 사용이 없었다는 증거가 아닙니다.",
            "There are no windows on the \(missing) side, so this is a single-provider readout rather than a comparison. It may be unused, or polling may be off, or the login may have expired — an absence of records is not evidence of an absence of use."
        )
    }

    /// One provider's column.
    ///
    /// `allRows` sets the history span; `inCommon` is what the figures are
    /// counted over. Keeping them separate is what lets the column say "18 of
    /// my 46 windows are outside the compared period" instead of quietly
    /// dropping them.
    static func side(
        provider: String,
        allRows: [WindowRow],
        inCommon: [WindowRow],
        nowMs: Int64
    ) -> ProviderComparisonModel.Side {
        let ends = allRows.map(\.windowEndMs)
        let span = (ends.min()).flatMap { first in
            ends.max().map { last in
                L.tr(
                    "기록 \(PlanFitFormat.day(first)) – \(PlanFitFormat.day(last))",
                    "History \(PlanFitFormat.day(first)) – \(PlanFitFormat.day(last))"
                )
            }
        } ?? L.tr("기록 없음", "no history")

        let segments = WindowStats.segments(
            rows: inCommon.map { (provider, $0) }, nowMs: nowMs
        )
        let workHours = workTimeRows(inCommon.map { (provider, $0) })
            .reduce(0.0) { $0 + Double($1.activeMs) / 3_600_000 }
        let exhaustions = inCommon.filter(\.maxedOut).count
        let workedWindows = segments.reduce(0) { $0 + $1.activeUse.activeCount }
        let interruptions = segments.reduce(0.0) { $0 + $1.activeUse.interruptionsPerWeek }

        let excluded = allRows.count - inCommon.count
        return ProviderComparisonModel.Side(
            id: provider,
            title: PlanFitFormat.providerTitle(provider),
            historySpan: span,
            collectionNote: collectionNote(provider),
            metrics: [
                .init(
                    id: "\(provider)|hours",
                    label: L.tr("기록된 실사용 시간", "Recorded work time"),
                    value: PlanFitFormat.hours(workHours),
                    // `activeMs` restarts with the daemon, so this can only
                    // ever understate.
                    provenance: .lowerBound
                ),
                .init(
                    id: "\(provider)|worked",
                    label: L.tr("실사용이 확인된 창", "Windows worked in"),
                    value: L.tr("\(workedWindows)개 / 완료 \(inCommon.count)개",
                                "\(workedWindows) of \(inCommon.count)"),
                    provenance: .observed
                ),
                .init(
                    id: "\(provider)|exhaustions",
                    label: L.tr("한도 소진", "Times the limit ran out"),
                    value: L.tr("\(exhaustions)회", "\(exhaustions)"),
                    provenance: .observed
                ),
                .init(
                    id: "\(provider)|interruptions",
                    label: L.tr("방해 빈도 (주당)", "Interruptions per week"),
                    value: String(format: "%.1f", interruptions),
                    // Weighted by how much of the cycle was left (V5).
                    provenance: .derived
                ),
            ],
            limitSystem: limitSystem(inCommon.isEmpty ? allRows : inCommon),
            excludedNote: excluded > 0
                ? L.tr(
                    "공통 기간 밖의 창 \(excluded)개는 비교에서 뺐습니다 — 상대 공급자가 관측되지 않은 기간입니다.",
                    "\(excluded) windows fall outside the common period and are out of the comparison — the other provider was not being observed then."
                )
                : nil
        )
    }

    /// Contract W2. The two collection mechanisms, which is the reason the two
    /// spans differ at all.
    static func collectionNote(_ provider: String) -> String {
        switch provider {
        case "codex":
            return L.tr(
                "rollout 로그에서 소급 복원 — 파일이 남아 있는 만큼 과거가 있습니다.",
                "Recovered retroactively from rollout logs — history reaches as far back as the files do."
            )
        case "claude_code":
            return L.tr(
                "능동 폴링 — 폴링을 시작한 뒤의 창만 있고, 그 이전은 복원할 수 없습니다.",
                "Active polling — windows exist only from when polling started, and nothing earlier can be recovered."
            )
        default:
            return L.tr("수집 방식이 확인되지 않았습니다.", "The collection method is not known.")
        }
    }

    /// The limit series this provider actually reports. Claude splits its
    /// weekly limit by model; Codex reports one `limit_id` for everything.
    static func limitSystem(_ rows: [WindowRow]) -> String {
        var seen: [String] = []
        for row in rows {
            let key = "\(row.kind)|\(row.limitId)"
            if !seen.contains(key) { seen.append(key) }
        }
        guard !seen.isEmpty else { return L.tr("한도 없음", "no limits reported") }
        let names = seen.sorted().map { key -> String in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            return PlanFitFormat.limitTitle(
                provider: "", kind: parts.first ?? "", limitId: parts.count > 1 ? parts[1] : ""
            )
        }
        return L.tr("한도 \(seen.count)종 · \(names.joined(separator: ", "))",
                    "\(seen.count) limit series · \(names.joined(separator: ", "))")
    }
}
