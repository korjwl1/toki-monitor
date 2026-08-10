import Foundation

// MARK: - Field-driven rendering
//
// The step that lets `PanelMetric` leave the execution path.
//
// Today a renderer switches on the metric enum to decide which number to show
// (`PanelDataExtractor.statValue`, `chartPoints`), with a `default` branch that
// returns "-" or an empty chart. That is why a user-written query outside the
// twelve cases cannot render: the enum is not a label on the data, it IS the
// instruction for reading it.
//
// A field-driven renderer instead asks: which FIELD of the frame, reduced how.
// Both come from the panel definition, so a new number needs no enum case and
// no renderer branch — which is the actual milestone, not the transformation
// count.

/// Which column of a frame a visualization should read, and how to collapse it
/// when the visualization wants a single value.
struct FieldSelection: Codable, Equatable, Sendable {
    /// Field name. Nil means "the first numeric field", which keeps a panel
    /// working when a query's columns change underneath it.
    var field: String?
    var reducer: ReduceTransformation.Reducer

    init(field: String? = nil, reducer: ReduceTransformation.Reducer = .lastNotNull) {
        self.field = field
        self.reducer = reducer
    }

    /// Resolve against a frame, falling back to its first numeric column.
    func resolve(in frame: Frame) -> Field? {
        if let field { return frame.field(named: field) }
        return frame.numberFields.first
    }
}

/// Reading numbers out of frames. Replaces the metric switch — every function
/// here is driven by a field name and a reducer rather than by an enum case.
enum FrameReader {

    /// One value across the whole set: reduce each frame, then combine.
    ///
    /// Combining with `sum` is right for additive measures (tokens, cost,
    /// events) which is everything toki records. A measure where that is wrong
    /// would need its own combiner, and the caller passes one.
    static func singleValue(
        _ set: FrameSet,
        selection: FieldSelection,
        combine: ReduceTransformation.Reducer = .sum
    ) -> Double? {
        let perFrame: [Double?] = set.frames.compactMap { frame in
            guard let f = selection.resolve(in: frame),
                  let numbers = f.values.numbers else { return nil }
            return ReduceTransformation.reduce(numbers, using: selection.reducer)
        }
        // All-absent stays absent: a stat card reading 0 for "no data" is
        // indistinguishable from a real measurement of zero.
        return perFrame.compactMap { $0 }.isEmpty
            ? nil
            : ReduceTransformation.reduce(perFrame, using: combine)
    }

    /// Per-series points for a chart, keyed by the frame's display name.
    static func series(
        _ set: FrameSet,
        selection: FieldSelection
    ) -> [(name: String, points: [(date: Date, value: Double?)])] {
        set.frames.compactMap { frame in
            guard let times = frame.timeField,
                  case let .time(dates) = times.values,
                  let values = selection.resolve(in: frame)?.values.numbers
            else { return nil }
            let n = min(dates.count, values.count)
            return (frame.displayName, (0..<n).map { (dates[$0], values[$0]) })
        }
    }

    /// The series with the largest reduced value — "top model" without an enum
    /// case for it.
    ///
    /// `labelKey` names which dimension to report. A card headed "top model"
    /// should answer with a model, not with the full series identity: the
    /// display name also carries provider and any other grouping dimension,
    /// which reads as noise when the question named one of them.
    static func topSeries(_ set: FrameSet, selection: FieldSelection,
                          labelKey: String? = nil) -> String? {
        set.frames
            .compactMap { frame -> (String, Double)? in
                guard let numbers = selection.resolve(in: frame)?.values.numbers,
                      let v = ReduceTransformation.reduce(numbers, using: selection.reducer)
                else { return nil }
                let name = labelKey.flatMap { frame.commonLabels[$0] } ?? frame.displayName
                return (name, v)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Distinct values of a label across the set — what a groupBy or adhoc
    /// variable will read, and what a legend needs to offer.
    static func labelValues(_ set: FrameSet, key: String) -> [String] {
        Array(Set(set.frames.compactMap { $0.commonLabels[key] })).sorted()
    }

    /// Which labels the data actually carries. A variable editor that offers a
    /// hard-coded list can offer one the query never returns, and the user gets
    /// an empty dropdown with nothing to explain it.
    static func labelKeys(_ set: FrameSet) -> [String] {
        Array(Set(set.frames.flatMap { $0.commonLabels.keys })).sorted()
    }
}

// MARK: - Presets

/// What `PanelMetric` becomes once it stops being an execution discriminator:
/// a catalogue of starting points. A preset seeds a panel's query, its field
/// selection and its visualization; after that the panel is described entirely
/// by those, and the preset is not consulted again.
///
/// Keeping the catalogue is deliberate — "add a panel" should not begin with a
/// blank query box. What changes is that it is now a convenience, not the
/// mechanism.
struct PanelPreset: Equatable, Sendable {
    var metric: PanelMetric
    var selection: FieldSelection

    /// The field each built-in metric reads, and how it collapses. Derived from
    /// what the metric-switching extractor did, so presets reproduce today's
    /// behaviour exactly while the renderer stops depending on the enum.
    static func selection(for metric: PanelMetric) -> FieldSelection {
        switch metric {
        case .totalTokens, .tokensByModel, .inputVsOutput:
            return FieldSelection(field: "total_tokens", reducer: .sum)
        case .totalCost, .costByModel:
            return FieldSelection(field: "cost_usd", reducer: .sum)
        case .apiCalls, .eventsByModel:
            return FieldSelection(field: "events", reducer: .sum)
        case .reasoningTokens:
            return FieldSelection(field: "reasoning_output_tokens", reducer: .sum)
        case .cacheHitRate:
            // Computed by a transformation rather than read directly — the
            // ratio has no column of its own on the wire.
            return FieldSelection(field: "cache_hit_rate", reducer: .lastNotNull)
        case .topModel, .modelBreakdown, .tokensByProject:
            return FieldSelection(field: "total_tokens", reducer: .sum)
        case .rateLimitWindows:
            // The peak is what a window is judged by; the last value only
            // says where it happened to be when it was last observed.
            return FieldSelection(field: "peak_pct", reducer: .max)
        }
    }

    /// Steps a preset needs before its selection resolves. Only the ratio needs
    /// any today, which is precisely the metric that could not be expressed
    /// without an enum case before.
    static func transformations(for metric: PanelMetric) -> [any Transformation] {
        switch metric {
        case .cacheHitRate:
            return [
                CalculateFieldTransformation(
                    left: "cache_read_input_tokens", right: "input_tokens",
                    operation: .add, alias: "cache_denominator"
                ),
                CalculateFieldTransformation(
                    left: "cache_read_input_tokens", right: "cache_denominator",
                    operation: .divide, alias: "cache_hit_rate"
                ),
            ]
        default:
            return []
        }
    }
}
