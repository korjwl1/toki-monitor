import SwiftUI
import Charts

/// Explore mode: free-form PromQL query input with live results.
struct ExploreView: View {
    @Bindable var viewModel: DashboardViewModel
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            DetailHeaderView(title: L.dash.explore, icon: "magnifyingglass.circle")

            // Query input
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                TextField("PromQL", text: $viewModel.exploreQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit {
                        viewModel.runExploreQuery()
                    }

                Button {
                    showHistory.toggle()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showHistory) {
                    queryHistoryPopover
                }

                Button(L.dash.runQuery) {
                    viewModel.runExploreQuery()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.exploreQuery.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Results
            if viewModel.isExploreLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let data = viewModel.exploreResults {
                HSplitView {
                    // Chart
                    exploreChart(data: data)
                        .frame(minHeight: 200)

                    // Table
                    exploreTable(data: data)
                        .frame(minHeight: 200)
                }
                .padding(16)
            } else {
                ContentUnavailableView(
                    L.tr("쿼리를 입력하세요", "Enter a query"),
                    systemImage: "terminal",
                    description: Text(L.tr("PromQL 쿼리를 입력하고 실행하면 결과가 표시됩니다", "Enter a PromQL query and run it to see results"))
                )
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Query History

    private var queryHistoryPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.dash.queryHistory)
                    .font(.subheadline.bold())
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if viewModel.exploreQueryHistory.isEmpty {
                Text(L.tr("기록 없음", "No history"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                List(viewModel.exploreQueryHistory) { entry in
                    Button {
                        viewModel.exploreQuery = entry.query
                        showHistory = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.query)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                            Text(entry.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 320, height: 280)
    }

    // MARK: - Chart

    @ViewBuilder
    private func exploreChart(data: TimeSeriesData) -> some View {
        let modelNames = data.allModelNames
        if modelNames.isEmpty {
            Text(L.tr("데이터 없음", "No data"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(modelNames, id: \.self) { model in
                    let points = data.tokensFor(model: model)
                    ForEach(points) { point in
                        LineMark(
                            x: .value(L.dash.axisTime, point.date),
                            y: .value(L.dash.axisTokens, point.value)
                        )
                        .foregroundStyle(by: .value(L.dash.axisModel, model))
                    }
                }
            }
        }
    }

    // MARK: - Table

    @ViewBuilder
    private func exploreTable(data: TimeSeriesData) -> some View {
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
                }
                TableColumn(L.dash.axisCost) { row in
                    Text(TokenFormatter.formatCost(row.cost))
                }
            }
        }
    }
}
