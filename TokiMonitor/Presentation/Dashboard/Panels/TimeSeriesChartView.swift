import SwiftUI
import Charts

/// Independent time series chart with per-panel hover tooltip.
/// Each instance has its own @State hoveredDate so charts don't interfere.
struct TimeSeriesChartView: View {
    let metric: PanelMetric
    @Bindable var viewModel: DashboardViewModel
    let dateFormat: Date.FormatStyle

    @State private var hoveredDate: Date?
    @State private var hoverX: CGFloat = 0
    @State private var plotWidth: CGFloat = 1
    @State private var modelData: [(model: String, points: [TimeSeriesData.ChartPoint])] = []

    var body: some View {
        Chart {
            ForEach(modelData, id: \.model) { entry in
                ForEach(entry.points) { point in
                    LineMark(
                        x: .value(L.dash.axisTime, point.date),
                        y: .value(L.dash.axisTokens, point.value)
                    )
                    .foregroundStyle(by: .value(L.dash.axisModel, entry.model))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value(L.dash.axisTime, point.date),
                        y: .value(L.dash.axisTokens, point.value)
                    )
                    .foregroundStyle(by: .value(L.dash.axisModel, entry.model))
                    .symbolSize(16)
                }
            }

            // Hover crosshair
            if let hoveredDate {
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
        .chartForegroundStyleScale { (model: String) in
            viewModel.colorForModel(model)
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic) { _ in
                AxisGridLine()
                AxisValueLabel(format: dateFormat)
                    .font(.system(size: 9))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Color.clear
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plotFrame = geo[proxy.plotFrame!]
                            let relativeX = location.x - plotFrame.origin.x
                            if relativeX >= 0 && relativeX <= plotFrame.width {
                                hoveredDate = proxy.value(atX: location.x, as: Date.self)
                                hoverX = location.x
                                plotWidth = plotFrame.width
                            } else {
                                hoveredDate = nil
                            }
                        case .ended:
                            hoveredDate = nil
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if let hoveredDate {
                tooltipView(date: hoveredDate)
                    .offset(x: max(8, min(hoverX - 80, plotWidth - 170)), y: 4)
            }
        }
        .onAppear { animateIn() }
        .onChange(of: viewModel.dataVersion) { _, _ in animateIn() }
        .onChange(of: viewModel.enabledModels) { _, _ in
            withAnimation(.easeOut(duration: 0.3)) {
                modelData = PanelDataExtractor.allModelChartPoints(
                    for: metric,
                    enabledModels: viewModel.enabledModels,
                    data: viewModel.timeSeriesData
                )
            }
        }
        .onChange(of: viewModel.isLoading) { _, loading in
            if loading { collapseToZero() }
        }
    }

    // MARK: - Data

    private func animateIn() {
        let real = PanelDataExtractor.allModelChartPoints(
            for: metric,
            enabledModels: viewModel.enabledModels,
            data: viewModel.timeSeriesData
        )
        // Start from zero
        modelData = real.map { entry in
            (model: entry.model, points: entry.points.map {
                TimeSeriesData.ChartPoint(date: $0.date, value: 0)
            })
        }
        // Animate to real values
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

    // MARK: - Tooltip

    private func tooltipView(date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.month(.defaultDigits).day(.defaultDigits).hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(modelData, id: \.model) { entry in
                if let closest = entry.points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.colorForModel(entry.model))
                            .frame(width: 6, height: 6)
                        Text(entry.model)
                            .font(.system(size: 8))
                            .lineLimit(1)
                        Spacer()
                        Text(TokenFormatter.formatTokens(UInt64(closest.value)))
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                    }
                }
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .frame(width: 160)
    }
}
