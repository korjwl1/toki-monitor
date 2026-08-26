import SwiftUI
import Charts

/// Independent time series chart with per-panel hover tooltip.
/// Each instance has its own @State hoveredDate so charts don't interfere.
///
/// Every display option the editor shows for a time series arrives here and
/// changes what is drawn (contract R1). Before, the line width was the literal
/// `1.5`, there was no fill, and no legend API was called at all — so five
/// controls in the editor moved and the screen did not.
struct TimeSeriesChartView: View {
    let metric: PanelMetric
    /// THIS panel's result. Previously the view read `viewModel.timeSeriesData`
    /// — a global holding whichever regular panel happened to load first — so
    /// two time-series panels with different queries rendered identical data.
    /// Every other panel type already received its own `data`; only this one
    /// did not.
    let data: TimeSeriesData?
    /// Frames for this panel. When present the chart reads series from fields
    /// and labels — so a query grouped by two dimensions draws one line per
    /// (model, project) rather than collapsing them onto a single name.
    var frames: FrameSet?
    var panel: PanelConfig?
    @Bindable var viewModel: DashboardViewModel
    let dateFormat: Date.FormatStyle

    @State private var hoveredDate: Date?
    @State private var hoveredValue: Double?
    @State private var hoverX: CGFloat = 0
    @State private var plotWidth: CGFloat = 1
    @State private var segments: [LineSegment] = []

    private var options: PanelDisplayOptions { panel?.options ?? PanelDisplayOptions() }

    /// A run of consecutive samples with no gap in them.
    ///
    /// Charts joins consecutive `LineMark`s that share a series, so a gap can
    /// only be drawn by NOT sharing one. Each run therefore gets its own series
    /// id while keeping the model name for colour and legend — which is what
    /// makes an absent bucket read as absent instead of as a dive to zero.
    struct LineSegment: Identifiable {
        let id: String
        let model: String
        var points: [TimeSeriesData.ChartPoint]
    }

    var body: some View {
        // The legend is drawn beside the chart rather than by it: Swift Charts'
        // own legend cannot be clicked, and clicking it is the whole point
        // (contract R7).
        // Resolved once per render and handed down. Read as a computed property
        // it would re-run the panel's whole pipeline for every series the
        // colour scale asks about.
        let styles = self.styles
        switch legendPlacement {
        case .none:
            chartBody(styles: styles)
        case .bottom:
            VStack(spacing: DS.xs) {
                chartBody(styles: styles)
                legend(styles: styles)
            }
        case .trailing:
            HStack(alignment: .center, spacing: DS.sm) {
                chartBody(styles: styles)
                legend(styles: styles).frame(maxWidth: 140)
            }
        }
    }

    private func chartBody(styles: [String: FieldDisplayConfig]) -> some View {
        chart
            .chartLegend(.hidden)
            .chartForegroundStyleScale { (model: String) in
                self.color(for: model, styles: styles)
            }
            .modifier(YAxisDomain(range: pinnedYDomain(styles: styles)))
            .chartXAxis {
                AxisMarks(preset: .aligned, values: .automatic) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: dateFormat)
                        .font(.system(size: DS.fontTiny))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Color.clear
                        .onContinuousHover { phase in
                            guard showsTooltip else { return }
                            switch phase {
                            case .active(let location):
                                track(location, proxy: proxy, geo: geo)
                            case .ended:
                                hoveredDate = nil
                                hoveredValue = nil
                            }
                        }
                }
            }
            .overlay(alignment: .topLeading) {
                if showsTooltip, let hoveredDate {
                    tooltipView(date: hoveredDate, styles: styles)
                        .offset(x: max(8, min(hoverX - 80, plotWidth - 170)), y: 4)
                }
            }
            .onAppear { animateIn() }
            .onChange(of: viewModel.dataVersion) { _, _ in animateIn() }
            .onChange(of: hiddenSeries) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) { segments = Self.segments(from: series()) }
            }
            .onChange(of: viewModel.isLoading) { _, loading in
                if loading { collapseToZero() }
            }
    }

    private var chart: some View {
        Chart {
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    // Fill first so the line sits on top of its own area.
                    // Unstacked on purpose: these series answer the same
                    // question about different models, and stacking them would
                    // make each one's height mean a total nobody asked for.
                    if options.fillOpacity > 0 {
                        AreaMark(
                            x: .value(L.dash.axisTime, point.date),
                            y: .value(L.dash.axisTokens, point.value),
                            series: .value("segment", segment.id),
                            stacking: .unstacked
                        )
                        .foregroundStyle(by: .value(L.dash.axisModel, segment.model))
                        .opacity(options.fillOpacity)
                        .interpolationMethod(.monotone)
                    }

                    LineMark(
                        x: .value(L.dash.axisTime, point.date),
                        y: .value(L.dash.axisTokens, point.value),
                        series: .value("segment", segment.id)
                    )
                    .foregroundStyle(by: .value(L.dash.axisModel, segment.model))
                    .lineStyle(StrokeStyle(lineWidth: options.lineWidth,
                                           lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value(L.dash.axisTime, point.date),
                        y: .value(L.dash.axisTokens, point.value)
                    )
                    .foregroundStyle(by: .value(L.dash.axisModel, segment.model))
                    .symbolSize(pointSize)
                }
            }

            // Threshold rules. The steps were editable for years and reached
            // nothing but the gauge; on a line chart they are the horizontal
            // lines that say where "too much" starts.
            ForEach(thresholdRules, id: \.at) { rule in
                RuleMark(y: .value(L.tr("임계값", "Threshold"), rule.at))
                    .foregroundStyle(DS.threshold(rule.color))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 1) {
                        // The line's own value, so the band is legible without
                        // separating the hues (계약 R6).
                        Text(rule.label)
                            .font(.system(size: DS.fontTiny, design: .monospaced))
                            .foregroundStyle(DS.threshold(rule.color))
                    }
            }

            // Hover crosshair
            if showsTooltip, let hoveredDate {
                RuleMark(x: .value("", hoveredDate))
                    .foregroundStyle(.primary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }

            // Annotation markers
            ForEach(viewModel.annotations) { annotation in
                RuleMark(x: .value("", annotation.timestamp))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
            }
        }
    }

    // MARK: - Options

    /// The toggle and the position are two ways of saying the same thing, and
    /// either one saying "no" wins — a reader who set the position to Hidden
    /// and a reader who switched the toggle off both expect no legend.
    private var showsLegend: Bool {
        options.showLegend && options.legendPosition != .hidden
    }

    /// Where the legend goes, or nowhere.
    private enum LegendPlacement { case none, bottom, trailing }

    private var legendPlacement: LegendPlacement {
        guard showsLegend else { return .none }
        return options.legendPosition == .right ? .trailing : .bottom
    }

    /// Every series the panel would draw, hidden ones included — a legend
    /// missing its own hidden entries could not bring them back.
    private func legend(styles: [String: FieldDisplayConfig]) -> some View {
        PanelLegendView(
            entries: PanelSeries.seriesNames(metric: metric, panel: panel,
                                             frames: frames, data: data)
                .map { .init(name: $0, color: color(for: $0, styles: styles)) },
            hidden: hiddenSeries,
            position: options.legendPosition,
            onToggle: { name in
                guard let panelID = panel?.id else { return }
                viewModel.toggleSeries(name, panelID: panelID)
            }
        )
    }

    /// What the reader hid on THIS panel. A preview with no panel of its own
    /// hides nothing.
    private var hiddenSeries: Set<String> {
        guard let id = panel?.id else { return [] }
        return viewModel.hiddenSeries(for: id)
    }

    private var showsTooltip: Bool { options.tooltipMode != .hidden }

    // MARK: - Field overrides

    /// The resolved display config for each series, keyed by the name the chart
    /// draws it under. Empty unless the panel has rules.
    private var styles: [String: FieldDisplayConfig] {
        PanelSeries.styles(metric: metric, panel: panel, frames: frames)
    }

    /// A series' colour: the override's, when one names it, else the shared
    /// model palette — so a model keeps one colour across every panel that did
    /// not deliberately say otherwise.
    private func color(for series: String,
                       styles: [String: FieldDisplayConfig]) -> Color {
        DS.seriesColor(styles[series]?.color) ?? viewModel.colorForModel(series)
    }

    /// The y axis, when an override pins one or both ends. Nil leaves the chart
    /// to size itself and include zero, as it always has.
    ///
    /// A half-stated range is completed from the data rather than from zero: a
    /// reader who wrote only a maximum meant "cap the top", not "and start at
    /// whatever you like".
    private func pinnedYDomain(styles: [String: FieldDisplayConfig]) -> ClosedRange<Double>? {
        let bounds = styles.values
        let low = bounds.compactMap(\.min).min()
        let high = bounds.compactMap(\.max).max()
        guard low != nil || high != nil else { return nil }
        let drawn = segments.flatMap { $0.points.map(\.value) }
        let lower = low ?? Swift.min(0, drawn.min() ?? 0)
        let upper = high ?? Swift.max(drawn.max() ?? lower, lower)
        guard upper > lower else { return nil }
        return lower...upper
    }

    /// A value in the unit its own series was given.
    private func format(_ value: Double, series: String,
                        styles: [String: FieldDisplayConfig]) -> String {
        if let config = styles[series], !config.isEmpty {
            return FieldFormatter.format(value, config: config)
        }
        return TokenFormatter.formatTokens(UInt64(Swift.max(0, value)))
    }

    /// Where each threshold sits on this chart's own y axis.
    ///
    /// In percentage mode the scale is what the chart is actually drawing —
    /// a line chart has no stated ends, so the data's own range is the only
    /// honest thing to take a percentage of. With no data there is no range,
    /// and `Thresholds.placed` then yields nothing rather than stacking every
    /// step at zero.
    private var thresholdRules: [(at: Double, color: ThresholdColor, label: String)] {
        guard options.showThresholdMarkers, !options.thresholds.isEmpty else { return [] }
        let drawn = segments.flatMap { $0.points.map(\.value) }
        let scale = drawn.isEmpty ? nil : (drawn.min() ?? 0)...(drawn.max() ?? 0)
        let suffix = options.thresholdMode == .percentage ? "%" : ""
        return Thresholds
            .placed(options.thresholds, mode: options.thresholdMode, scale: scale)
            .map { entry in
                let written = entry.step.value
                let text = written == written.rounded()
                    ? "\(Int(written))\(suffix)"
                    : String(format: "%g%@", written, suffix)
                return (at: entry.at, color: entry.step.color, label: text)
            }
    }

    /// Dots scale with the line so a 5pt line is not decorated with pinheads.
    private var pointSize: CGFloat { max(12, options.lineWidth * 8) }

    // MARK: - Data

    private func series() -> [(model: String, points: [(date: Date, value: Double?)])] {
        PanelSeries.chartSeriesWithGaps(metric: metric, panel: panel, frames: frames,
                                        data: data, hidden: hiddenSeries)
    }

    /// Split each series at its gaps. A nil sample ends the run it is in and
    /// the next present sample starts a new one.
    static func segments(
        from series: [(model: String, points: [(date: Date, value: Double?)])]
    ) -> [LineSegment] {
        var out: [LineSegment] = []
        for entry in series {
            var run: [TimeSeriesData.ChartPoint] = []
            var index = 0
            func flush() {
                guard !run.isEmpty else { return }
                out.append(LineSegment(id: "\(entry.model)#\(index)",
                                       model: entry.model, points: run))
                index += 1
                run = []
            }
            for point in entry.points {
                if let value = point.value {
                    run.append(TimeSeriesData.ChartPoint(date: point.date, value: value))
                } else {
                    flush()
                }
            }
            flush()
        }
        return out
    }

    private func animateIn() {
        let real = Self.segments(from: series())
        // Start from zero
        segments = real.map { segment in
            LineSegment(id: segment.id, model: segment.model,
                        points: segment.points.map {
                            TimeSeriesData.ChartPoint(date: $0.date, value: 0)
                        })
        }
        // Animate to real values
        withAnimation(.easeOut(duration: 0.3)) {
            segments = real
        }
    }

    private func collapseToZero() {
        withAnimation(.easeIn(duration: 0.15)) {
            segments = segments.map { segment in
                LineSegment(id: segment.id, model: segment.model,
                            points: segment.points.map {
                                TimeSeriesData.ChartPoint(date: $0.date, value: 0)
                            })
            }
        }
    }

    // MARK: - Hover

    private func track(_ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let plotRect = geo[plotFrame]
        let relativeX = location.x - plotRect.origin.x
        guard relativeX >= 0, relativeX <= plotRect.width else {
            hoveredDate = nil
            hoveredValue = nil
            return
        }
        hoveredDate = proxy.value(atX: location.x, as: Date.self)
        // Only `.single` needs to know where the cursor is vertically: it is
        // the value that decides which series the reader is pointing at.
        hoveredValue = options.tooltipMode == .single
            ? proxy.value(atY: location.y - plotRect.origin.y, as: Double.self)
            : nil
        hoverX = location.x
        plotWidth = plotRect.width
    }

    // MARK: - Tooltip

    /// One row per series, or just the series under the cursor.
    ///
    /// `.single` and `.all` are the two readings a tooltip can have and they
    /// answer different questions — "what is this line worth here" versus
    /// "how do the lines compare here". Both were in the editor; neither was
    /// implemented, and the tooltip always listed every series.
    private func tooltipRows(date: Date) -> [(model: String, value: Double)] {
        // A model split by gaps is several segments and still one row: the
        // sample nearest the cursor wins, wherever it sits.
        var order: [String] = []
        var pointsByModel: [String: [TimeSeriesData.ChartPoint]] = [:]
        for segment in segments {
            if pointsByModel[segment.model] == nil { order.append(segment.model) }
            pointsByModel[segment.model, default: []].append(contentsOf: segment.points)
        }
        let rows: [(model: String, value: Double)] = order.compactMap { model in
            guard let closest = pointsByModel[model]?.min(by: {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            }) else { return nil }
            return (model: model, value: closest.value)
        }
        guard options.tooltipMode == .single, let hoveredValue else { return rows }
        guard let nearest = rows.min(by: {
            abs($0.value - hoveredValue) < abs($1.value - hoveredValue)
        }) else { return rows }
        return [nearest]
    }

    private func tooltipView(date: Date,
                             styles: [String: FieldDisplayConfig]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.month(.defaultDigits).day(.defaultDigits).hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits))
                .font(.system(size: DS.fontTiny, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
            ForEach(tooltipRows(date: date), id: \.model) { row in
                HStack(spacing: 4) {
                    Circle()
                        .fill(color(for: row.model, styles: styles))
                        .frame(width: 6, height: 6)
                    Text(row.model)
                        .font(.system(size: 9))
                        .lineLimit(1)
                    Spacer()
                    Text(format(row.value, series: row.model, styles: styles))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                }
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .frame(width: 160)
    }
}

/// A y scale that is either pinned by a field override or left automatic.
///
/// Two `chartYScale` calls with different domain types cannot be one expression,
/// and a chart that applied the automatic one and then the pinned one would
/// keep the last — which is the wrong half whenever there is no override.
private struct YAxisDomain: ViewModifier {
    let range: ClosedRange<Double>?

    func body(content: Content) -> some View {
        if let range {
            content.chartYScale(domain: range)
        } else {
            content.chartYScale(domain: .automatic(includesZero: true))
        }
    }
}
