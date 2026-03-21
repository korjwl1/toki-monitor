import SwiftUI
import Charts

/// Stacked bar chart showing API call count over time per model.
struct EventsChart: View {
    let data: TimeSeriesData
    let enabledModels: [String]
    let colorForModel: (String) -> Color

    var body: some View {
        Chart {
            ForEach(enabledModels, id: \.self) { model in
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
        .chartForegroundStyleScale(domain: enabledModels, range: enabledModels.map { colorForModel($0) })
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisGridLine()
                AxisValueLabel(format: xAxisFormat)
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

    private var xAxisFormat: Date.FormatStyle {
        data.granularity == .hourly
            ? .dateTime.hour(.defaultDigits(amPM: .abbreviated))
            : .dateTime.month(.defaultDigits).day()
    }
}
