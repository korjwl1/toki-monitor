import SwiftUI

struct DashboardView: View {
    let reportClient: TokiReportClient

    @State private var selectedPeriod: ReportPeriod = .daily
    @State private var summaries: [TokiModelSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedModel: TokiModelSummary?

    var body: some View {
        HSplitView {
            // Left: report list
            VStack(alignment: .leading, spacing: 0) {
                periodPicker
                Divider()

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    errorView(error)
                } else if summaries.isEmpty {
                    emptyView
                } else {
                    reportTable
                }
            }
            .frame(minWidth: 350)

            // Right: detail view
            if let model = selectedModel {
                ModelDetailView(summary: model)
                    .frame(minWidth: 250)
            } else {
                placeholderDetail
            }
        }
        .onAppear { fetchReport() }
    }

    // MARK: - Period Picker

    private var periodPicker: some View {
        HStack {
            Text("기간")
                .font(.headline)
            Picker("", selection: $selectedPeriod) {
                ForEach(ReportPeriod.allCases, id: \.self) { period in
                    Text(period.displayName).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .onChange(of: selectedPeriod) { _, _ in fetchReport() }

            Spacer()

            Button(action: fetchReport) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("새로고침")
        }
        .padding(12)
    }

    // MARK: - Report Table

    private var reportTable: some View {
        Table(summaries, selection: Binding(
            get: { selectedModel?.model },
            set: { id in selectedModel = summaries.first { $0.model == id } }
        )) {
            TableColumn("모델") { summary in
                HStack(spacing: 6) {
                    let provider = ProviderRegistry.resolve(model: summary.model)
                    Image(systemName: provider.icon)
                        .foregroundStyle(provider.color)
                    Text(summary.model)
                        .lineLimit(1)
                }
            }
            .width(min: 120, ideal: 180)

            TableColumn("Input") { summary in
                Text(TokenFormatter.formatTokens(summary.inputTokens))
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 60, ideal: 80)

            TableColumn("Output") { summary in
                Text(TokenFormatter.formatTokens(summary.outputTokens))
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 60, ideal: 80)

            TableColumn("호출") { summary in
                Text("\(summary.events)")
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 40, ideal: 50)

            TableColumn("비용") { summary in
                if let cost = summary.costUsd {
                    Text(TokenFormatter.formatCost(cost))
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text("--")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 80)
        }
    }

    // MARK: - States

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("다시 시도", action: fetchReport)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("해당 기간에 데이터가 없습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderDetail: some View {
        VStack {
            Image(systemName: "sidebar.right")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("모델을 선택하면 상세 정보가 표시됩니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func fetchReport() {
        isLoading = true
        errorMessage = nil

        reportClient.queryAllSummaries(period: selectedPeriod) { result in
            Task { @MainActor in
                isLoading = false
                switch result {
                case .success(let data):
                    summaries = data.sorted { ($0.costUsd ?? 0) > ($1.costUsd ?? 0) }
                    selectedModel = nil
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

}

// MARK: - ReportPeriod

enum ReportPeriod: String, CaseIterable {
    case daily, weekly, monthly

    var displayName: String {
        switch self {
        case .daily: "일간"
        case .weekly: "주간"
        case .monthly: "월간"
        }
    }

    var subcommand: String {
        switch self {
        case .daily: "daily"
        case .weekly: "weekly"
        case .monthly: "monthly"
        }
    }

    var sinceDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let date: Date
        switch self {
        case .daily:
            date = Date()
        case .weekly:
            date = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        case .monthly:
            date = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        }
        return formatter.string(from: date)
    }
}
