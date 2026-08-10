import Foundation

// MARK: - What a panel draws
//
// One place where a panel's data becomes the shape a visualization wants.
// Frames when the datasource produced them; the legacy metric-switching
// extractor only when it did not.
//
// The point of routing every panel type through here is that the branch on
// `PanelMetric` disappears from the renderers: a preset says which FIELD to
// read and how to reduce it, and the label map says what to call each series.
// A panel pointed at a column no enum case knows about draws the same way.

/// Main-actor for the same reason `PanelDataExtractor` is: the legacy fallback
/// it delegates to reads localized strings.
@MainActor
enum PanelSeries {

    /// Transformations the panel needs, plus the field it reads afterwards.
    /// The panel's own selection wins; the preset is the starting point a panel
    /// keeps until someone changes it.
    private static func prepared(metric: PanelMetric, panel: PanelConfig?,
                                 frames: FrameSet) -> (FrameSet, FieldSelection) {
        let set = TransformationPipeline.apply(
            PanelPreset.transformations(for: metric), to: frames
        )
        return (set, panel?.fieldSelection ?? PanelPreset.selection(for: metric))
    }

    /// The name to show for a series, narrowed to one dimension when the panel
    /// asked about one. A pie headed "usage by project" should say "toki", not
    /// "toki · claude_code".
    private static func label(_ frame: Frame, key: String?) -> String {
        guard let key, let value = frame.commonLabels[key] else { return frame.displayName }
        return value
    }

    // MARK: - Time series and bars

    /// Per-series points, keyed by the name the legend shows.
    ///
    /// Absent buckets become 0 here rather than in the data: these are counters,
    /// so "this model logged nothing in this bucket" reads as zero on a chart —
    /// but that is the chart's reading, not a fact recorded about the bucket.
    static func chartPoints(metric: PanelMetric, panel: PanelConfig?, frames: FrameSet?,
                            data: TimeSeriesData?, enabled: Set<String>)
        -> [(model: String, points: [TimeSeriesData.ChartPoint])] {
        guard let frames, !frames.frames.isEmpty else {
            return PanelDataExtractor.allModelChartPoints(
                for: metric, enabledModels: enabled, data: data
            )
        }
        let (set, selection) = prepared(metric: metric, panel: panel, frames: frames)
        return FrameReader.series(set, selection: selection).compactMap { entry in
            // The model toggle list is keyed by the legacy series name; a frame
            // whose display name carries extra dimensions must still match the
            // model the user toggled, so match on the first component too.
            let modelPart = entry.name.components(separatedBy: " · ").first ?? entry.name
            guard enabled.isEmpty || enabled.contains(modelPart) || enabled.contains(entry.name)
            else { return nil }
            return (entry.name, entry.points.map {
                TimeSeriesData.ChartPoint(date: $0.date, value: $0.value ?? 0)
            })
        }
    }

    // MARK: - Tables

    /// One row per series. The frame path keeps every grouping dimension in the
    /// row name, so the same project under two providers stays two rows instead
    /// of being silently blended into one.
    static func rows(frames: FrameSet?, data: TimeSeriesData?) -> [PanelDataExtractor.ModelRow] {
        guard let frames, !frames.frames.isEmpty else {
            return PanelDataExtractor.tableRows(from: data)
        }
        return frames.frames.map { frame in
            func sum(_ name: String) -> Double? {
                guard let numbers = frame.field(named: name)?.values.numbers else { return nil }
                return ReduceTransformation.reduce(numbers, using: .sum)
            }
            return PanelDataExtractor.ModelRow(
                id: frame.displayName,
                model: frame.displayName,
                tokens: UInt64(max(0, sum("total_tokens") ?? 0)),
                cost: sum("cost_usd") ?? 0,
                events: Int(max(0, sum("events") ?? 0))
            )
        }
        .sorted { $0.tokens > $1.tokens }
    }

    // MARK: - Proportions

    /// Label and value per slice, aggregated by one dimension.
    ///
    /// Aggregating by the label rather than by the frame is what makes a pie
    /// read correctly: a query grouped by project AND provider produces two
    /// frames for one project, and a chart of proportions should show the
    /// project once.
    static func breakdown(metric: PanelMetric, panel: PanelConfig?,
                          frames: FrameSet?, data: TimeSeriesData?)
        -> [(label: String, value: Double)] {
        guard let frames, !frames.frames.isEmpty else {
            if metric == .tokensByProject {
                return PanelDataExtractor.projectBreakdown(from: data)
                    .map { (label: $0.project, value: Double($0.tokens)) }
            }
            return PanelDataExtractor.tableRows(from: data)
                .map { (label: $0.model, value: Double($0.tokens)) }
        }

        let byProject = metric == .tokensByProject
        let (set, selection) = prepared(metric: metric, panel: panel, frames: frames)

        var totals: [String: Double] = [:]
        var order: [String] = []
        for frame in set.frames {
            guard let numbers = selection.resolve(in: frame)?.values.numbers,
                  let value = ReduceTransformation.reduce(numbers, using: selection.reducer)
            else { continue }
            var name = label(frame, key: byProject ? "project" : "model")
            if byProject { name = ProjectNameResolver.cleanProjectName(name) }
            if totals[name] == nil { order.append(name) }
            totals[name, default: 0] += value
        }
        return order
            .map { (label: $0, value: totals[$0] ?? 0) }
            .sorted { $0.value > $1.value }
    }
}
