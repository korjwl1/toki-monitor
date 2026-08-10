import SwiftUI
import Charts

/// Responsive dashboard grid view.
/// Fills the available window space — panels resize dynamically with the window.
struct CustomDashboardView: View {
    @Bindable var viewModel: DashboardViewModel
    var onEditPanel: ((PanelConfig) -> Void)?
    var onInspectPanel: ((PanelConfig) -> Void)?

    @State private var barHoverState = BarHoverState()
    @State private var barModelData: [(model: String, points: [TimeSeriesData.ChartPoint])] = []
    @State private var barAnimated = false


    var body: some View {
        GeometryReader { geometry in
            let containerWidth = geometry.size.width - (DS.Dashboard.gridPadding * 2)
            let containerHeight = geometry.size.height - (DS.Dashboard.gridPadding * 2)
            let panels = viewModel.visiblePanels
            // Adaptive row height: fills the viewport when the grid fits
            // (preserves the default dashboard's spacious layout) but pins
            // at `defaultRowHeight` once panels exceed the viewport, at
            // which point the surrounding ScrollView takes over.
            let rowHeight = DashboardGridLayout.adaptiveRowHeight(
                for: panels,
                containerHeight: containerHeight
            )

            // Precompute each panel's grid frame so `DashboardCustomLayout`
            // (and the edit-mode overlay) share a single source of truth.
            let framesByID: [UUID: CGRect] = Dictionary(
                uniqueKeysWithValues: panels.map { panel in
                    (
                        panel.id,
                        DashboardGridLayout.frame(
                            for: panel.gridPosition,
                            in: containerWidth,
                            rowHeight: rowHeight
                        )
                    )
                }
            )
            let totalHeight = DashboardGridLayout.totalHeight(for: panels, rowHeight: rowHeight)

            ScrollView(.vertical, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    // Edit mode grid overlay (background grid lines)
                    if viewModel.isEditing {
                        DashboardEditOverlay(
                            containerWidth: containerWidth,
                            totalHeight: totalHeight
                        )
                    }

                    // Panels placed by `DashboardCustomLayout` via `Layout`
                    // protocol. Each subview's outer frame matches its grid
                    // cell exactly — no `.offset` / `.position` workarounds,
                    // so gesture hit-test stays bounded to the right panel.
                    DashboardCustomLayout(frames: framesByID) {
                        ForEach(panels) { panel in
                            Group {
                                if panel.panelType == .rowPanel {
                                    rowPanelView(panel: panel, containerWidth: containerWidth)
                                } else {
                                    panelView(for: panel, containerWidth: containerWidth)
                                        .panelDrag(
                                            panelID: panel.id,
                                            containerWidth: containerWidth,
                                            rowHeight: rowHeight,
                                            isEditing: viewModel.isEditing,
                                            viewModel: viewModel
                                        )
                                        .panelEdgeResize(
                                            panelID: panel.id,
                                            panelType: panel.panelType,
                                            containerWidth: containerWidth,
                                            rowHeight: rowHeight,
                                            isEditing: viewModel.isEditing,
                                            viewModel: viewModel
                                        )
                                }
                            }
                            .panelID(panel.id)
                        }
                    }
                    .frame(width: containerWidth, height: totalHeight, alignment: .topLeading)
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
        PanelContainerView(
            title: panel.title,
            isEditing: viewModel.isEditing,
            dataState: viewModel.dataState(for: panel.id),
            onDelete: { viewModel.removePanel(id: panel.id) },
            onEdit: { onEditPanel?(panel) },
            onInspect: onInspectPanel.map { handler in { handler(panel) } }
        ) {
            panelContent(for: panel)
        }
    }

    /// Dispatch panel content by type. PanelContainerView handles loading/error states.
    /// Chart panels show "데이터 없음" for empty data. Stat/gauge show "-" or "0" naturally.
    @ViewBuilder
    private func panelContent(for panel: PanelConfig) -> some View {
        let state = viewModel.dataState(for: panel.id)
        let data = state.timeSeriesData
        let frames = state.frames
        // A datasource that serves frames and no legacy points is not empty.
        let isEmpty = (data?.allModelNames.isEmpty ?? true) && (frames?.frames.isEmpty ?? true)
        switch panel.panelType {
        case .stat:
            statContent(for: panel, data: data, frames: frames)
        case .timeSeries:
            if isEmpty {
                Spacer()
            } else if viewModel.filteredModelNames.isEmpty {
                noModelSelected
            } else {
                TimeSeriesChartView(
                    metric: panel.effectiveMetric,
                    data: data,
                    frames: frames,
                    panel: panel,
                    viewModel: viewModel,
                    dateFormat: chartDateFormat
                )
            }
        case .barChart:
            if isEmpty {
                Spacer()
            } else if viewModel.filteredModelNames.isEmpty {
                noModelSelected
            } else {
                barChartContent(for: panel, data: data, frames: frames)
            }
        case .pieChart:
            if isEmpty { Spacer() } else { pieChartContent(for: panel, data: data, frames: frames) }
        case .table:
            if isEmpty { Spacer() } else { tableContent(data: data, frames: frames) }
        case .gauge:
            gaugeContent(for: panel, data: data, frames: frames)
        case .rowPanel:
            EmptyView()
        }
    }

    // MARK: - Pure Panel Renderers (data passed in, no global state reads)

    /// Field-driven when frames are available, with the legacy extractor as a
    /// fallback for sources that do not produce them yet.
    ///
    /// The value no longer comes from a switch on the metric: the preset says
    /// which FIELD to read and how to reduce it, so a panel pointed at a column
    /// no enum case knows about renders through this same path.
    private func statContent(for panel: PanelConfig, data: TimeSeriesData?,
                             frames: FrameSet?) -> some View {
        let stat = Self.statValue(panel: panel, data: data, frames: frames)
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

    /// Resolve a stat card's number. Frames first; the legacy extractor only
    /// when a datasource has not been migrated.
    static func statValue(panel: PanelConfig, data: TimeSeriesData?,
                          frames: FrameSet?) -> PanelDataExtractor.StatValue {
        let metric = panel.effectiveMetric
        guard let frames, !frames.frames.isEmpty else {
            return PanelDataExtractor.statValue(for: metric, data: data)
        }
        // `topModel` names a series rather than reducing a column.
        if metric == .topModel {
            let name = FrameReader.topSeries(
                frames, selection: PanelPreset.selection(for: metric), labelKey: "model"
            )
            return PanelDataExtractor.StatValue(value: name ?? "-", subtitle: nil)
        }
        let prepared = TransformationPipeline.apply(
            PanelPreset.transformations(for: metric), to: frames
        )
        // The panel's own selection wins; the preset is the starting point a
        // panel keeps until someone changes it.
        let selection = panel.fieldSelection ?? PanelPreset.selection(for: metric)
        guard let value = FrameReader.singleValue(prepared, selection: selection) else {
            // Absent stays "-", never 0 — see FrameReader.singleValue.
            return PanelDataExtractor.StatValue(value: "-", subtitle: nil)
        }
        // Formatting comes from the field's resolved config when the panel has
        // one, so a card can read "$" while its neighbour reads tokens.
        if let config = panel.fieldConfig,
           let field = prepared.frames.compactMap({ selection.resolve(in: $0) }).first {
            let resolved = config.resolve(for: field)
            if !resolved.isEmpty {
                return PanelDataExtractor.StatValue(
                    value: FieldFormatter.format(value, config: resolved), subtitle: nil
                )
            }
        }
        return PanelDataExtractor.StatValue(
            value: Self.format(value, metric: metric), subtitle: nil
        )
    }

    static func format(_ value: Double, metric: PanelMetric) -> String {
        switch metric {
        case .totalCost, .costByModel:
            return TokenFormatter.formatCost(value)
        case .apiCalls, .eventsByModel:
            return String(Int(value))
        case .cacheHitRate:
            return String(format: "%.1f%%", value * 100)
        default:
            return TokenFormatter.formatTokens(UInt64(max(0, value)))
        }
    }

    @ViewBuilder
    private func barChartContent(for panel: PanelConfig, data: TimeSeriesData?,
                                 frames: FrameSet?) -> some View {
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
        .onAppear { barAnimateIn(panel: panel, data: data, frames: frames) }
        .onChange(of: viewModel.dataVersion) { _, _ in
            barAnimateIn(panel: panel, data: data, frames: frames)
        }
        .onChange(of: viewModel.isLoading) { _, loading in
            if loading { barCollapseToZero() }
        }
    }

    private func barAnimateIn(panel: PanelConfig, data: TimeSeriesData?, frames: FrameSet?) {
        let real = PanelSeries.chartPoints(
            metric: panel.effectiveMetric, panel: panel, frames: frames,
            data: data, enabled: viewModel.enabledModels
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
        BarChartTime.isSameBucket(a, b, bucketSecs: bucketSecs)
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
    private func tableContent(data: TimeSeriesData?, frames: FrameSet?) -> some View {
        let rows = PanelSeries.rows(frames: frames, data: data)
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
    private func pieChartContent(for panel: PanelConfig, data: TimeSeriesData?,
                                 frames: FrameSet?) -> some View {
        let metric = panel.effectiveMetric
        let slices = PanelSeries.breakdown(metric: metric, panel: panel,
                                           frames: frames, data: data)
        if slices.isEmpty {
            Text("-").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PieChartView(
                entries: slices.map { .init(label: $0.label, value: $0.value) },
                // Projects have no colour of their own; models do, and keeping
                // it means a model is the same colour in every panel.
                colors: metric == .tokensByProject
                    ? nil
                    : slices.map { viewModel.colorForModel($0.label) }
            )
        }
    }

    private func gaugeContent(for panel: PanelConfig, data: TimeSeriesData?,
                              frames: FrameSet?) -> some View {
        let stat = Self.statValue(panel: panel, data: data, frames: frames)
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
