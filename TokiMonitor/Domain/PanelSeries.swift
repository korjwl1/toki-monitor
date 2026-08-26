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
        let set = PanelPreset.prepared(frames, panel: panel, metric: metric)
        return (set, panel?.fieldSelection ?? PanelPreset.selection(for: metric))
    }

    /// The name to show for a series, narrowed to one dimension when the panel
    /// asked about one. A pie headed "usage by project" should say "toki", not
    /// "toki · claude_code".
    private static func label(_ frame: Frame, key: String?) -> String {
        guard let key, let value = frame.commonLabels[key] else { return frame.displayName }
        return value
    }

    /// How this panel names a series, or nil when it says nothing and the
    /// frame's own name stands.
    ///
    /// Returned as a closure rather than applied afterwards because the rule is
    /// matched against the FIELD the panel reads, and only `FrameReader` knows
    /// which field a given series resolved to.
    private static func naming(_ panel: PanelConfig?) -> ((Frame, Field) -> String)? {
        guard let panel, panel.hasFieldConfig,
              panel.panelType.honouredFieldProperties.contains(.displayName)
        else { return nil }
        return { frame, field in panel.seriesName(frame.displayName, field: field) }
    }

    // MARK: - Per-series display config

    /// The resolved display config for each series this panel draws, keyed by
    /// the name the render uses for it.
    ///
    /// This is how a rule reaches a chart: the renderer asks by series name,
    /// which is the only identity it has at the point where it is choosing a
    /// colour or formatting a tooltip row. Empty when the panel has no rules,
    /// so the common case costs one dictionary that is never built.
    static func styles(metric: PanelMetric, panel: PanelConfig?,
                       frames: FrameSet?) -> [String: FieldDisplayConfig] {
        guard let panel, panel.hasFieldConfig, let frames, !frames.frames.isEmpty
        else { return [:] }
        let (set, selection) = prepared(metric: metric, panel: panel, frames: frames)
        let name = naming(panel)
        var out: [String: FieldDisplayConfig] = [:]
        for frame in set.frames {
            guard let field = selection.resolve(in: frame) else { continue }
            out[name?(frame, field) ?? frame.displayName] = panel.displayConfig(for: field)
        }
        return out
    }

    // MARK: - Time series and bars

    /// Per-series points, keyed by the name the legend shows.
    ///
    /// Absent buckets become 0 here rather than in the data: these are counters,
    /// so "this model logged nothing in this bucket" reads as zero on a chart —
    /// but that is the chart's reading, not a fact recorded about the bucket.
    static func chartPoints(metric: PanelMetric, panel: PanelConfig?, frames: FrameSet?,
                            data: TimeSeriesData?, hidden: Set<String> = [])
        -> [(model: String, points: [TimeSeriesData.ChartPoint])] {
        guard let frames, !frames.frames.isEmpty else {
            return PanelDataExtractor.allModelChartPoints(
                for: metric, hidden: hidden, data: data
            )
        }
        let (set, selection) = prepared(metric: metric, panel: panel, frames: frames)
        return FrameReader.series(set, selection: selection, name: naming(panel))
            .compactMap { entry in
                guard !isHidden(entry.name, in: hidden) else { return nil }
                return (entry.name, entry.points.map {
                    TimeSeriesData.ChartPoint(date: $0.date, value: $0.value ?? 0)
                })
            }
    }

    /// Per-series points that keep an absent bucket ABSENT.
    ///
    /// `chartPoints` fills gaps with zero, which is the right reading for a bar
    /// chart of counters. It is the wrong reading for a line: joining across a
    /// gap draws a descent to zero and a climb back out, and a reader cannot
    /// tell that invented V from a real one. A line chart asks here instead and
    /// breaks the line at the gap (contract R4).
    ///
    /// The legacy extractor has no absence to report — it computes every bucket
    /// — so that path yields all-present points and behaves exactly as before.
    static func chartSeriesWithGaps(metric: PanelMetric, panel: PanelConfig?, frames: FrameSet?,
                                    data: TimeSeriesData?, hidden: Set<String> = [])
        -> [(model: String, points: [(date: Date, value: Double?)])] {
        guard let frames, !frames.frames.isEmpty else {
            return PanelDataExtractor.allModelChartPoints(
                for: metric, hidden: hidden, data: data
            ).map { ($0.model, $0.points.map { (date: $0.date, value: Double?($0.value)) }) }
        }
        let (set, selection) = prepared(metric: metric, panel: panel, frames: frames)
        return FrameReader.series(set, selection: selection, name: naming(panel))
            .compactMap { entry in
                guard !isHidden(entry.name, in: hidden) else { return nil }
                return (entry.name, entry.points)
            }
    }

    /// Every series this panel would draw, hidden ones included.
    ///
    /// The legend needs the full list: an entry the reader switched off is the
    /// only way to switch it back on, so a legend built from what is drawn
    /// would swallow its own controls one by one.
    static func seriesNames(metric: PanelMetric, panel: PanelConfig?,
                            frames: FrameSet?, data: TimeSeriesData?) -> [String] {
        chartSeriesWithGaps(metric: metric, panel: panel, frames: frames, data: data)
            .map(\.model)
    }

    /// Whether the reader hid this series.
    ///
    /// A frame grouped by two dimensions displays as `opus · toki`, and the
    /// legend offers exactly that string — but a legacy series name is the bare
    /// model, so the first component is matched too and a chart that gained a
    /// second grouping does not quietly un-hide everything.
    private static func isHidden(_ name: String, in hidden: Set<String>) -> Bool {
        if hidden.isEmpty { return false }
        if hidden.contains(name) { return true }
        let head = name.components(separatedBy: " · ").first ?? name
        return hidden.contains(head)
    }

    // MARK: - Tables

    /// One row per series. The frame path keeps every grouping dimension in the
    /// row name, so the same project under two providers stays two rows instead
    /// of being silently blended into one.
    ///
    /// `panel` is not decoration: a table has to run the panel's own
    /// transformation pipeline like every other visualization does, or a step
    /// the reader added would apply to the chart above and not to the table
    /// below it.
    static func rows(panel: PanelConfig? = nil, frames: FrameSet?,
                     data: TimeSeriesData?) -> [PanelDataExtractor.ModelRow] {
        guard let frames, !frames.frames.isEmpty else {
            return PanelDataExtractor.tableRows(from: data)
        }
        let metric = panel?.effectiveMetric ?? .totalTokens
        let prepared = PanelPreset.prepared(frames, panel: panel, metric: metric)
        let name = naming(panel)
        let selection = panel?.fieldSelection ?? PanelPreset.selection(for: metric)
        return prepared.frames.map { frame in
            func sum(_ name: String) -> Double? {
                guard let numbers = frame.field(named: name)?.values.numbers else { return nil }
                return ReduceTransformation.reduce(numbers, using: .sum)
            }
            let rowName = selection.resolve(in: frame)
                .flatMap { field in name?(frame, field) } ?? frame.displayName
            return PanelDataExtractor.ModelRow(
                id: rowName,
                model: rowName,
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
            // An explicit display name wins over the dimension narrowing: the
            // reader who wrote one has said what to call this slice. The
            // narrowed name stays the fallback, so a panel with rules that do
            // not name anything still says "toki" rather than "toki · opus".
            if let panel, panel.hasFieldConfig,
               panel.panelType.honouredFieldProperties.contains(.displayName),
               let field = selection.resolve(in: frame) {
                name = panel.seriesName(name, field: field)
            }
            if totals[name] == nil { order.append(name) }
            totals[name, default: 0] += value
        }
        return order
            .map { (label: $0, value: totals[$0] ?? 0) }
            .sorted { $0.value > $1.value }
    }
}
