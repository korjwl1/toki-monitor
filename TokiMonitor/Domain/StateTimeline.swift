import Foundation

// MARK: - Intervals
//
// The visualizations so far all answer "how much, over time". They cannot
// answer "what state was this in, and for how long" — which is the shape of
// half of what toki records: a rate-limit window is an interval with an
// outcome, a session is an interval, a limit being reached is an instant
// inside one. Drawing those as a line means reading a step function and
// guessing where it changed.
//
// A state timeline is spans on a row per series. This builds them from the
// same frames every other panel reads, in two shapes:
//
//   - a value column sampled over time, where consecutive equal states become
//     one span (Grafana's state-timeline);
//   - explicit `start`/`end` columns, where each row already IS a span, which
//     is what the windows metric produces.

/// One drawn span.
struct TimelineSpan: Identifiable, Equatable, Sendable {
    var id: String { "\(series)|\(start.timeIntervalSince1970)|\(label)" }
    var series: String
    var start: Date
    var end: Date
    /// What to print in the span and its tooltip.
    var label: String
    /// The number the span came from, when it came from one. Drives colour
    /// through the panel's thresholds; nil means the state was a string and
    /// the palette assigns by name.
    var value: Double?

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum StateTimelineBuilder {

    /// Field names that mean "this row is already an interval". Checked
    /// together: a frame with only one of them is a time series that happens
    /// to have a column called `end`.
    static let startField = "start"
    static let endField = "end"

    /// Build spans for every series in the set.
    ///
    /// - Parameters:
    ///   - selection: which column carries the state. A numeric column is
    ///     bucketed by `thresholds` so that a continuous measure (utilization)
    ///     becomes a small number of states; a string column is the state.
    ///   - thresholds: ascending steps. Empty means every distinct value is
    ///     its own state, which is right for an already-discrete column and
    ///     wrong for a continuous one — hence the panel seeds them.
    static func spans(_ set: FrameSet,
                      selection: FieldSelection,
                      thresholds: [ThresholdStep] = []) -> [TimelineSpan] {
        set.frames.flatMap { spans(in: $0, selection: selection, thresholds: thresholds) }
    }

    static func spans(in frame: Frame,
                      selection: FieldSelection,
                      thresholds: [ThresholdStep]) -> [TimelineSpan] {
        if let explicit = explicitIntervals(in: frame, selection: selection,
                                            thresholds: thresholds) {
            return explicit
        }
        return runs(in: frame, selection: selection, thresholds: thresholds)
    }

    // MARK: - Rows that are already intervals

    private static func explicitIntervals(in frame: Frame,
                                          selection: FieldSelection,
                                          thresholds: [ThresholdStep]) -> [TimelineSpan]? {
        guard case let .time(starts)? = frame.field(named: startField)?.values,
              case let .time(ends)? = frame.field(named: endField)?.values
        else { return nil }

        let name = frame.displayName
        let numbers = selection.resolve(in: frame)?.values.numbers
        let strings = selection.resolve(in: frame)?.values.strings
        var out: [TimelineSpan] = []
        for i in 0..<min(starts.count, ends.count) {
            // A row whose end precedes its start is not an interval. Drawing
            // it backwards would put a span where no time was spent.
            guard ends[i] >= starts[i] else { continue }
            let value = numbers?.indices.contains(i) == true ? numbers?[i] : nil
            let label = strings?.indices.contains(i) == true
                ? (strings?[i] ?? "")
                : stateName(for: value, thresholds: thresholds)
            out.append(TimelineSpan(series: name, start: starts[i], end: ends[i],
                                    label: label, value: value ?? nil))
        }
        return out
    }

    // MARK: - Sampled values, merged into runs

    private static func runs(in frame: Frame,
                             selection: FieldSelection,
                             thresholds: [ThresholdStep]) -> [TimelineSpan] {
        guard case let .time(times)? = frame.timeField?.values, times.count > 0,
              let field = selection.resolve(in: frame)
        else { return [] }

        let name = frame.displayName
        let numbers = field.values.numbers
        let strings = field.values.strings
        // The last sample has no successor to end it. Using the median step
        // rather than the last gap keeps one late sample from stretching the
        // final span across the whole chart.
        let step = medianStep(times)

        var out: [TimelineSpan] = []
        var runStart: Date?
        var runLabel = ""
        var runValue: Double?

        func labelAndValue(_ i: Int) -> (String, Double?)? {
            if let strings, i < strings.count {
                guard let s = strings[i] else { return nil }
                return (s, nil)
            }
            guard let numbers, i < numbers.count, let v = numbers[i] else { return nil }
            return (stateName(for: v, thresholds: thresholds), v)
        }

        for i in times.indices {
            let current = labelAndValue(i)
            // A gap is a gap: `nil` closes the run instead of extending the
            // previous state across time nobody measured.
            if current?.0 != runLabel || current == nil, let start = runStart {
                out.append(TimelineSpan(series: name, start: start, end: times[i],
                                        label: runLabel, value: runValue))
                runStart = nil
            }
            guard let (label, value) = current else { continue }
            if runStart == nil {
                runStart = times[i]
                runLabel = label
                runValue = value
            }
        }
        if let start = runStart, let last = times.last {
            out.append(TimelineSpan(series: name, start: start, end: last.addingTimeInterval(step),
                                    label: runLabel, value: runValue))
        }
        return out
    }

    /// Median interval between samples, or one hour when there is only one
    /// sample and nothing to infer from.
    static func medianStep(_ times: [Date]) -> TimeInterval {
        guard times.count > 1 else { return 3600 }
        let gaps = zip(times.dropFirst(), times)
            .map { $0.timeIntervalSince($1) }
            .filter { $0 > 0 }
            .sorted()
        guard !gaps.isEmpty else { return 3600 }
        return gaps[gaps.count / 2]
    }

    // MARK: - States from numbers

    /// Which threshold band a value falls in, named for a human.
    ///
    /// With no thresholds the number itself is the state, which keeps an
    /// already-discrete column (a status code, a boolean) readable with no
    /// configuration. With thresholds, consecutive samples in the same band
    /// merge into one span — the point of the panel for a continuous measure
    /// like utilization, where every sample differs and merging by exact
    /// value would produce one span per sample.
    static func stateName(for value: Double?, thresholds: [ThresholdStep]) -> String {
        guard let value else { return "" }
        guard let band = band(for: value, thresholds: thresholds) else {
            guard !thresholds.isEmpty else {
                return value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
            }
            // Below every step: the band with no lower bound.
            let lowest = thresholds.map(\.value).min() ?? 0
            return "< \(number(lowest))"
        }
        return "≥ \(number(band.value))"
    }

    /// The colour for a value, or nil to let the palette assign one by name.
    static func color(for value: Double?, thresholds: [ThresholdStep]) -> String? {
        band(for: value, thresholds: thresholds)?.color
    }

    private static func band(for value: Double?,
                             thresholds: [ThresholdStep]) -> ThresholdStep? {
        guard let value, !thresholds.isEmpty else { return nil }
        let sorted = thresholds.sorted { $0.value < $1.value }
        guard value >= sorted[0].value else { return nil }
        var band = sorted[0]
        for step in sorted where value >= step.value { band = step }
        return band
    }

    private static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}
