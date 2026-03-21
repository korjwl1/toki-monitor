import SwiftUI
import Charts

/// Renders a time series chart panel (area or line) for the customizable dashboard.
/// Dispatches to token area chart or cost line chart based on metric.
struct TimeSeriesPanelView: View {
    let metric: PanelMetric
    @Bindable var viewModel: DashboardViewModel

    var body: some View {
        if let data = viewModel.timeSeriesData {
            if viewModel.filteredModelNames.isEmpty {
                noModelSelected
            } else {
                chartContent(data)
            }
        } else {
            loadingPlaceholder
        }
    }

    @ViewBuilder
    private func chartContent(_ data: TimeSeriesData) -> some View {
        switch metric {
        case .tokensByModel:
            tokensAreaChart(data)
        case .costByModel:
            costLineChart(data)
        default:
            Text(L.dash.error)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tokens Area Chart

    private func tokensAreaChart(_ data: TimeSeriesData) -> some View {
        let models = viewModel.filteredModelNames
        return Chart {
            ForEach(models, id: \.self) { model in
                let points = data.tokensFor(model: model)
                ForEach(points) { point in
                    AreaMark(
                        x: .value(L.dash.axisTime, point.date),
                        y: .value(L.dash.axisTokens, point.value),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value(L.dash.axisModel, model))
                    .interpolationMethod(.catmullRom)
                }
            }
        }
        .chartForegroundStyleScale(domain: models, range: models.map { viewModel.colorForModel($0) })
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisGridLine()
                AxisValueLabel(format: xAxisFormat(data))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(TokenFormatter.formatTokens(UInt64(v)))
                    }
                }
            }
        }
        .chartLegend(position: .bottom, spacing: 8)
        .frame(minHeight: 200)
    }

    // MARK: - Cost Line Chart

    private func costLineChart(_ data: TimeSeriesData) -> some View {
        let models = viewModel.filteredModelNames
        return Chart {
            ForEach(models, id: \.self) { model in
                let points = data.costFor(model: model)
                ForEach(points) { point in
                    LineMark(
                        x: .value(L.dash.axisTime, point.date),
                        y: .value(L.dash.axisCost, point.value)
                    )
                    .foregroundStyle(by: .value(L.dash.axisModel, model))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
        }
        .chartForegroundStyleScale(domain: models, range: models.map { viewModel.colorForModel($0) })
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisGridLine()
                AxisValueLabel(format: xAxisFormat(data))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(TokenFormatter.formatCost(v))
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(minHeight: 150)
    }

    // MARK: - Helpers

    private func xAxisFormat(_ data: TimeSeriesData) -> Date.FormatStyle {
        data.granularity == .hourly
            ? .dateTime.hour(.defaultDigits(amPM: .abbreviated))
            : .dateTime.month(.defaultDigits).day()
    }

    private var noModelSelected: some View {
        ContentUnavailableView(
            L.dash.selectModel,
            systemImage: "line.3.horizontal.decrease.circle",
            description: Text(L.dash.selectModelDesc)
        )
        .frame(minHeight: 150)
    }

    private var loadingPlaceholder: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 150)
    }
}
