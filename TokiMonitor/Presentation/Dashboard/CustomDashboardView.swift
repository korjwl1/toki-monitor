import SwiftUI
import Charts

/// Main customizable dashboard grid view.
/// Positions panels absolutely using DashboardGridLayout within a scrollable ZStack.
struct CustomDashboardView: View {
    @Bindable var viewModel: DashboardViewModel

    var body: some View {
        GeometryReader { geometry in
            let containerWidth = geometry.size.width - 40 // 20pt padding on each side

            ScrollView {
                ZStack(alignment: .topLeading) {
                    // Edit mode grid overlay (behind panels)
                    if viewModel.isEditing {
                        DashboardEditOverlay(
                            containerWidth: containerWidth,
                            totalHeight: gridTotalHeight(containerWidth)
                        )
                    }

                    // Panels
                    ForEach(viewModel.dashboardConfig.panels) { panel in
                        panelView(for: panel, containerWidth: containerWidth)
                            .frame(
                                width: DashboardGridLayout.frame(for: panel.gridPosition, in: containerWidth).width,
                                height: DashboardGridLayout.frame(for: panel.gridPosition, in: containerWidth).height
                            )
                            .offset(
                                x: DashboardGridLayout.frame(for: panel.gridPosition, in: containerWidth).origin.x,
                                y: DashboardGridLayout.frame(for: panel.gridPosition, in: containerWidth).origin.y
                            )
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
                .frame(
                    width: containerWidth,
                    height: gridTotalHeight(containerWidth)
                )
                .padding(20)
            }
        }
    }

    // MARK: - Grid Height

    private func gridTotalHeight(_ containerWidth: CGFloat) -> CGFloat {
        let height = DashboardGridLayout.totalHeight(for: viewModel.dashboardConfig.panels)
        // Add extra row in edit mode for drop targets
        return viewModel.isEditing ? height + DashboardGridLayout.rowHeight + DashboardGridLayout.gap : height
    }

    // MARK: - Panel Dispatch

    @ViewBuilder
    private func panelView(for panel: PanelConfig, containerWidth: CGFloat) -> some View {
        PanelContainerView(
            title: panel.title,
            isEditing: viewModel.isEditing,
            onDelete: { viewModel.removePanel(id: panel.id) }
        ) {
            panelContent(for: panel)
        }
    }

    @ViewBuilder
    private func panelContent(for panel: PanelConfig) -> some View {
        switch panel.panelType {
        case .stat:
            statContent(for: panel.metric)
        case .timeSeries:
            timeSeriesContent(for: panel.metric)
        case .barChart:
            barChartContent(for: panel.metric)
        case .table:
            tableContent(for: panel.metric)
        case .gauge:
            gaugeContent(for: panel.metric)
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
