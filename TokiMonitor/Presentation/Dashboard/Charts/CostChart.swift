import SwiftUI
import Charts

/// Line chart showing cost over time per model.
struct CostChart: View {
    let data: TimeSeriesData
    let enabledModels: [String]
    let colorForModel: (String) -> Color

    var body: some View {
        Chart {
            ForEach(enabledModels, id: \.self) { model in
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
                        Text(TokenFormatter.formatCost(v))
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
