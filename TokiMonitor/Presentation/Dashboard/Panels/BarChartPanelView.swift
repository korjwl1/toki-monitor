import SwiftUI
import Charts

/// Renders a bar chart panel for the customizable dashboard.
/// For eventsByModel, displays a stacked bar chart matching EventsChart styling.
struct BarChartPanelView: View {
    let metric: PanelMetric
    @Bindable var viewModel: DashboardViewModel

    var body: some View {
        if let data = viewModel.timeSeriesData {
            if viewModel.filteredModelNames.isEmpty {
                noModelSelected
            } else {
                barChart(data)
            }
        } else {
            loadingPlaceholder
        }
    }

    private func barChart(_ data: TimeSeriesData) -> some View {
        let models = viewModel.filteredModelNames
        return Chart {
            ForEach(models, id: \.self) { model in
                let points = data.eventsFor(model: model)
                ForEach(points) { point in
                    BarMark(
                        x: .value(L.dash.axisTime, point.date),
                        y: .value(L.dash.axisCalls, point.value)
                    )
                    .foregroundStyle(by: .value(L.dash.axisModel, model))
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
                        Text("\(Int(v))")
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
