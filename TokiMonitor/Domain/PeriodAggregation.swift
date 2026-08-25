import Foundation

// MARK: - Period aggregation (weekly / monthly)
//
// The period unit is the ONLY control this page gives the user (FR-001), so
// everything the switch changes lives here rather than in the view.
//
// Two traps this layer exists to close:
//
// 1. **Months are not the same length.** February beside March on absolute
//    totals alone shows a ~10% "decline" that never happened — it is three
//    missing days. Every period therefore carries its daily average next to
//    its total (FR-007), and the length-neutral change rate is computed from
//    the average, not the total.
// 2. **The current period is not finished.** A month three days in is not a
//    quiet month. `isComplete` is stored, and the total-based change rate is
//    withheld entirely on an unfinished period (FR-004) — a caller cannot
//    render "-88% this month" by accident, because the number does not exist.
//
// Switching units must not change how much usage the page reports (FR-003):
// buckets partition the samples with no gaps and no overlap, so Σ weekly
// totals == Σ monthly totals == Σ sample amounts, for any span.

/// Weekly or monthly. There is no daily mode — the spec fixes these two.
enum PeriodUnit: String, Codable, CaseIterable, Sendable, Hashable {
    case weekly
    case monthly

    /// Calendar component the buckets are cut on.
    var component: Calendar.Component {
        switch self {
        case .weekly: return .weekOfYear
        case .monthly: return .month
        }
    }

    var label: String {
        switch self {
        case .weekly: return L.tr("주별", "Weekly")
        case .monthly: return L.tr("월별", "Monthly")
        }
    }
}

/// One dated quantity to be bucketed — tokens, cost, requests, whatever the
/// caller is trending. The aggregation is unit-agnostic on purpose: what a
/// "usage total" means is the caller's business, and duplicating this file per
/// metric is how the two modes drift apart.
struct UsageSample: Equatable, Sendable {
    let date: Date
    let amount: Double

    init(date: Date, amount: Double) {
        self.date = date
        self.amount = amount
    }
}

/// One aggregation bucket.
///
/// `end` is EXCLUSIVE: `[start, end)`. Adjacent periods share the instant, and
/// a sample lands in exactly one bucket.
struct Period: Equatable, Sendable {
    let unit: PeriodUnit
    let start: Date
    /// Exclusive upper bound.
    let end: Date
    /// Absolute total over the bucket.
    let total: Double
    /// Calendar days the bucket spans: 7 for a week, 28…31 for a month.
    /// Derived from the calendar, never assumed — a hardcoded 30 is exactly
    /// the bug the daily average exists to prevent.
    let calendarDays: Int
    /// Days of the bucket that have actually happened. Equals `calendarDays`
    /// once complete; on the in-progress period it is the elapsed fraction, so
    /// the daily average stays comparable with finished periods.
    let observedDays: Double
    /// The bucket has finished. An unfinished bucket is never compared as an
    /// equal to a finished one (FR-004).
    let isComplete: Bool

    /// Change against the previous period's total, in percent (FR-008 — a
    /// rate, never an absolute difference).
    ///
    /// nil when there is no previous period, when the previous total is zero
    /// (a rate of change from nothing is not a percentage), or when either
    /// period is unfinished — an in-progress total compared against a finished
    /// one reports a collapse that is only the calendar.
    let totalChangeRatePct: Double?
    /// Change against the previous period's daily average, in percent. This is
    /// the one that survives February: it is neutral to both period length and
    /// to the current period being unfinished, and it is what monthly mode
    /// should lead with.
    let dailyAverageChangeRatePct: Double?

    /// Total per day over the days that actually happened.
    ///
    /// nil below one observed day: a period a few hours old has no daily rate
    /// yet, and dividing by a fraction of a day manufactures a huge number out
    /// of one morning's work. Silence beats a plausible wrong figure
    /// (constitution IV).
    var dailyAverage: Double? {
        guard observedDays >= 1 else { return nil }
        return total / observedDays
    }

    /// Days of the bucket still to run. 0 once complete.
    var remainingDays: Double { max(0, Double(calendarDays) - observedDays) }
}

enum PeriodAggregation {

    /// The app's single notion of "the week" and "the month".
    ///
    /// `Calendar.current` carries the user's system time zone and the region's
    /// first weekday — the settings FR-005 points at. The app deliberately has
    /// no preference of its own: a second start-of-week would let the trend
    /// disagree with every date the rest of the app prints (`TokenAggregator`
    /// takes "today" from the same place).
    static var userCalendar: Calendar { .current }

    /// Bucket `samples` into contiguous periods.
    ///
    /// The result spans from the first sample's bucket through the bucket
    /// containing `now`, with empty buckets included: a month with no usage is
    /// a fact about the trend, and dropping it would compress the time axis
    /// into a lie. The last element is the in-progress period whenever `now`
    /// falls inside the span.
    ///
    /// - Parameters:
    ///   - now: the clock, injectable so tests are not calendar-dependent.
    ///   - calendar: defaults to `userCalendar`; tests pin time zone and
    ///     `firstWeekday` through it.
    static func aggregate(
        samples: [UsageSample],
        unit: PeriodUnit,
        now: Date = Date(),
        calendar: Calendar = PeriodAggregation.userCalendar
    ) -> [Period] {
        guard let earliest = samples.map(\.date).min() else { return [] }
        guard let firstInterval = calendar.dateInterval(of: unit.component, for: earliest) else {
            return []
        }

        // The span ends at whichever is later: the newest sample or now. A
        // fixture clock behind its own data must still produce every bucket
        // the data needs, and a live clock ahead of the data must still show
        // the empty periods since.
        let latest = max(samples.map(\.date).max() ?? earliest, now)

        var bounds: [(start: Date, end: Date)] = []
        var cursor = firstInterval.start
        while cursor <= latest {
            guard let interval = calendar.dateInterval(of: unit.component, for: cursor) else { break }
            bounds.append((interval.start, interval.end))
            guard let next = calendar.date(byAdding: unit.component, value: 1, to: interval.start),
                  next > cursor else { break }
            cursor = next
        }
        guard !bounds.isEmpty else { return [] }

        var totals = [Double](repeating: 0, count: bounds.count)
        for sample in samples {
            // Binary search would need the samples sorted; the page's trend is
            // a few hundred buckets at most, and a wrong bucket is a wrong
            // trend, so this stays a straight scan over the bounds.
            guard let index = bounds.firstIndex(where: { sample.date >= $0.start && sample.date < $0.end })
            else { continue }
            totals[index] += sample.amount
        }

        var periods: [Period] = []
        periods.reserveCapacity(bounds.count)
        for (index, bound) in bounds.enumerated() {
            let calendarDays = calendarDayCount(from: bound.start, to: bound.end, calendar: calendar)
            let isComplete = bound.end <= now
            let observed = isComplete
                ? Double(calendarDays)
                : min(Double(calendarDays), elapsedDays(from: bound.start, to: now, calendar: calendar))

            let period = Period(
                unit: unit,
                start: bound.start,
                end: bound.end,
                total: totals[index],
                calendarDays: calendarDays,
                observedDays: max(0, observed),
                isComplete: isComplete,
                totalChangeRatePct: nil,
                dailyAverageChangeRatePct: nil
            )
            periods.append(withChangeRates(period, previous: periods.last))
        }
        return periods
    }

    /// Percentage rate of change, `nil` when the base is zero.
    ///
    /// Growth from zero is not a percentage — reporting it as `+∞` or as some
    /// large number would put a fabricated figure on screen where the honest
    /// statement is "first period with any usage".
    static func changeRatePct(from previous: Double, to current: Double) -> Double? {
        guard previous != 0 else { return nil }
        return (current - previous) / abs(previous) * 100
    }

    /// Whole calendar days in `[from, to)`. DST-safe: a 23-hour day is still a
    /// day, which `timeIntervalSince / 86400` gets wrong twice a year.
    static func calendarDayCount(from: Date, to: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// Days elapsed between `from` and `now`, counting the partial current day
    /// as its own fraction — measured against that day's real length, so a DST
    /// day is 23 or 25 hours rather than 24.
    static func elapsedDays(from: Date, to now: Date, calendar: Calendar) -> Double {
        guard now > from else { return 0 }
        let dayStart = calendar.startOfDay(for: now)
        let fullDays = max(0, calendarDayCount(from: from, to: dayStart, calendar: calendar))
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        let dayLength = dayEnd.timeIntervalSince(dayStart)
        let fraction = dayLength > 0 ? now.timeIntervalSince(dayStart) / dayLength : 0
        return Double(fullDays) + min(1, max(0, fraction))
    }

    private static func withChangeRates(_ period: Period, previous: Period?) -> Period {
        guard let previous else { return period }

        // Totals are only comparable between two finished periods. On the
        // in-progress one the figure would be the calendar talking, not usage.
        let totalRate = (period.isComplete && previous.isComplete)
            ? changeRatePct(from: previous.total, to: period.total)
            : nil

        let averageRate: Double? = {
            guard let current = period.dailyAverage, let base = previous.dailyAverage else { return nil }
            return changeRatePct(from: base, to: current)
        }()

        return Period(
            unit: period.unit,
            start: period.start,
            end: period.end,
            total: period.total,
            calendarDays: period.calendarDays,
            observedDays: period.observedDays,
            isComplete: period.isComplete,
            totalChangeRatePct: totalRate,
            dailyAverageChangeRatePct: averageRate
        )
    }
}

// MARK: - Labels

extension Period {

    /// Axis / row label for this bucket.
    ///
    /// Formatted from the bucket's own boundaries so the label can never
    /// disagree with the aggregation: the presentation layer has no business
    /// re-deriving where a week starts.
    func displayLabel(calendar: Calendar = PeriodAggregation.userCalendar) -> String {
        let locale = Locale(identifier: L.code == "ko" ? "ko_KR" : "en_US")
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        switch unit {
        case .monthly:
            formatter.setLocalizedDateFormatFromTemplate("yMMM")
            return formatter.string(from: start)
        case .weekly:
            formatter.setLocalizedDateFormatFromTemplate("Md")
            // The stored `end` is exclusive; the label names the last day the
            // week actually contains.
            let lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? end
            return "\(formatter.string(from: start)) – \(formatter.string(from: lastDay))"
        }
    }

    /// Marker for a period that is still running, to be shown wherever the
    /// period is (FR-004: the distinction has to be visible, not implied).
    var incompleteNote: String? {
        guard !isComplete else { return nil }
        let days = Int(observedDays.rounded(.down))
        return L.tr("진행 중 · \(days)/\(calendarDays)일", "In progress · day \(days) of \(calendarDays)")
    }
}
