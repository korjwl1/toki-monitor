import SwiftUI
import Charts

struct DashboardView: View {
    @State private var viewModel: DashboardViewModel

    init(reportClient: TokiReportClient) {
        _viewModel = State(initialValue: DashboardViewModel(reportClient: reportClient))
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.timeSeriesData == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if let data = viewModel.timeSeriesData {
                dashboardContent(data)
            } else {
                emptyView
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                timeRangePicker
                Spacer()
                modelFilterMenu
                refreshButton
            }
        }
        .navigationTitle(L.dash.title)
        .onAppear { viewModel.fetchData() }
    }

    // MARK: - Toolbar Items

    private var timeRangePicker: some View {
        Picker(L.dash.period, selection: $viewModel.selectedTimeRange) {
            ForEach(DashboardTimeRange.allCases) { range in
                Text(range.displayName).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 400)
    }

    private var modelFilterMenu: some View {
        Menu {
            Button(L.dash.selectAll) { viewModel.selectAllModels() }
            Button(L.dash.deselectAll) { viewModel.deselectAllModels() }
            Divider()
            if let data = viewModel.timeSeriesData {
                ForEach(data.allModelNames, id: \.self) { model in
                    Toggle(model, isOn: Binding(
                        get: { viewModel.enabledModels.contains(model) },
                        set: { _ in viewModel.toggleModel(model) }
                    ))
                }
            }
        } label: {
            Label(L.dash.filter, systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var refreshButton: some View {
        Button(action: { viewModel.fetchData() }) {
            Label(L.dash.refresh, systemImage: "arrow.clockwise")
        }
        .disabled(viewModel.isLoading)
    }

    // MARK: - Dashboard Content

    private func dashboardContent(_ data: TimeSeriesData) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Summary stat cards
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        StatCard(
                            title: L.dash.totalTokens,
                            value: TokenFormatter.formatTokens(viewModel.totalTokens),
                            icon: "number"
                        )
                        StatCard(
                            title: L.dash.totalCost,
                            value: TokenFormatter.formatCost(viewModel.totalCost),
                            icon: "dollarsign.circle"
                        )
                        StatCard(
                            title: L.dash.apiCalls,
                            value: "\(viewModel.totalEvents)",
                            icon: "arrow.up.arrow.down"
                        )
                        StatCard(
                            title: L.dash.topModel,
                            value: shortModelName(viewModel.topModel ?? "-"),
                            icon: "star"
                        )
                    }
                }

                // Token usage chart (large)
                ChartPanel(title: L.dash.tokenTrend) {
                    if viewModel.filteredModelNames.isEmpty {
                        noModelSelected
                    } else {
                        TokenUsageChart(
                            data: data,
                            enabledModels: viewModel.filteredModelNames,
                            colorForModel: viewModel.colorForModel
                        )
                    }
                }

                // Cost + Events side by side
                HStack(spacing: 12) {
                    ChartPanel(title: L.dash.costTrend) {
                        if viewModel.filteredModelNames.isEmpty {
                            noModelSelected
                        } else {
                            CostChart(
                                data: data,
                                enabledModels: viewModel.filteredModelNames,
                                colorForModel: viewModel.colorForModel
                            )
                        }
                    }

                    ChartPanel(title: L.dash.apiTrend) {
                        if viewModel.filteredModelNames.isEmpty {
                            noModelSelected
                        } else {
                            EventsChart(
                                data: data,
                                enabledModels: viewModel.filteredModelNames,
                                colorForModel: viewModel.colorForModel
                            )
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - States

    private var noModelSelected: some View {
        ContentUnavailableView(
            L.dash.selectModel,
            systemImage: "line.3.horizontal.decrease.circle",
            description: Text(L.dash.selectModelDesc)
        )
        .frame(minHeight: 150)
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label(L.dash.error, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(L.account.retry) { viewModel.fetchData() }
                .buttonStyle(.bordered)
        }
    }

    private var emptyView: some View {
        ContentUnavailableView(
            L.dash.loading,
            systemImage: "chart.xyaxis.line"
        )
    }

    private func shortModelName(_ model: String) -> String {
        if model.count > 15 {
            return String(model.prefix(15)) + "…"
        }
        return model
    }
}
