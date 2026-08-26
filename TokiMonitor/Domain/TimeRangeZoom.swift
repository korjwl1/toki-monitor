import Foundation

// MARK: - Changing the time range without the picker
//
// The dashboard could only change its time range through the popover: pick a
// preset, or type two absolute dates. Both of those are "state the range you
// want"; neither is "show me THAT bit", which is the move a reader makes when
// something on a chart is interesting — and the reason Grafana's drag-to-zoom
// is the control people reach for first.
//
// The arithmetic lives here rather than on the view model because it is the
// part that can be wrong: a zoom that drifts off centre, a pan that shows the
// future, a drag of two pixels that collapses the range to nothing. A test can
// hold all three still without a window.

enum TimeRangeZoom {

    /// The narrowest range worth showing. Below a minute the bucket width
    /// (`duration / 15`) drops under 4 seconds and every panel is drawing
    /// noise.
    static let minimumSpan: TimeInterval = 60

    /// The widest. Ten years is past any data this app can have and keeps a
    /// runaway zoom-out from asking for an unbounded query.
    static let maximumSpan: TimeInterval = 10 * 365 * 86_400

    /// Scale the range about its own centre.
    ///
    /// `factor` below 1 zooms in (0.5 halves the window), above 1 zooms out.
    /// The result is always ABSOLUTE, even from a relative range: "the last 24
    /// hours, halved" is not a relative range any more — it ends in the past —
    /// and writing it as one would silently slide the window forward on every
    /// refresh.
    static func zoom(_ time: TimeConfig, factor: Double,
                     now: Date = Date()) -> TimeConfig {
        precondition(factor > 0, "a zoom factor must be positive")
        let (from, to) = bounds(time, now: now)
        let span = to.timeIntervalSince(from)
        guard span > 0 else { return time }
        let centre = from.addingTimeInterval(span / 2)
        let scaled = clampSpan(span * factor)
        return TimeConfig.absolute(from: centre.addingTimeInterval(-scaled / 2),
                                   to: centre.addingTimeInterval(scaled / 2))
    }

    /// Slide the range by a fraction of its own width. Negative moves back.
    ///
    /// Forward motion stops at `now`. There is no data after it, so a range
    /// that runs into the future is half a chart of blank — and the reader who
    /// pressed the key once more is not asking to see nothing, they are asking
    /// to catch up to the present.
    static func pan(_ time: TimeConfig, by fraction: Double,
                    now: Date = Date()) -> TimeConfig {
        let (from, to) = bounds(time, now: now)
        let span = to.timeIntervalSince(from)
        guard span > 0 else { return time }
        var shift = span * fraction
        if to.addingTimeInterval(shift) > now {
            shift = now.timeIntervalSince(to)
        }
        guard shift != 0 else { return time }
        return TimeConfig.absolute(from: from.addingTimeInterval(shift),
                                   to: to.addingTimeInterval(shift))
    }

    /// The range a drag across a chart selects, or nil when the drag was not a
    /// selection.
    ///
    /// Nil for a backwards or degenerate drag: a click that moved three pixels
    /// is a click, and treating it as a zoom to a 200-millisecond window is the
    /// behaviour that makes people stop using drag-to-zoom.
    static func selection(from start: Date, to end: Date) -> TimeConfig? {
        let lower = min(start, end)
        let upper = max(start, end)
        let span = upper.timeIntervalSince(lower)
        guard span >= minimumSpan else { return nil }
        return TimeConfig.absolute(from: lower, to: min(upper, lower.addingTimeInterval(maximumSpan)))
    }

    /// Whether a drag is long enough on screen to have been meant as one.
    ///
    /// Separate from the span check above because they catch different
    /// mistakes: this one is about the hand, that one about the axis. A careful
    /// 40-pixel drag on a 7-day chart is a real selection; a 3-pixel twitch on
    /// the same chart is not, even though its span passes.
    static let minimumDragWidth: CGFloat = 12

    // MARK: - Shared

    /// The range as two dates, resolving `now-…` against the clock passed in
    /// rather than the real one — so a test can state what "now" is.
    private static func bounds(_ time: TimeConfig, now: Date) -> (Date, Date) {
        guard time.isRelative else { return (time.fromDate, time.toDate) }
        return (now.addingTimeInterval(-time.duration), now)
    }

    private static func clampSpan(_ span: TimeInterval) -> TimeInterval {
        Swift.min(Swift.max(span, minimumSpan), maximumSpan)
    }
}
