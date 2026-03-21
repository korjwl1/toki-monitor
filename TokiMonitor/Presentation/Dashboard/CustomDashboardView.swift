import SwiftUI
import Charts

/// Responsive dashboard grid view.
/// Fills the available window space — panels resize dynamically with the window.
struct CustomDashboardView: View {
    @Bindable var viewModel: DashboardViewModel
    var onEditPanel: ((PanelConfig) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let containerWidth = geometry.size.width - 32  // 16pt padding each side
            let containerHeight = geometry.size.height - 32
            let rowHeight = DashboardGridLayout.dynamicRowHeight(
                for: viewModel.dashboardConfig.panels,
                containerHeight: containerHeight
            )

            ZStack(alignment: .topLeading) {
                // Layout anchor
                Color.clear

                // Edit mode grid overlay
                if viewModel.isEditing {
                    DashboardEditOverlay(
                        containerWidth: containerWidth,
                        totalHeight: DashboardGridLayout.totalHeight(
                            for: viewModel.dashboardConfig.panels,
                            rowHeight: rowHeight
                        )
                    )
                }

                // Panels
                ForEach(viewModel.dashboardConfig.panels) { panel in
                    let frame = DashboardGridLayout.frame(
                        for: panel.gridPosition,
                        in: containerWidth,
                        rowHeight: rowHeight
                    )
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
            .frame(width: containerWidth, height: containerHeight)
            .padding(16)
        }
    }

    // MARK: - Panel Dispatch

    @ViewBuilder
    private func panelView(for panel: PanelConfig, containerWidth: CGFloat) -> some View {
        PanelContainerView(
            title: panel.title,
            isEditing: viewModel.isEditing,
            onDelete: { viewModel.removePanel(id: panel.id) },
            onEdit: { onEditPanel?(panel) }
        ) {
            panelContent(for: panel)
        }
    }

    @ViewBuilder
    private func panelContent(for panel: PanelConfig) -> some View {
        switch panel.panelType {
        case .stat:
            statContent(for: panel.effectiveMetric)
        case .timeSeries:
            timeSeriesContent(for: panel.effectiveMetric)
        case .barChart:
            barChartContent(for: panel.effectiveMetric)
        case .table:
            tableContent(for: panel.effectiveMetric)
        case .gauge:
            gaugeContent(for: panel.effectiveMetric)
        }
    }

    // MARK: - Panel Content Renderers

    @ViewBuilder
    private func statContent(for metric: PanelMetric) -> some View {
        let stat = PanelDataExtractor.statValue(
            for: metric,
            timeSeriesData: viewModel.timeSeriesData,
            viewModel: viewModel
        )
        VStack(alignment: .leading, spacing: 4) {
            Text(stat.value)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let subtitle = stat.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func timeSeriesContent(for metric: PanelMetric) -> some View {
        if viewModel.filteredModelNames.isEmpty {
            noModelSelected
        } else {
            let modelData = PanelDataExtractor.allModelChartPoints(
                for: metric,
                viewModel: viewModel,
                timeSeriesData: viewModel.timeSeriesData
            )
            Chart {
                ForEach(modelData, id: \.model) { entry in
                    ForEach(entry.points) { point in
                        LineMark(
                            x: .value(L.dash.axisTime, point.date),
                            y: .value(L.dash.axisTokens, point.value)
                        )
                        .foregroundStyle(by: .value(L.dash.axisModel, entry.model))
                    }
                }
            }
            .chartForegroundStyleScale { (model: String) in
                viewModel.colorForModel(model)
            }
        }
    }

    @ViewBuilder
    private func barChartContent(for metric: PanelMetric) -> some View {
        if viewModel.filteredModelNames.isEmpty {
            noModelSelected
        } else {
            let modelData = PanelDataExtractor.allModelChartPoints(
                for: metric,
                viewModel: viewModel,
                timeSeriesData: viewModel.timeSeriesData
            )
            Chart {
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
        }
    }

    @ViewBuilder
    private func tableContent(for metric: PanelMetric) -> some View {
        let rows = PanelDataExtractor.tableRows(from: viewModel.timeSeriesData)
        if rows.isEmpty {
            Text("-")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows) {
                TableColumn(L.dash.axisModel, value: \.model)
                TableColumn(L.dash.axisTokens) { row in
                    Text(TokenFormatter.formatTokens(row.tokens))
                }
                TableColumn(L.dash.axisCost) { row in
                    Text(TokenFormatter.formatCost(row.cost))
                }
            }
        }
    }

    @ViewBuilder
    private func gaugeContent(for metric: PanelMetric) -> some View {
        let stat = PanelDataExtractor.statValue(
            for: metric,
            timeSeriesData: viewModel.timeSeriesData,
            viewModel: viewModel
        )
        VStack {
            Text(stat.value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noModelSelected: some View {
        ContentUnavailableView(
            L.dash.selectModel,
            systemImage: "line.3.horizontal.decrease.circle",
            description: Text(L.dash.selectModelDesc)
        )
        .frame(minHeight: 80)
    }
}
