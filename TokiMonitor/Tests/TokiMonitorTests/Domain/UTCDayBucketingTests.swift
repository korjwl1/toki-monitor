import Testing
import Foundation
@testable import TokiMonitor

/// The model-usage query runs `toki query -z UTC`, so the dates it returns are
/// UTC midnights. Re-bucketing those with the local calendar pushes each one
/// into the previous local day anywhere west of Greenwich, and the per-model
/// change rate lands in the wrong week or month at the boundary.
///
/// This is invisible in KST — UTC+9 keeps a UTC midnight inside the same local
/// day — which is exactly why it survived review on a machine in Seoul. These
/// assert against calendars pinned to specific zones rather than whatever the
/// machine running them happens to use.
@Suite("A UTC day stays in its UTC period")
struct UTCDayBucketingTests {

    private func utcCalendar(firstWeekday: Int = 1) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = firstWeekday
        return c
    }

    private func calendar(in zone: String, firstWeekday: Int = 1) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.firstWeekday = firstWeekday
        return c
    }

    /// 2026-03-01T00:00Z is the first day of March in UTC. In New York it is
    /// 2026-02-28T19:00 — February. A month bucket built with the local
    /// calendar therefore files March's first day under February.
    @Test("a UTC month boundary is not pulled into the previous month")
    func monthBoundaryHoldsInUTC() throws {
        let marchFirstUTC = Date(timeIntervalSince1970: 1_772_323_200) // 2026-03-01T00:00:00Z
        let samples = [UsageSample(date: marchFirstUTC, amount: 1_000)]

        let utc = PeriodAggregation.aggregate(
            samples: samples, unit: .monthly,
            now: marchFirstUTC, calendar: utcCalendar()
        )
        let newYork = PeriodAggregation.aggregate(
            samples: samples, unit: .monthly,
            now: marchFirstUTC, calendar: calendar(in: "America/New_York")
        )

        let utcMonth = try #require(utc.last.map { utcCalendar().component(.month, from: $0.start) })
        let nyMonth = try #require(
            newYork.last.map { calendar(in: "America/New_York").component(.month, from: $0.start) }
        )
        #expect(utcMonth == 3, "a UTC midnight on the 1st belongs to that month")
        #expect(nyMonth == 2, "the local calendar files it under the previous month — the bug")
        #expect(utcMonth != nyMonth, "if these ever agree this test has stopped proving anything")
    }

    /// The same shift at a week boundary, which is the one the change rate
    /// reads in weekly mode.
    @Test("a UTC week boundary is not pulled into the previous week")
    func weekBoundaryHoldsInUTC() throws {
        // 2026-03-01T00:00:00Z is a Sunday — the first day of the week when
        // firstWeekday is 1.
        let sundayUTC = Date(timeIntervalSince1970: 1_772_323_200)
        let samples = [UsageSample(date: sundayUTC, amount: 1_000)]

        let utc = PeriodAggregation.aggregate(
            samples: samples, unit: .weekly, now: sundayUTC, calendar: utcCalendar()
        )
        let newYork = PeriodAggregation.aggregate(
            samples: samples, unit: .weekly, now: sundayUTC,
            calendar: calendar(in: "America/New_York")
        )

        let utcStart = try #require(utc.last?.start)
        let nyStart = try #require(newYork.last?.start)
        #expect(utcStart != nyStart, "the two calendars must not agree on this instant's week")
    }

    /// Seoul is why nobody saw it. Pinning this keeps a future reader from
    /// "verifying" the bug is gone by running the app locally.
    @Test("in KST the two agree, which is why this was never noticed")
    func kstHidesIt() throws {
        let marchFirstUTC = Date(timeIntervalSince1970: 1_772_323_200)
        let samples = [UsageSample(date: marchFirstUTC, amount: 1_000)]

        let utc = PeriodAggregation.aggregate(
            samples: samples, unit: .monthly, now: marchFirstUTC, calendar: utcCalendar()
        )
        let seoul = PeriodAggregation.aggregate(
            samples: samples, unit: .monthly, now: marchFirstUTC,
            calendar: calendar(in: "Asia/Seoul")
        )
        let utcMonth = try #require(utc.last.map { utcCalendar().component(.month, from: $0.start) })
        let kstMonth = try #require(
            seoul.last.map { calendar(in: "Asia/Seoul").component(.month, from: $0.start) }
        )
        #expect(utcMonth == kstMonth, "UTC+9 keeps a UTC midnight inside the same local day")
    }
}
