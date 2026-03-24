import SwiftUI
import Charts

/// Renders a bar chart panel with hover crosshair and value tooltip.
struct BarChartPanelView: View {
    let metric: PanelMetric
    @Bindable var viewModel: DashboardViewModel

    @State private var hoveredDate: Date?

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
                    .opacity(hoveredDate == nil || isSameBar(point.date, hoveredDate!, data) ? 1.0 : 0.4)
                }
            }

            // Crosshair rule
            if let hDate = hoveredDate {
                RuleMark(x: .value("", hDate))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, spacing: 4) {
                        tooltipView(at: hDate, data: data, models: models)
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        withAnimation(.easeOut(duration: 0.15)) {
                            switch phase {
                            case .active(let location):
                                hoveredDate = findNearestDate(at: location, proxy: proxy, geo: geo, data: data)
                            case .ended:
                                hoveredDate = nil
                            }
                        }
                    }
            }
        }
        .frame(minHeight: 150)
    }

    // MARK: - Tooltip

    private func tooltipView(at date: Date, data: TimeSeriesData, models: [String]) -> some View {
        let values = models.compactMap { model -> (String, Int)? in
            let points = data.eventsFor(model: model)
            guard let point = points.first(where: { isSameBar($0.date, date, data) }) else { return nil }
            let v = Int(point.value)
            if v == 0 { return nil }
            return (model, v)
        }

        return VStack(alignment: .leading, spacing: 2) {
            Text(formatTooltipDate(date, data))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            ForEach(values, id: \.0) { name, value in
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.colorForModel(name))
                        .frame(width: 6, height: 6)
                    Text("\(name): \(value)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Helpers

    private func findNearestDate(at location: CGPoint, proxy: ChartProxy, geo: GeometryReader<some View>.Value, data: TimeSeriesData) -> Date? {
        let plotFrame = geo[proxy.plotFrame!]
        let x = location.x - plotFrame.minX
        guard let date: Date = proxy.value(atX: x) else { return nil }

        // Snap to nearest bar
        let allDates = data.points.map(\.date).sorted()
        return allDates.min(by: { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) })
    }

    private func isSameBar(_ a: Date, _ b: Date, _ data: TimeSeriesData) -> Bool {
        if data.granularity == .hourly {
            return Calendar.current.isDate(a, equalTo: b, toGranularity: .hour)
        }
        return Calendar.current.isDate(a, inSameDayAs: b)
    }

    private func formatTooltipDate(_ date: Date, _ data: TimeSeriesData) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        if data.granularity == .hourly {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "MM/dd"
        }
        return f.string(from: date)
    }

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
