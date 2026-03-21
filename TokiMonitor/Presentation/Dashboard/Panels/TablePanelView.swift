import SwiftUI

/// Table panel showing per-model breakdown with columns for tokens, cost, and events.
/// Aggregates data from TimeSeriesData across all time points.
struct TablePanelView: View {
    @Bindable var viewModel: DashboardViewModel

    var body: some View {
        if let data = viewModel.timeSeriesData {
            let rows = aggregateModels(from: data)
            if rows.isEmpty {
                emptyState
            } else {
                tableContent(rows)
            }
        } else {
            loadingPlaceholder
        }
    }

    private func tableContent(_ rows: [ModelRow]) -> some View {
        Table(rows) {
            TableColumn(L.dash.axisModel) { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.colorForModel(row.model))
                        .frame(width: 8, height: 8)
                    Text(row.model)
                        .lineLimit(1)
                }
            }
            .width(min: 120, ideal: 180)

            TableColumn(L.dash.inputTokens) { row in
                Text(TokenFormatter.formatTokens(row.inputTokens))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn(L.dash.outputTokens) { row in
                Text(TokenFormatter.formatTokens(row.outputTokens))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn(L.dash.totalTokens) { row in
                Text(TokenFormatter.formatTokens(row.totalTokens))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn(L.dash.axisCost) { row in
                Text(TokenFormatter.formatCost(row.cost))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)

            TableColumn(L.dash.axisCalls) { row in
                Text("\(row.events)")
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70)
        }
        .frame(minHeight: 150)
    }

    // MARK: - Data Aggregation

    private func aggregateModels(from data: TimeSeriesData) -> [ModelRow] {
        var aggregate: [String: ModelRow] = [:]

        for point in data.points {
            for model in point.models {
                var row = aggregate[model.model] ?? ModelRow(model: model.model)
                row.inputTokens += model.inputTokens
                row.outputTokens += model.outputTokens
                row.totalTokens += model.totalTokens
                row.cost += model.costUsd ?? 0
                row.events += model.events
                aggregate[model.model] = row
            }
        }

        return aggregate.values
            .filter { viewModel.enabledModels.contains($0.model) }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    // MARK: - States

    private var emptyState: some View {
        ContentUnavailableView(
            L.dash.selectModel,
            systemImage: "tablecells",
            description: Text(L.dash.selectModelDesc)
        )
        .frame(minHeight: 150)
    }

    private var loadingPlaceholder: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 150)
    }
}

// MARK: - Model

struct ModelRow: Identifiable {
    let model: String
    var inputTokens: UInt64 = 0
    var outputTokens: UInt64 = 0
    var totalTokens: UInt64 = 0
    var cost: Double = 0
    var events: Int = 0

    var id: String { model }
}
