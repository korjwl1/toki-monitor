import SwiftUI

struct PopoverContentView: View {
    let summaries: [ProviderSummary]
    let total: TotalSummary?
    let timeRange: TimeRange
    let tokensPerMinute: Double
    let onTimeRangeChange: (TimeRange) -> Void
    let onDashboardTap: () -> Void
    let onSettingsTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with rate
            header
            Divider()

            if summaries.isEmpty {
                emptyState
            } else {
                // Total row (if 2+ providers)
                if let total {
                    TotalSummaryView(total: total)
                        .padding(.horizontal, 12)
                    Divider()
                }

                // Provider rows
                ForEach(summaries) { summary in
                    ProviderRowView(summary: summary)
                        .padding(.horizontal, 12)
                }
            }

            Divider()

            // Footer: time range + buttons
            footer
        }
        .frame(width: 300)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Toki Monitor")
                    .font(.headline)
                Text(TokenAggregator.formatRate(tokensPerMinute))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.green)
            Text("연결됨")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("아직 토큰 이벤트가 없습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("AI 도구를 사용하면 여기에 표시됩니다")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // Time range picker
            Picker("", selection: Binding(
                get: { timeRange },
                set: { onTimeRangeChange($0) }
            )) {
                ForEach(TimeRange.allCases, id: \.self) { range in
                    Text(range.displayName).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            Spacer()

            Button(action: onDashboardTap) {
                Image(systemName: "chart.bar.xaxis")
            }
            .buttonStyle(.borderless)
            .help("대시보드")

            Button(action: onSettingsTap) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("설정")
        }
        .padding(10)
    }
}
