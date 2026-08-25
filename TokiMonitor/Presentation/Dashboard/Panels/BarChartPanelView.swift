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
                            switch phase {
                            case .active(let location):
                                hoverState.date = snapToNearestBar(at: location, proxy: proxy, geo: geo, modelData: modelData)
                                hoverState.position = location
                            case .ended:
                                hoverState.date = nil
                            }
                        }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            BarChartTooltipOverlay(
                state: hoverState,
                modelData: modelData,
                bucketSecs: bucketSecs,
                colorForModel: { viewModel.colorForModel($0) },
                formatDate: { formatBarDate($0) }
            )
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
}

/// Isolated overlay that only re-renders when hover state changes,
/// without causing the parent Chart to rebuild.
struct BarChartTooltipOverlay: View {
    let state: BarHoverState
    let modelData: [(model: String, points: [TimeSeriesData.ChartPoint])]
    let bucketSecs: Int
    let colorForModel: (String) -> Color
    let formatDate: (Date) -> String

    var body: some View {
        if let date = state.date {
            let values = modelData.compactMap { entry -> (String, Int)? in
                guard let pt = entry.points.first(where: { isSameBucket($0.date, date) }) else { return nil }
                let v = Int(pt.value)
                return v > 0 ? (entry.model, v) : nil
            }
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
