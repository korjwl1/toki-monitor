import SwiftUI
import Charts

/// Bar chart panel render.
///
/// Moved here verbatim from `CustomDashboardView.barChartContent` (and the
/// `barAnimateIn` / `barCollapseToZero` / `snapToNearestBar` / `formatBarDate`
/// helpers that only it used) so that a panel type has exactly one render
/// implementation in the app (contract R2). What this file used to contain —
/// a bar chart reading `viewModel.timeSeriesData` directly — was never
/// instantiated.
///
/// The hover state and the animated series now belong to the panel rather than
/// to the dashboard. They were `@State` on `CustomDashboardView`, which is one
/// view for the whole grid: two bar panels shared a single crosshair and a
/// single `barModelData`, so the second one to appear overwrote the first.
/// Nothing else could follow from moving a stateful view into its own type.
struct BarChartPanelView: View {
    let panel: PanelConfig
    let data: TimeSeriesData?
    let frames: FrameSet?
    @Bindable var viewModel: DashboardViewModel
    let dateFormat: Date.FormatStyle

    @State private var hoverState = BarHoverState()
    @State private var modelData: [(model: String, points: [TimeSeriesData.ChartPoint])] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var options: PanelDisplayOptions { panel.options }

    var body: some View {
        // Same arrangement as the time series: the legend is ours, because a
        // legend that cannot be clicked is not the series control the contract
        // asks for (R7).
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
        let bucketSecs = viewModel.dashboardConfig.time.bucketSeconds
        return Chart {
            ForEach(modelData, id: \.model) { entry in
                ForEach(entry.points) { point in
                    BarMark(
                        x: .value(L.dash.axisTime, point.date),
                        y: .value(L.dash.axisCalls, point.value)
                    )
                    .foregroundStyle(by: .value(L.dash.axisModel, entry.model))
                }
            }
        }
        .chartForegroundStyleScale { (model: String) in
            self.color(for: model, styles: styles)
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic) { _ in
                AxisGridLine()
                AxisValueLabel(format: dateFormat)
                    .font(.system(size: 9))
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // The shared instant (US7), drawn from the dashboard's
                    // crosshair rather than from this panel's own hover — so
                    // pointing at the line chart above marks the same moment
                    // here. `x(for:)` places it, because a bar chart's rule has
                    // to be positioned by hand: the overlay is not a mark and
                    // has no scale of its own.
                    if let shared = viewModel.crosshair.date,
                       let plotFrame = proxy.plotFrame,
                       let x = proxy.position(forX: shared) {
                        let plotRect = geo[plotFrame]
                        Rectangle()
                            .fill(DS.iconSecondary)
                            .frame(width: 1, height: plotRect.height)
                            .offset(x: plotRect.minX + x, y: plotRect.minY)
                            .allowsHitTesting(false)
                    }

                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard options.tooltipMode != .hidden else { return }
                            switch phase {
                            case .active(let location):
                                let snapped = snapToNearestBar(at: location, proxy: proxy, geo: geo, modelData: modelData)
                                hoverState.date = snapped
                                hoverState.position = location
                                // A bar chart snaps to a bucket, so what it
                                // publishes is the bucket's own instant — which
                                // is the honest thing to mark on the charts
                                // beside it.
                                if let snapped {
                                    viewModel.crosshair.move(to: snapped, panelID: panel.id)
                                }
                                // Which stacked band the cursor is in. Only
                                // `.single` needs it, but reading it here keeps
                                // the geometry in the one place that has it.
                                if let plotFrame = proxy.plotFrame {
                                    let plotRect = geo[plotFrame]
                                    hoverState.value = proxy.value(
                                        atY: location.y - plotRect.minY, as: Double.self
                                    )
                                }
                            case .ended:
                                hoverState.date = nil
                                hoverState.value = nil
                                viewModel.crosshair.clear(panelID: panel.id)
                            }
                        }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            // The rule is shared; the tooltip is not — one tooltip per panel
            // would cover the very charts the shared rule exists to compare.
            if options.tooltipMode != .hidden, viewModel.crosshair.isOwner(panel.id) {
                BarChartTooltipOverlay(
                    state: hoverState,
                    modelData: modelData,
                    bucketSecs: bucketSecs,
                    mode: options.tooltipMode,
                    colorForModel: { color(for: $0, styles: styles) },
                    formatValue: { format($0, series: $1, styles: styles) },
                    formatDate: { formatBarDate($0) }
                )
            }
        }
        .onAppear { animateIn() }
        .onChange(of: viewModel.dataVersion) { _, _ in
            animateIn()
        }
        .onChange(of: viewModel.isLoading) { _, loading in
            if loading { collapseToZero() }
        }
        .onChange(of: hiddenSeries) { _, _ in animateIn() }
    }

    // MARK: - Legend

    private enum LegendPlacement { case none, bottom, trailing }

    private var legendPlacement: LegendPlacement {
        guard options.showLegend, options.legendPosition != .hidden else { return .none }
        return options.legendPosition == .right ? .trailing : .bottom
    }

    private func legend(styles: [String: FieldDisplayConfig]) -> some View {
        PanelLegendView(
            entries: PanelSeries.seriesNames(metric: panel.effectiveMetric, panel: panel,
                                             frames: frames, data: data)
                .map { .init(name: $0, color: color(for: $0, styles: styles)) },
            hidden: hiddenSeries,
            position: options.legendPosition,
            onToggle: { viewModel.toggleSeries($0, panelID: panel.id) }
        )
    }

    private var hiddenSeries: Set<String> { viewModel.hiddenSeries(for: panel.id) }

    // MARK: - Field overrides

    private var styles: [String: FieldDisplayConfig] {
        PanelSeries.styles(metric: panel.effectiveMetric, panel: panel, frames: frames)
    }

    /// The override's colour when one names this series, else the shared model
    /// palette — so a model keeps one colour across panels.
    private func color(for series: String,
                       styles: [String: FieldDisplayConfig]) -> Color {
        DS.seriesColor(styles[series]?.color) ?? viewModel.colorForModel(series)
    }

    /// A bar's value in the unit its own series was given. The tooltip printed
    /// a bare integer before, so a cost series read "3" for three dollars.
    private func format(_ value: Double, series: String,
                        styles: [String: FieldDisplayConfig]) -> String {
        if let config = styles[series], !config.isEmpty {
            return FieldFormatter.format(value, config: config)
        }
        return PanelValueFormat.fallback(value)
    }

    private func animateIn() {
        let real = PanelSeries.chartPoints(
            metric: panel.effectiveMetric, panel: panel, frames: frames,
            data: data, hidden: hiddenSeries
        )
        // See `TimeSeriesChartView.animateIn` — bars growing out of the axis
        // are the same motion, and Reduce Motion drops it here too (FR-064).
        guard Motion.growsFromZero(reduceMotion) else {
            modelData = real
            return
        }
        modelData = real.map { entry in
            (model: entry.model, points: entry.points.map {
                TimeSeriesData.ChartPoint(date: $0.date, value: 0)
            })
        }
        withAnimation(Motion.data(reduceMotion)) {
            modelData = real
        }
    }

    private func collapseToZero() {
        guard Motion.growsFromZero(reduceMotion) else { return }
        withAnimation(Motion.dataOut(reduceMotion)) {
            modelData = modelData.map { entry in
                (model: entry.model, points: entry.points.map {
                    TimeSeriesData.ChartPoint(date: $0.date, value: 0)
                })
            }
        }
    }

    private func snapToNearestBar(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, modelData: [(model: String, points: [TimeSeriesData.ChartPoint])]) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let plotRect = geo[plotFrame]

        // Only respond within the plot area
        guard plotRect.contains(location) else { return nil }

        let x = location.x - plotRect.minX
        guard let date: Date = proxy.value(atX: x) else { return nil }
        let allDates = modelData.flatMap { $0.points.map(\.date) }
        let unique = Array(Set(allDates)).sorted()
        return unique.min(by: { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) })
    }

    /// The same style the axis beside it uses.
    ///
    /// This used to build its own `DateFormatter` per call with a hardcoded
    /// `"HH:mm"`. Setting `locale` does not undo a fixed format string, so a
    /// reader whose region uses a 12-hour clock got `2:30 PM` on the axis and
    /// `14:30` in the tooltip of the same chart. `PanelDateFormat`'s own
    /// comment says it exists because "a preview whose axis is formatted
    /// differently from the dashboard is showing a different chart" — the same
    /// argument applies within one chart.
    private func formatBarDate(_ date: Date) -> String {
        date.formatted(
            PanelDateFormat.forBucket(seconds: viewModel.dashboardConfig.time.bucketSeconds)
        )
    }
}

// MARK: - Bar Chart Hover State

@Observable
final class BarHoverState {
    var date: Date?
    var position: CGPoint = .zero
    /// The data value under the cursor, used to pick one band out of a stack.
    var value: Double?
}

/// Isolated overlay that only re-renders when hover state changes,
/// without causing the parent Chart to rebuild.
struct BarChartTooltipOverlay: View {
    let state: BarHoverState
    let modelData: [(model: String, points: [TimeSeriesData.ChartPoint])]
    let bucketSecs: Int
    /// `.single` names the one bar under the cursor; `.all` lists the bucket.
    /// Both were offered in the editor and neither was implemented — the
    /// tooltip always listed everything.
    let mode: PanelDisplayOptions.TooltipMode
    let colorForModel: (String) -> Color
    /// A value in the unit its own series was given (contract R1) — the row
    /// used to print `Int(value)` regardless, so a cost series read "3".
    let formatValue: (Double, String) -> String
    let formatDate: (Date) -> String

    var body: some View {
        if let date = state.date {
            let all = modelData.compactMap { entry -> (String, Double)? in
                guard let pt = entry.points.first(where: { isSameBucket($0.date, date) }) else { return nil }
                return pt.value > 0 ? (entry.model, pt.value) : nil
            }
            let values = mode == .single ? Self.bandUnderCursor(all, at: state.value) : all
            VStack(alignment: .leading, spacing: 2) {
                Text(formatDate(date))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                ForEach(values, id: \.0) { name, value in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(colorForModel(name))
                            .frame(width: 6, height: 6)
                        Text("\(name): \(formatValue(value, name))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                }
            }
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .offset(x: state.position.x - 40, y: max(state.position.y - 60, 0))
            .allowsHitTesting(false)
        }
    }

    private func isSameBucket(_ a: Date, _ b: Date) -> Bool {
        BarChartTime.isSameBucket(a, b, bucketSecs: bucketSecs)
    }

    /// The stacked band containing `value`. Bars are drawn bottom-up in series
    /// order, so the bands are the running sums; a cursor above the stack
    /// belongs to the topmost band rather than to nothing.
    static func bandUnderCursor(_ values: [(String, Double)],
                                at value: Double?) -> [(String, Double)] {
        guard let value, !values.isEmpty else { return values }
        var lower = 0.0
        for entry in values {
            let upper = lower + entry.1
            if value <= upper { return [entry] }
            lower = upper
        }
        return values.suffix(1).map { $0 }
    }
}

/// Bucket-equality helper used by both the bar chart hover lookup and
/// the tooltip overlay's date lookup. Two separate copies had grown
/// over time — extracted here so a future granularity tweak only has
/// one place to land.
enum BarChartTime {
    static func isSameBucket(_ a: Date, _ b: Date, bucketSecs: Int) -> Bool {
        if bucketSecs < 3600 {
            return Calendar.current.isDate(a, equalTo: b, toGranularity: .minute)
        } else if bucketSecs < 86400 {
            return Calendar.current.isDate(a, equalTo: b, toGranularity: .hour)
        }
        return Calendar.current.isDate(a, inSameDayAs: b)
    }
}
