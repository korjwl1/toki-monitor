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

    /// Per-series points for a chart.
    ///
    /// `name` decides what each series is called. It takes the frame and the
    /// field the selection resolved to, because a `displayName` override is
    /// written against the FIELD — `{{project}} tokens` fills from that field's
    /// own labels. Nil is the frame's own display name, which is what every
    /// caller wanted before overrides could rename anything.
    static func series(
        _ set: FrameSet,
        selection: FieldSelection,
        name: ((Frame, Field) -> String)? = nil
    ) -> [(name: String, points: [(date: Date, value: Double?)])] {
        set.frames.compactMap { frame in
            guard let times = frame.timeField,
                  case let .time(dates) = times.values,
                  let field = selection.resolve(in: frame),
                  let values = field.values.numbers
            else { return nil }
            let n = min(dates.count, values.count)
            let seriesName = name?(frame, field) ?? frame.displayName
            return (seriesName, (0..<n).map { (dates[$0], values[$0]) })
        }
    }

    /// Every numeric column of every frame, as named series.
    ///
    /// For readers with no panel to tell them which field to read: Explore runs
    /// an arbitrary query and has to show whatever came back, including columns
    /// no `PanelMetric` names. A frame carrying several measures contributes one
    /// series per measure, named for it, so `usage` does not silently show only
    /// its first column.
    static func allSeries(
        _ set: FrameSet
    ) -> [(name: String, points: [(date: Date, value: Double?)])] {
        var out: [(name: String, points: [(date: Date, value: Double?)])] = []
        for frame in set.frames {
            guard let times = frame.timeField, case let .time(dates) = times.values else { continue }
            let measures = frame.numberFields
            for field in measures {
                guard let values = field.values.numbers else { continue }
                let n = min(dates.count, values.count)
                let name = measures.count > 1
                    ? "\(frame.displayName) · \(field.name)"
                    : frame.displayName
                out.append((name, (0..<n).map { (dates[$0], values[$0]) }))
            }
        }
        return out
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

// MARK: - What a panel actually draws

extension PanelPreset {
    /// The frames a panel draws: the preset's own steps first, then the steps
    /// the user stored on the panel.
    ///
    /// One entry point rather than the four copies of
    /// `TransformationPipeline.apply(PanelPreset.transformations(for:), to:)`
    /// that had accumulated, because the panel's own pipeline has to run in
    /// every one of them. A transformation that applied on the stat card and
    /// not on the chart beside it would be worse than no transformation at all.
    ///
    /// Preset first: the preset is what the panel starts with, and a user step
    /// composes on top of it — `cacheHitRate`'s computed column has to exist
    /// before a filter can name it.
    static func prepared(_ frames: FrameSet, panel: PanelConfig?,
                         metric: PanelMetric) -> FrameSet {
        let seeded = TransformationPipeline.apply(transformations(for: metric), to: frames)
        guard let panel, !panel.transformations.isEmpty else { return seeded }
        return TransformationPipeline.apply(steps: panel.transformations, to: seeded)
    }
}
