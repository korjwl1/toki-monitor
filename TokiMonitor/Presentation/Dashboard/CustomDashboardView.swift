import SwiftUI
import Charts

/// Responsive dashboard grid view.
/// Fills the available window space — panels resize dynamically with the window.
struct CustomDashboardView: View {
    @Bindable var viewModel: DashboardViewModel
    var onEditPanel: ((PanelConfig) -> Void)?

    @State private var barHoverState = BarHoverState()
    @State private var barModelData: [(model: String, points: [TimeSeriesData.ChartPoint])] = []
    @State private var barAnimated = false


    var body: some View {
        GeometryReader { geometry in
            let containerWidth = geometry.size.width - (DS.Dashboard.gridPadding * 2)
            let containerHeight = geometry.size.height - (DS.Dashboard.gridPadding * 2)
            let panels = viewModel.visiblePanels
            let rowHeight = DashboardGridLayout.dynamicRowHeight(
                for: panels,
                containerHeight: containerHeight
            )

            ScrollView(.vertical, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    // Layout anchor
                    Color.clear
                        .frame(
                            width: containerWidth,
                            height: DashboardGridLayout.totalHeight(for: panels, rowHeight: rowHeight)
                        )

                    // Edit mode grid overlay
                    if viewModel.isEditing {
                        DashboardEditOverlay(
                            containerWidth: containerWidth,
                            totalHeight: DashboardGridLayout.totalHeight(
                                for: panels,
                                rowHeight: rowHeight
                            )
                        )
                    }

                    // Panels
                    ForEach(panels) { panel in
                        let frame = DashboardGridLayout.frame(
                            for: panel.gridPosition,
                            in: containerWidth,
                            rowHeight: rowHeight
                        )

                        if panel.panelType == .rowPanel {
                            rowPanelView(panel: panel, containerWidth: containerWidth)
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.origin.x, y: frame.origin.y)
                        } else {
                            panelView(for: panel, containerWidth: containerWidth)
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.origin.x, y: frame.origin.y)
                                .panelDrag(
                                    panelID: panel.id,
                                    containerWidth: containerWidth,
                                    isEditing: viewModel.isEditing,
                                    viewModel: viewModel
                                )
                                .overlay {
                                    if viewModel.isEditing {
                                        PanelResizeHandle(
                                            panelID: panel.id,
                                            panelType: panel.panelType,
                                            containerWidth: containerWidth,
                                            viewModel: viewModel
                                        )
                                    }
                                }
                        }
                    }
                }
                .padding(DS.Dashboard.gridPadding)
            }
        }
    }

    // MARK: - Row Panel View

    private func rowPanelView(panel: PanelConfig, containerWidth: CGFloat) -> some View {
        let isCollapsed = viewModel.collapsedRows.contains(panel.id) || panel.collapsed

        return HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.toggleRowCollapse(panelID: panel.id)
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if viewModel.isEditing {
                TextField(L.tr("행 제목", "Row title"), text: Binding(
                    get: {
                        viewModel.dashboardConfig.panels
                            .first(where: { $0.id == panel.id })?.title ?? panel.title
                    },
                    set: { newTitle in
                        if let idx = viewModel.dashboardConfig.panels.firstIndex(where: { $0.id == panel.id }) {
                            viewModel.dashboardConfig.panels[idx].title = newTitle
                            viewModel.saveDashboard()
                        }
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
            } else {
                Text(panel.title)
                    .font(.system(size: 12, weight: .semibold))
            }

            VStack { Divider() }

            if viewModel.isEditing {
                Button(role: .destructive) {
                    viewModel.removePanel(id: panel.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Panel Dispatch

    @ViewBuilder
    private func panelView(for panel: PanelConfig, containerWidth: CGFloat) -> some View {
        let alertState = viewModel.alertManager.alertState(for: panel.id)

        PanelContainerView(
            title: panel.title,
            isEditing: viewModel.isEditing,
            alertState: alertState,
            dataState: viewModel.dataState(for: panel.id),
            onDelete: { viewModel.removePanel(id: panel.id) },
            onEdit: { onEditPanel?(panel) }
        ) {
            panelContent(for: panel)
        }
    }

    /// Dispatch panel content by type. PanelContainerView handles loading/error states.
    /// Chart panels show "데이터 없음" for empty data. Stat/gauge show "-" or "0" naturally.
    @ViewBuilder
    private func panelContent(for panel: PanelConfig) -> some View {
        let data = viewModel.dataState(for: panel.id).timeSeriesData
        let isEmpty = data == nil || data!.allModelNames.isEmpty
        switch panel.panelType {
        case .stat:
            statContent(for: panel.effectiveMetric, data: data)
        case .timeSeries:
            if isEmpty {
                emptyDataView
            } else if viewModel.filteredModelNames.isEmpty {
                noModelSelected
            } else {
                TimeSeriesChartView(
                    metric: panel.effectiveMetric,
                    viewModel: viewModel,
                    dateFormat: chartDateFormat
                )
            }
        case .barChart:
            if isEmpty {
                emptyDataView
            } else if viewModel.filteredModelNames.isEmpty {
                noModelSelected
            } else {
                barChartContent(for: panel.effectiveMetric, data: data)
            }
        case .pieChart:
            if isEmpty { emptyDataView } else { pieChartContent(for: panel.effectiveMetric, data: data) }
        case .table:
            if isEmpty { emptyDataView } else { tableContent(data: data) }
        case .gauge:
            gaugeContent(for: panel.effectiveMetric, data: data)
        case .rowPanel:
            EmptyView()
        }
    }

    // MARK: - Pure Panel Renderers (data passed in, no global state reads)

    private func statContent(for metric: PanelMetric, data: TimeSeriesData?) -> some View {
        let stat = PanelDataExtractor.statValue(for: metric, data: data)
        return VStack(alignment: .leading, spacing: 4) {
            Text(stat.value)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.5), value: stat.value)
            if let subtitle = stat.subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func barChartContent(for metric: PanelMetric, data: TimeSeriesData?) -> some View {
        let bucketSecs = viewModel.dashboardConfig.time.bucketSeconds
        return Chart {
            ForEach(barModelData, id: \.model) { entry in
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
                AxisValueLabel(format: chartDateFormat)
                    .font(.system(size: 9))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    if barHoverState.date != nil, let plotFrame = proxy.plotFrame {
                        let plotRect = geo[plotFrame]
                        Rectangle()
                            .fill(.secondary.opacity(0.3))
                            .frame(width: 1, height: plotRect.height)
                            .offset(x: barHoverState.position.x, y: plotRect.minY)
                            .allowsHitTesting(false)
                    }

                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                barHoverState.date = snapToNearestBar(at: location, proxy: proxy, geo: geo, modelData: barModelData)
                                barHoverState.position = location
                            case .ended:
                                barHoverState.date = nil
                            }
                        }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            BarChartTooltipOverlay(
                state: barHoverState,
                modelData: barModelData,
                bucketSecs: bucketSecs,
                colorForModel: { viewModel.colorForModel($0) },
                formatDate: { formatBarDate($0) }
            )
        }
        .onAppear { barAnimateIn(metric: metric, data: data) }
        .onChange(of: viewModel.dataVersion) { _, _ in barAnimateIn(metric: metric, data: data) }
        .onChange(of: viewModel.isLoading) { _, loading in
            if loading { barCollapseToZero() }
        }
    }

    private func barAnimateIn(metric: PanelMetric, data: TimeSeriesData?) {
        let real = PanelDataExtractor.allModelChartPoints(
            for: metric,
            enabledModels: viewModel.enabledModels,
            data: data
        )
        barModelData = real.map { entry in
            (model: entry.model, points: entry.points.map {
                TimeSeriesData.ChartPoint(date: $0.date, value: 0)
            })
        }
        withAnimation(.easeOut(duration: 0.3)) {
            barModelData = real
        }
    }

    private func barCollapseToZero() {
        withAnimation(.easeIn(duration: 0.15)) {
            barModelData = barModelData.map { entry in
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

    private func isSameBucket(_ a: Date, _ b: Date, _ bucketSecs: Int) -> Bool {
        if bucketSecs < 3600 {
            return Calendar.current.isDate(a, equalTo: b, toGranularity: .minute)
        } else if bucketSecs < 86400 {
            return Calendar.current.isDate(a, equalTo: b, toGranularity: .hour)
        }
        return Calendar.current.isDate(a, inSameDayAs: b)
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

    @ViewBuilder
    private func tableContent(data: TimeSeriesData?) -> some View {
        let rows = PanelDataExtractor.tableRows(from: data)
        if rows.isEmpty {
            Text("-")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows) {
                TableColumn(L.dash.axisModel, value: \.model)
                TableColumn(L.dash.axisTokens) { row in
                    Text(TokenFormatter.formatTokens(row.tokens))
                        .monospacedDigit()
                }
                TableColumn(L.dash.axisCost) { row in
                    Text(TokenFormatter.formatCost(row.cost))
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private func pieChartContent(for metric: PanelMetric, data: TimeSeriesData?) -> some View {
        if metric == .tokensByProject {
            let projects = PanelDataExtractor.projectBreakdown(from: data)
            if projects.isEmpty {
                Text("-").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PieChartView(
                    entries: projects.map { .init(label: $0.project, value: Double($0.tokens)) },
                    colors: nil
                )
            }
        } else {
            let rows = PanelDataExtractor.tableRows(from: data)
            if rows.isEmpty {
                Text("-").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PieChartView(
                    entries: rows.map { .init(label: $0.model, value: Double($0.tokens)) },
                    colors: rows.map { viewModel.colorForModel($0.model) }
                )
            }
        }
    }

    private func gaugeContent(for metric: PanelMetric, data: TimeSeriesData?) -> some View {
        let stat = PanelDataExtractor.statValue(for: metric, data: data)
        return VStack {
            Text(stat.value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chartDateFormat: Date.FormatStyle {
        let secs = viewModel.dashboardConfig.time.bucketSeconds
        if secs < 3600 {
            return .dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
        } else if secs < 86400 {
            return .dateTime.month(.defaultDigits).day(.defaultDigits).hour(.defaultDigits(amPM: .abbreviated))
        } else {
            return .dateTime.month(.defaultDigits).day(.defaultDigits)
        }
    }

    private var emptyDataView: some View {
        ContentUnavailableView(
            L.tr("데이터 없음", "No Data"),
            systemImage: "chart.line.downtrend.xyaxis",
            description: Text(L.tr("해당 기간에 데이터가 없습니다", "No data for this period"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noModelSelected: some View {
        ContentUnavailableView(
            L.dash.selectModel,
            systemImage: "line.3.horizontal.decrease.circle",
            description: Text(L.dash.selectModelDesc)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        if bucketSecs < 3600 {
            return Calendar.current.isDate(a, equalTo: b, toGranularity: .minute)
        } else if bucketSecs < 86400 {
            return Calendar.current.isDate(a, equalTo: b, toGranularity: .hour)
        }
        return Calendar.current.isDate(a, inSameDayAs: b)
    }
}
