import Testing
import Foundation
@testable import TokiMonitor

/// The period switch is the only control on the page, so the two ways it can
/// lie are the two things worth testing: usage appearing or vanishing when the
/// unit changes, and February looking like a slump because it is short.
///
/// `@MainActor` because the labels reach `L.tr`, which resolves the language
/// through `MainActor.assumeIsolated`.
@Suite("Period aggregation")
@MainActor
struct PeriodAggregationTests {

    /// Fixed calendar: UTC and Monday-start, so the assertions below are about
    /// the aggregation rather than about wherever the machine running them is.
    /// Production reads `Calendar.current` — the user's own time zone and
    /// first weekday (FR-005).
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// One sample per day at noon, inclusive of both ends.
    private func dailySamples(from start: Date, to end: Date, amount: Double) -> [UsageSample] {
        var samples: [UsageSample] = []
        var cursor = start
        while cursor <= end {
            samples.append(UsageSample(date: cursor, amount: amount))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return samples
    }

    // MARK: - T027: the total survives the switch

    @Test("switching weekly to monthly moves no usage")
    func totalsPreservedAcrossUnits() {
        // 2026-01-01 through 2026-04-15: spans month boundaries that fall
        // mid-week in both directions, which is where a bucket can eat or
        // double-count a day.
        let samples = dailySamples(from: date(2026, 1, 1), to: date(2026, 4, 15), amount: 7)
        let now = date(2026, 4, 20)
        let sourceTotal = samples.reduce(0) { $0 + $1.amount }

        let weekly = PeriodAggregation.aggregate(samples: samples, unit: .weekly, now: now, calendar: calendar)
        let monthly = PeriodAggregation.aggregate(samples: samples, unit: .monthly, now: now, calendar: calendar)

        #expect(weekly.reduce(0) { $0 + $1.total } == sourceTotal)
        #expect(monthly.reduce(0) { $0 + $1.total } == sourceTotal)
        #expect(weekly.count > monthly.count)
    }

    @Test("buckets are contiguous and half-open, so no sample lands twice")
    func bucketsPartitionTheSpan() {
        let samples = dailySamples(from: date(2026, 1, 1), to: date(2026, 3, 31), amount: 1)
        let now = date(2026, 4, 1)

        for unit in PeriodUnit.allCases {
            let periods = PeriodAggregation.aggregate(samples: samples, unit: unit, now: now, calendar: calendar)
            for (previous, next) in zip(periods, periods.dropFirst()) {
                #expect(previous.end == next.start)
            }
            // Every sample is inside exactly one bucket.
            for sample in samples {
                let hits = periods.filter { sample.date >= $0.start && sample.date < $0.end }
                #expect(hits.count == 1)
            }
        }
    }

    @Test("a period with no usage is still a period")
    func emptyPeriodsAreKept() {
        // January, then nothing until April.
        let samples = dailySamples(from: date(2026, 1, 5), to: date(2026, 1, 9), amount: 3)
            + dailySamples(from: date(2026, 4, 6), to: date(2026, 4, 10), amount: 3)
        let periods = PeriodAggregation.aggregate(
            samples: samples, unit: .monthly, now: date(2026, 4, 30), calendar: calendar
        )
        #expect(periods.count == 4)
        #expect(periods[1].total == 0)
        #expect(periods[2].total == 0)
    }

    // MARK: - T024: the daily average matches the real day count

    @Test("the daily average divides by the month's own length, February included")
    func dailyAverageUsesRealDayCount() {
        // The same usage every single day across four months of three
        // different lengths. A fixed 30-day divisor gets all three wrong.
        let samples = dailySamples(from: date(2026, 1, 1), to: date(2026, 4, 30), amount: 10)
        let periods = PeriodAggregation.aggregate(
            samples: samples, unit: .monthly, now: date(2026, 5, 15), calendar: calendar
        )

        let byMonth = Dictionary(uniqueKeysWithValues: periods.map {
            (calendar.component(.month, from: $0.start), $0)
        })

        #expect(byMonth[1]?.calendarDays == 31)
        #expect(byMonth[2]?.calendarDays == 28)   // 2026 is not a leap year
        #expect(byMonth[3]?.calendarDays == 31)
        #expect(byMonth[4]?.calendarDays == 30)

        #expect(byMonth[1]?.total == 310)
        #expect(byMonth[2]?.total == 280)

        // The point of the daily average: February's smaller total is not a
        // smaller usage rate.
        for month in 1...4 {
            #expect(byMonth[month]?.dailyAverage == 10)
        }
    }

    @Test("a leap February is 29 days")
    func leapFebruary() {
        let samples = dailySamples(from: date(2028, 2, 1), to: date(2028, 2, 29), amount: 5)
        let periods = PeriodAggregation.aggregate(
            samples: samples, unit: .monthly, now: date(2028, 3, 10), calendar: calendar
        )
        #expect(periods.first?.calendarDays == 29)
        #expect(periods.first?.total == 145)
        #expect(periods.first?.dailyAverage == 5)
    }

    @Test("a week is seven days regardless of where the month ends")
    func weeklyDayCount() {
        let samples = dailySamples(from: date(2026, 1, 1), to: date(2026, 3, 31), amount: 2)
        let periods = PeriodAggregation.aggregate(
            samples: samples, unit: .weekly, now: date(2026, 4, 6), calendar: calendar
        )
        #expect(periods.allSatisfy { $0.calendarDays == 7 })
    }

    // MARK: - T026: an unfinished period is marked, and not compared as an equal

    @Test("the running period is marked incomplete and the finished ones are not")
    func incompletePeriodIsMarked() {
        let samples = dailySamples(from: date(2026, 1, 1), to: date(2026, 3, 10), amount: 4)
        let now = date(2026, 3, 10, 18)
        let periods = PeriodAggregation.aggregate(
            samples: samples, unit: .monthly, now: now, calendar: calendar
        )

        #expect(periods.count == 3)
        #expect(periods.dropLast().allSatisfy { $0.isComplete })
        #expect(periods.last?.isComplete == false)
        #expect(periods.last?.incompleteNote != nil)
        #expect(periods.first?.incompleteNote == nil)

        // Nine full days plus most of the tenth.
        let observed = periods.last?.observedDays ?? 0
        #expect(observed > 9.7 && observed < 10.0)
        #expect(periods.last?.remainingDays ?? 0 > 21)
    }

    @Test("an unfinished period is not given a total-based change rate")
    func incompletePeriodWithholdsTotalChange() {
        let samples = dailySamples(from: date(2026, 1, 1), to: date(2026, 2, 3), amount: 6)
        // Three full days into February, at exactly the same daily rate.
        let periods = PeriodAggregation.aggregate(
            samples: samples, unit: .monthly, now: date(2026, 2, 4, 0), calendar: calendar
        )
        let february = periods.last!
        #expect(february.isComplete == false)
        // Three days of February against all of January would read as a 90%
        // collapse — the calendar talking, not the user.
        #expect(february.totalChangeRatePct == nil)
        // The length-neutral one still works: same daily rate, no change.
        #expect(february.dailyAverageChangeRatePct != nil)
        #expect(abs(february.dailyAverageChangeRatePct! - 0) < 0.001)
    }

    @Test("a period under a day old reports no daily average")
    func subDayPeriodHasNoAverage() {
        let samples = [UsageSample(date: date(2026, 3, 1, 1), amount: 40)]
        let periods = PeriodAggregation.aggregate(
            samples: samples, unit: .monthly, now: date(2026, 3, 1, 3), calendar: calendar
        )
        #expect(periods.count == 1)
        #expect(periods[0].total == 40)
        #expect(periods[0].dailyAverage == nil)
    }

    // MARK: - T025: change is a rate, not a difference

    @Test("period-over-period change is a percentage")
    func changeIsARate() {
        // 10/day in January (31 days), 20/day in February (28 days).
        let samples = dailySamples(from: date(2026, 1, 1), to: date(2026, 1, 31), amount: 10)
            + dailySamples(from: date(2026, 2, 1), to: date(2026, 2, 28), amount: 20)
        let periods = PeriodAggregation.aggregate(
            samples: samples, unit: .monthly, now: date(2026, 3, 5), calendar: calendar
        )

        let january = periods[0]
        let february = periods[1]
        #expect(january.totalChangeRatePct == nil)          // nothing before it
        #expect(january.dailyAverageChangeRatePct == nil)

        // Totals: 310 → 560 is +80.6%, which understates the doubling because
        // February is three days shorter.
        #expect(abs(february.totalChangeRatePct! - 80.645) < 0.01)
        // Daily average: 10 → 20 is exactly +100%, which is what happened.
        #expect(abs(february.dailyAverageChangeRatePct! - 100) < 0.001)
    }

    @Test("growth from zero is not a percentage")
    func rateFromZeroIsWithheld() {
        #expect(PeriodAggregation.changeRatePct(from: 0, to: 50) == nil)
        #expect(PeriodAggregation.changeRatePct(from: 100, to: 0) == -100)
        #expect(PeriodAggregation.changeRatePct(from: 100, to: 150) == 50)
    }

    @Test("the first period after an empty one has no rate to report")
    func rateAfterAnEmptyPeriod() {
        let samples = dailySamples(from: date(2026, 3, 1), to: date(2026, 3, 31), amount: 9)
        let periods = PeriodAggregation.aggregate(
            samples: samples, unit: .monthly, now: date(2026, 4, 15), calendar: calendar
        )
        // April is in progress with nothing in it: no total rate (unfinished),
        // and the average rate is a real -100% only once a day has elapsed.
        #expect(periods.last?.total == 0)
        #expect(periods.last?.totalChangeRatePct == nil)
    }

    // MARK: - Boundaries follow the calendar it is given

    @Test("week boundaries follow the calendar's first weekday")
    func weekStartFollowsTheCalendar() {
        var sunday = calendar
        sunday.firstWeekday = 1
        let samples = dailySamples(from: date(2026, 3, 2), to: date(2026, 3, 8), amount: 1)

        // Still inside the Monday-start week, so no extra in-progress bucket
        // is opened on that side.
        let now = date(2026, 3, 8, 18)
        let mondayWeeks = PeriodAggregation.aggregate(
            samples: samples, unit: .weekly, now: now, calendar: calendar
        )
        let sundayWeeks = PeriodAggregation.aggregate(
            samples: samples, unit: .weekly, now: now, calendar: sunday
        )

        // 2026-03-02 is a Monday: one bucket Monday-start, two Sunday-start.
        #expect(mondayWeeks.count == 1)
        #expect(sundayWeeks.count == 2)
        // And the usage is the same either way.
        #expect(mondayWeeks.reduce(0) { $0 + $1.total } == sundayWeeks.reduce(0) { $0 + $1.total })
    }

    @Test("a week containing a DST change is still seven days")
    func dstWeekIsSevenDays() {
        // US DST starts 2026-03-08: that week is 167 hours, and dividing an
        // interval by 86400 would call it 6.96 days.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        newYork.firstWeekday = 2

        let start = newYork.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 12))!
        let end = newYork.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 12))!
        var samples: [UsageSample] = []
        var cursor = start
        while cursor <= end {
            samples.append(UsageSample(date: cursor, amount: 1))
            cursor = newYork.date(byAdding: .day, value: 1, to: cursor)!
        }

        let weekly = PeriodAggregation.aggregate(
            samples: samples, unit: .weekly,
            now: newYork.date(from: DateComponents(year: 2026, month: 4, day: 6))!,
            calendar: newYork
        )
        #expect(weekly.allSatisfy { $0.calendarDays == 7 })
        // The week that lost an hour still reports exactly 1/day.
        let dstWeek = weekly.first { week in
            week.start <= start && start < week.end
        }
        #expect(dstWeek?.total == 7)
        #expect(dstWeek?.dailyAverage == 1)
    }

    @Test("no samples means no periods, not a zero-filled chart")
    func emptyInputIsEmpty() {
        #expect(PeriodAggregation.aggregate(
            samples: [], unit: .monthly, now: date(2026, 3, 1), calendar: calendar
        ).isEmpty)
    }

    @Test("each period names itself from its own boundaries")
    func labels() {
        let samples = dailySamples(from: date(2026, 3, 2), to: date(2026, 3, 8), amount: 1)
        let weekly = PeriodAggregation.aggregate(
            samples: samples, unit: .weekly, now: date(2026, 3, 9), calendar: calendar
        )
        let monthly = PeriodAggregation.aggregate(
            samples: samples, unit: .monthly, now: date(2026, 3, 9), calendar: calendar
        )
        #expect(weekly[0].displayLabel(calendar: calendar).contains("–"))
        #expect(!monthly[0].displayLabel(calendar: calendar).isEmpty)
    }
}
