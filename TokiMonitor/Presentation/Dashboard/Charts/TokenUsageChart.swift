import SwiftUI
import Charts

/// Stacked area chart showing token usage over time per model.
struct TokenUsageChart: View {
    let data: TimeSeriesData
    let enabledModels: [String]
    let colorForModel: (String) -> Color

    var body: some View {
        Chart {
            ForEach(enabledModels, id: \.self) { model in
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
                        Text(TokenFormatter.formatTokens(UInt64(v)))
                    }
                }
            }
        }
        .chartLegend(position: .bottom, spacing: 8)
        .frame(minHeight: 200)
    }

    private var xAxisFormat: Date.FormatStyle {
        data.granularity == .hourly
            ? .dateTime.hour(.defaultDigits(amPM: .abbreviated))
            : .dateTime.month(.defaultDigits).day()
    }
}
