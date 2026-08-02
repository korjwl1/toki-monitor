import Foundation

// MARK: - Window statistics (plan-fit analytics)
//
// Pure functions over [WindowRow]. Statistical choices follow cloud
// right-sizing practice (see the design plan §2/§7):
// - trailing 28 days (4 weekly cycles), finalized windows only
// - percentile-of-peaks, never means-of-means
// - 100% windows are right-censored: counted and extrapolated, not averaged in
// - low-coverage windows (big gap between last sample and reset) are lower
//   bounds — they count toward maxed-out but are excluded from percentiles
// - statistics are segmented by plan tier and account: a peak percentage is
//   relative to the tier's limit, so mixing tiers corrupts every number

/// One statistics segment: same provider, window kind, tier, and account.
struct WindowStatsSegment: Equatable, Hashable {
    let provider: String
    let kind: String            // "session" | "weekly"
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
    /// Mean peak over active windows ("사용 중 평균").
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
    /// Anchor of the newest window (current-segment detection).
    let newestWindowEndMs: Int64

    let advice: TierAdvice

    func replacingAdvice(_ advice: TierAdvice) -> WindowStatsSegment {
        WindowStatsSegment(
            provider: provider, kind: kind, plan: plan, account: account,
            activeWindowCount: activeWindowCount, maxedCount: maxedCount,
            medianTimeTo100Sec: medianTimeTo100Sec,
            p50Peak: p50Peak, p90Peak: p90Peak, p95Peak: p95Peak,
            p95IsCensored: p95IsCensored,
            meanPeakActive: meanPeakActive, approxOverallMean: approxOverallMean,
            dutyCycle: dutyCycle, impliedDemandP90: impliedDemandP90,
            sawCreditOverflow: sawCreditOverflow, observedDays: observedDays,
            newestWindowEndMs: newestWindowEndMs, advice: advice
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
}

enum WindowStats {

    static let lookbackDays: Double = 28
    /// A last-sample gap beyond this means the recorded peak is a lower bound
    /// (machine asleep at reset) — excluded from percentiles.
    static let coverageGapLimitMs: Int64 = 30 * 60_000

    /// Compute all segments from raw rows (any providers/kinds mixed).
    /// `nowMs` is injectable for tests.
    static func segments(
        rows: [(provider: String, row: WindowRow)],
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> [WindowStatsSegment] {
        let cutoff = nowMs - Int64(lookbackDays * 86_400_000)
        let eligible = rows.filter { $0.row.finalized && $0.row.windowEndMs >= cutoff }

        var groups: [String: [(String, WindowRow)]] = [:]
        for (provider, row) in eligible {
            let key = [provider, row.kind, row.plan, row.account].joined(separator: "|")
            groups[key, default: []].append((provider, row))
        }

        var segments = groups.values.compactMap { group -> WindowStatsSegment? in
            guard let first = group.first else { return nil }
            let rows = group.map(\.1)
            return segment(
                provider: first.0,
                kind: first.1.kind,
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
        var newestByKey: [String: Int64] = [:]
        for s in segments {
            let key = "\(s.provider)|\(s.kind)"
            newestByKey[key] = max(newestByKey[key] ?? 0, s.newestWindowEndMs)
        }
        segments = segments.map { s in
            let key = "\(s.provider)|\(s.kind)"
            if s.newestWindowEndMs < (newestByKey[key] ?? 0) {
                return s.replacingAdvice(.evidenceOnly)
            }
            return s
        }
        return segments.sorted { ($0.provider, $0.kind) < ($1.provider, $1.kind) }
    }

    static func segment(
        provider: String,
        kind: String,
        plan: String,
        account: String,
        rows: [WindowRow],
        nowMs: Int64
    ) -> WindowStatsSegment? {
        // Active window := has usage (a row only exists after a >0% observation)
        // AND either recorded activity or a nonzero peak.
        let active = rows.filter { $0.activeMs > 0 || $0.peakPct > 0 }
        guard !active.isEmpty else { return nil }

        let maxed = active.filter(\.maxedOut)
        let wellCovered = active.filter { $0.lastSampleGapMs <= coverageGapLimitMs }
        // Percentiles use well-covered windows; censored (maxed) windows are
        // exact at ">=100", so they stay in the sample — percentiles below the
        // censoring fraction are unaffected, and we flag p95 when censored.
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
        let observedDays = Double(newest - oldest) / 86_400_000

        let meanPeakActive = active.isEmpty
            ? nil
            : active.map(\.peakPct).reduce(0, +) / Double(active.count)

        // Session windows exist only while used; approximate the overall mean
        // against the calendar slot count. Weekly windows always exist, so the
        // active mean IS the overall mean (approx nil to avoid double-reporting).
        var approxOverall: Double? = nil
        if kind == "session", let windowMinutes = active.first?.windowMinutes, windowMinutes > 0 {
            let slots = lookbackDays * 24 * 60 / Double(windowMinutes)
            approxOverall = active.map(\.peakPct).reduce(0, +) / max(slots, 1)
        }

        let wallMs = min(Int64(lookbackDays * 86_400_000), max(nowMs - oldest, 1))
        let dutyCycle = min(1.0, Double(active.map(\.activeMs).reduce(0, +)) / Double(wallMs))

        let medianT100 = percentile(t100s, 0.5)
        let seg = WindowStatsSegment(
            provider: provider,
            kind: kind,
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
            newestWindowEndMs: newest,
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
            let weeks = max(s.observedDays / 7, 1)
            let maxedPerWeek = Double(s.maxedCount) / weeks
            let windowMinutes: Double = s.kind == "session" ? 300 : 10_080
            let chronicEarlyExhaustion =
                (s.medianTimeTo100Sec ?? .infinity) < windowMinutes * 60 * 0.6

            if s.sawCreditOverflow {
                advice = .upgrade(reason: L.tr(
                    "이미 한도 초과분을 크레딧으로 지불 중 — 초과 지출이 티어 차액보다 크면 업그레이드가 저렴합니다",
                    "Already paying overflow via credits — upgrading is cheaper if overflow spend exceeds the tier gap"
                ))
            } else if maxedPerWeek >= 2 {
                advice = .upgrade(reason: L.tr(
                    "주당 \(String(format: "%.1f", maxedPerWeek))회 한도 소진",
                    "Hitting the limit \(String(format: "%.1f", maxedPerWeek))×/week"
                ))
            } else if let demand = s.impliedDemandP90, demand > 100 {
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
                      let p95 = s.p95Peak, p95 < 40, !s.p95IsCensored {
                // Downgrade is deliberately stricter than upgrade: it needs the
                // full 28-day lookback with zero exhaustion (plan §2).
                advice = .downgrade(reason: L.tr(
                    "28일간 소진 0회, p95 peak \(Int(p95))%",
                    "0 maxed windows in 28d, p95 peak \(Int(p95))%"
                ))
            } else {
                let p95Text = s.p95Peak.map { "\(Int($0))%" } ?? "-"
                advice = .keep(reason: L.tr(
                    "p95 peak \(p95Text), 소진 \(s.maxedCount)회 — 적정",
                    "p95 peak \(p95Text), \(s.maxedCount) maxed — right-sized"
                ))
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
