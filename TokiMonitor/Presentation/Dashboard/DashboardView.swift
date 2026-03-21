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
        .navigationTitle("대시보드")
        .onAppear { viewModel.fetchData() }
    }

    // MARK: - Toolbar Items

    private var timeRangePicker: some View {
        Picker("기간", selection: $viewModel.selectedTimeRange) {
            ForEach(DashboardTimeRange.allCases) { range in
                Text(range.displayName).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 400)
    }

    private var modelFilterMenu: some View {
        Menu {
            Button("전체 선택") { viewModel.selectAllModels() }
            Button("전체 해제") { viewModel.deselectAllModels() }
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
            Label("필터", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var refreshButton: some View {
        Button(action: { viewModel.fetchData() }) {
            Label("새로고침", systemImage: "arrow.clockwise")
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
                            title: "총 토큰",
                            value: TokenFormatter.formatTokens(viewModel.totalTokens),
                            icon: "number"
                        )
                        StatCard(
                            title: "총 비용",
                            value: TokenFormatter.formatCost(viewModel.totalCost),
                            icon: "dollarsign.circle"
                        )
                        StatCard(
                            title: "API 호출",
                            value: "\(viewModel.totalEvents)",
                            icon: "arrow.up.arrow.down"
                        )
                        StatCard(
                            title: "최다 모델",
                            value: shortModelName(viewModel.topModel ?? "-"),
                            icon: "star"
                        )
                    }
                }

                // Token usage chart (large)
                ChartPanel(title: "토큰 사용량 추이") {
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
                    ChartPanel(title: "비용 추이") {
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

                    ChartPanel(title: "API 호출 추이") {
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
            "모델을 선택하세요",
            systemImage: "line.3.horizontal.decrease.circle",
            description: Text("필터에서 모델을 선택하면 데이터가 표시됩니다")
        )
        .frame(minHeight: 150)
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("오류 발생", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("다시 시도") { viewModel.fetchData() }
                .buttonStyle(.bordered)
        }
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "데이터를 불러오는 중...",
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
