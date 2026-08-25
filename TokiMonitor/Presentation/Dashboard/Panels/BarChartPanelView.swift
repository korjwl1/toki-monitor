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

    private var options: PanelDisplayOptions { panel.options }

    var body: some View {
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
            viewModel.colorForModel(model)
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic) { _ in
                AxisGridLine()
                AxisValueLabel(format: dateFormat)
                    .font(.system(size: 9))
            }
        }
        .chartLegend(position: .bottom, alignment: .center, spacing: DS.sm)
        .chartLegend(options.showLegend ? .visible : .hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    if hoverState.date != nil, let plotFrame = proxy.plotFrame {
                        let plotRect = geo[plotFrame]
                        Rectangle()
                            .fill(.secondary.opacity(0.3))
                            .frame(width: 1, height: plotRect.height)
                            .offset(x: hoverState.position.x, y: plotRect.minY)
                            .allowsHitTesting(false)
                    }

                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard options.tooltipMode != .hidden else { return }
                            switch phase {
                            case .active(let location):
                                hoverState.date = snapToNearestBar(at: location, proxy: proxy, geo: geo, modelData: modelData)
                                hoverState.position = location
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
                            }
                        }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if options.tooltipMode != .hidden {
                BarChartTooltipOverlay(
                    state: hoverState,
                    modelData: modelData,
                    bucketSecs: bucketSecs,
                    mode: options.tooltipMode,
                    colorForModel: { viewModel.colorForModel($0) },
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
    }

    private func animateIn() {
        let real = PanelSeries.chartPoints(
            metric: panel.effectiveMetric, panel: panel, frames: frames,
            data: data, enabled: viewModel.enabledModels
        )
        modelData = real.map { entry in
            (model: entry.model, points: entry.points.map {
                TimeSeriesData.ChartPoint(date: $0.date, value: 0)
            })
        }
        withAnimation(.easeOut(duration: 0.3)) {
            modelData = real
        }
    }

    private func collapseToZero() {
        withAnimation(.easeIn(duration: 0.15)) {
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

    private func formatBarDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        let secs = viewModel.dashboardConfig.time.bucketSeconds
        if secs < 3600 {
            f.dateFormat = "HH:mm"
        } else if secs < 86400 {
            f.dateFormat = "M/d HH:mm"
        } else {
            f.dateFormat = "M/d"
        }
        return f.string(from: date)
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
    let formatDate: (Date) -> String

    var body: some View {
        if let date = state.date {
            let all = modelData.compactMap { entry -> (String, Int)? in
                guard let pt = entry.points.first(where: { isSameBucket($0.date, date) }) else { return nil }
                let v = Int(pt.value)
                return v > 0 ? (entry.model, v) : nil
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
                        Text("\(name): \(value)")
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
    static func bandUnderCursor(_ values: [(String, Int)], at value: Double?) -> [(String, Int)] {
        guard let value, !values.isEmpty else { return values }
        var lower = 0.0
        for entry in values {
            let upper = lower + Double(entry.1)
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
