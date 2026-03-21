import SwiftUI
import Charts

struct DashboardView: View {
    @State private var viewModel: DashboardViewModel

    init(reportClient: TokiReportClient) {
        _viewModel = State(initialValue: DashboardViewModel(reportClient: reportClient))
    }

    var body: some View {
        VStack(spacing: 0) {
            DashboardToolbar(viewModel: viewModel)
            Divider()

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
        .onAppear { viewModel.fetchData() }
    }

    // MARK: - Dashboard Content

    private func dashboardContent(_ data: TimeSeriesData) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                // Summary stat cards
                HStack(spacing: 10) {
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
                HStack(spacing: 10) {
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
            .padding(16)
        }
    }

    // MARK: - States

    private var noModelSelected: some View {
        Text("모델을 선택하세요")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 150)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("다시 시도") { viewModel.fetchData() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("데이터를 불러오는 중...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shorten model name for stat card display
    private func shortModelName(_ model: String) -> String {
        if model.count > 15 {
            return String(model.prefix(15)) + "…"
        }
        return model
    }
}
