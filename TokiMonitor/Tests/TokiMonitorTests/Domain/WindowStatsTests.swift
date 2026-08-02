import XCTest
@testable import TokiMonitor

final class WindowStatsTests: XCTestCase {

    private let nowMs: Int64 = 1_786_000_000_000

    private func row(
        kind: String = "session",
        endOffsetDays: Double,
        peak: Double,
        maxed: Bool = false,
        timeTo100Ms: Int64 = -1,
        finalized: Bool = true,
        gapMs: Int64 = 1000,
        activeMs: Int64 = 3_600_000,
        plan: String = "max_5x",
        account: String = "a",
        limitReachedKind: Int = 0,
        windowMinutes: Int = 300
    ) -> WindowRow {
        let end = nowMs - Int64(endOffsetDays * 86_400_000)
        return WindowRow(
            kind: kind, limitId: kind == "session" ? "five_hour" : "seven_day",
            account: account, windowEndMs: end, rawResetsAtMs: end,
            windowMinutes: windowMinutes, peakPct: peak, lastPct: peak,
            observedTsMs: end - 1000, firstSeenMs: end - 3_600_000,
            finalized: finalized, maxedOut: maxed,
            limitReachedKind: maxed ? max(limitReachedKind, 1) : limitReachedKind,
            timeTo100Ms: timeTo100Ms, activeMs: activeMs,
            lastSampleGapMs: gapMs, nSamples: 10, plan: plan
        )
    }

    func testPercentileNearestRank() {
        let sorted: [Double] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        XCTAssertEqual(WindowStats.percentile(sorted, 0.5), 50)
        XCTAssertEqual(WindowStats.percentile(sorted, 0.9), 90)
        XCTAssertEqual(WindowStats.percentile(sorted, 0.95), 100)
        XCTAssertNil(WindowStats.percentile([], 0.5))
        XCTAssertEqual(WindowStats.percentile([42], 0.95), 42)
    }

    func testSegmentationSplitsTierAndKind() {
        var rows: [(provider: String, row: WindowRow)] = []
        // 15+ days on each tier so advice gating doesn't collapse to collecting.
        for d in 0..<16 {
            rows.append(("claude_code", row(endOffsetDays: Double(d), peak: 50, plan: "pro")))
            rows.append(("claude_code", row(endOffsetDays: Double(d), peak: 30, plan: "max_5x")))
            rows.append(("claude_code", row(kind: "weekly", endOffsetDays: Double(d), peak: 60, plan: "pro", windowMinutes: 10_080)))
        }
        let segments = WindowStats.segments(rows: rows, nowMs: nowMs)
        XCTAssertEqual(segments.count, 3) // (session,pro), (session,max_5x), (weekly,pro)
    }

    func testUnfinalizedAndOldWindowsExcluded() {
        let rows: [(provider: String, row: WindowRow)] = [
            ("codex", row(endOffsetDays: 1, peak: 50)),
            ("codex", row(endOffsetDays: 2, peak: 60, finalized: false)), // open
            ("codex", row(endOffsetDays: 40, peak: 90)), // outside 28d
        ]
        let segments = WindowStats.segments(rows: rows, nowMs: nowMs)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].activeWindowCount, 1)
    }

    func testCensoringFlagsP95AndCountsMaxed() {
        var rows: [(provider: String, row: WindowRow)] = []
        for d in 0..<15 {
            rows.append(("claude_code", row(endOffsetDays: Double(d), peak: 60)))
        }
        // Two censored windows (hit 100% after 2h of a 5h window).
        rows.append(("claude_code", row(endOffsetDays: 15, peak: 100, maxed: true, timeTo100Ms: 2 * 3_600_000)))
        rows.append(("claude_code", row(endOffsetDays: 16, peak: 100, maxed: true, timeTo100Ms: 3 * 3_600_000)))

        let segs = WindowStats.segments(rows: rows, nowMs: nowMs)
        XCTAssertEqual(segs.count, 1)
        let s = segs[0]
        XCTAssertEqual(s.maxedCount, 2)
        XCTAssertTrue(s.p95IsCensored)
        // median time-to-100 = 2.5h
        XCTAssertEqual(s.medianTimeTo100Sec ?? 0, 2 * 3600, accuracy: 1)
        // implied demand: 100 * 5h/2h = 250, 100 * 5h/3h ≈ 167 → p90 = 250
        XCTAssertEqual(s.impliedDemandP90 ?? 0, 250, accuracy: 1)
    }

    func testLowCoverageExcludedFromPercentilesButMaxedStillCounts() {
        var rows: [(provider: String, row: WindowRow)] = []
        for d in 0..<15 {
            rows.append(("codex", row(endOffsetDays: Double(d), peak: 30)))
        }
        // Slept through the reset: 2h gap → peak is a lower bound.
        rows.append(("codex", row(endOffsetDays: 15, peak: 95, gapMs: 2 * 3_600_000)))
        let s = WindowStats.segments(rows: rows, nowMs: nowMs)[0]
        XCTAssertEqual(s.p95Peak, 30) // 95-peak row excluded from percentile sample
        XCTAssertEqual(s.activeWindowCount, 16)
    }

    func testAdviceUpgradeOnFrequentMaxing() {
        var rows: [(provider: String, row: WindowRow)] = []
        for d in 0..<15 {
            let maxed = d % 2 == 0 // ~3.5 maxed/week
            rows.append(("claude_code", row(
                endOffsetDays: Double(d), peak: maxed ? 100 : 70,
                maxed: maxed, timeTo100Ms: maxed ? 4 * 3_600_000 : -1
            )))
        }
        let s = WindowStats.segments(rows: rows, nowMs: nowMs)[0]
        guard case .upgrade = s.advice else {
            return XCTFail("expected upgrade, got \(s.advice)")
        }
    }

    func testAdviceDowngradeOnConsistentlyLowPeaks() {
        // Downgrade needs the FULL 28-day lookback observed (stricter than
        // upgrade by design).
        var rows: [(provider: String, row: WindowRow)] = []
        for d in 0..<28 {
            rows.append(("claude_code", row(endOffsetDays: Double(d), peak: Double(10 + d % 10))))
        }
        let s = WindowStats.segments(rows: rows, nowMs: nowMs)[0]
        guard case .downgrade = s.advice else {
            return XCTFail("expected downgrade, got \(s.advice)")
        }
    }

    func testAdviceKeepInMiddleGround() {
        var rows: [(provider: String, row: WindowRow)] = []
        for d in 0..<20 {
            rows.append(("claude_code", row(endOffsetDays: Double(d), peak: Double(60 + d % 20))))
        }
        let s = WindowStats.segments(rows: rows, nowMs: nowMs)[0]
        guard case .keep = s.advice else {
            return XCTFail("expected keep, got \(s.advice)")
        }
    }

    func testAdviceGatedUntil14DaysOnTier() {
        let rows: [(provider: String, row: WindowRow)] = (0..<5).map {
            ("claude_code", row(endOffsetDays: Double($0), peak: 100, maxed: true, timeTo100Ms: 3_600_000))
        }
        let s = WindowStats.segments(rows: rows, nowMs: nowMs)[0]
        guard case .collecting = s.advice else {
            return XCTFail("expected collecting, got \(s.advice)")
        }
    }

    func testAdviceEvidenceOnlyWithoutPlan() {
        let rows: [(provider: String, row: WindowRow)] = (0..<20).map {
            ("codex", row(endOffsetDays: Double($0), peak: 100, maxed: true, timeTo100Ms: 3_600_000, plan: ""))
        }
        let s = WindowStats.segments(rows: rows, nowMs: nowMs)[0]
        XCTAssertEqual(s.advice, .evidenceOnly)
    }

    func testCreditOverflowDrivesUpgradeWording() {
        var rows: [(provider: String, row: WindowRow)] = []
        for d in 0..<16 {
            rows.append(("codex", row(
                endOffsetDays: Double(d), peak: 100, maxed: true,
                timeTo100Ms: 4 * 3_600_000, limitReachedKind: 2
            )))
        }
        let s = WindowStats.segments(rows: rows, nowMs: nowMs)[0]
        XCTAssertTrue(s.sawCreditOverflow)
        guard case .upgrade = s.advice else {
            return XCTFail("expected upgrade, got \(s.advice)")
        }
    }

    func testAdviceOnlyForCurrentTierSegment() {
        var rows: [(provider: String, row: WindowRow)] = []
        // Old tier: 15 days of heavy maxing, ending 10 days ago.
        for d in 13..<28 {
            rows.append(("claude_code", row(endOffsetDays: Double(d), peak: 100, maxed: true, timeTo100Ms: 3_600_000, plan: "pro")))
        }
        // Current tier: recent, calm.
        for d in 0..<13 {
            rows.append(("claude_code", row(endOffsetDays: Double(d), peak: 30, plan: "max_5x")))
        }
        let segs = WindowStats.segments(rows: rows, nowMs: nowMs)
        let old = segs.first { $0.plan == "pro" }!
        let current = segs.first { $0.plan == "max_5x" }!
        // The abandoned tier must not scream "upgrade" — evidence only.
        XCTAssertEqual(old.advice, .evidenceOnly)
        // The current tier has <14 days → collecting.
        guard case .collecting = current.advice else {
            return XCTFail("expected collecting, got \(current.advice)")
        }
    }

    func testOverallCalendarApproximationForSessionOnly() {
        var rows: [(provider: String, row: WindowRow)] = []
        for d in 0..<15 {
            rows.append(("claude_code", row(endOffsetDays: Double(d), peak: 67)))
            rows.append(("claude_code", row(kind: "weekly", endOffsetDays: Double(d), peak: 40, windowMinutes: 10_080)))
        }
        let segs = WindowStats.segments(rows: rows, nowMs: nowMs)
        let session = segs.first { $0.kind == "session" }!
        let weekly = segs.first { $0.kind == "weekly" }!
        // 15 windows × 67% over ~134 possible 5h slots ≈ 7.5%
        XCTAssertEqual(session.approxOverallMean ?? 0, 15.0 * 67.0 / (28.0 * 24 * 60 / 300), accuracy: 0.1)
        XCTAssertNil(weekly.approxOverallMean)
        XCTAssertEqual(weekly.meanPeakActive ?? 0, 40, accuracy: 0.1)
    }
}
