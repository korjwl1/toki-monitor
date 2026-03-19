import SwiftUI
import Charts

struct ModelDetailView: View {
    let summary: TokiModelSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 8) {
                let provider = ProviderRegistry.resolve(model: summary.model)
                Image(systemName: provider.icon)
                    .font(.title2)
                    .foregroundStyle(provider.color)
                VStack(alignment: .leading) {
                    Text(summary.model)
                        .font(.headline)
                    Text(provider.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Token breakdown chart
            tokenBreakdownChart

            Divider()

            // Stats grid
            statsGrid

            Spacer()
        }
        .padding(16)
    }

    // MARK: - Token Breakdown Chart

    private var tokenBreakdownChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("토큰 분포")
                .font(.subheadline)
                .fontWeight(.medium)

            Chart {
                BarMark(
                    x: .value("Tokens", summary.inputTokens),
                    y: .value("Type", "Input")
                )
                .foregroundStyle(.blue)

                BarMark(
                    x: .value("Tokens", summary.outputTokens),
                    y: .value("Type", "Output")
                )
                .foregroundStyle(.green)

                // Claude Code specific
                if let cache = summary.cacheCreationInputTokens, cache > 0 {
                    BarMark(
                        x: .value("Tokens", cache),
                        y: .value("Type", "Cache Create")
                    )
                    .foregroundStyle(.orange)
                }

                if let cache = summary.cacheReadInputTokens, cache > 0 {
                    BarMark(
                        x: .value("Tokens", cache),
                        y: .value("Type", "Cache Read")
                    )
                    .foregroundStyle(.purple)
                }

                // Codex specific
                if let cached = summary.cachedInputTokens, cached > 0 {
                    BarMark(
                        x: .value("Tokens", cached),
                        y: .value("Type", "Cached Input")
                    )
                    .foregroundStyle(.orange)
                }

                if let reasoning = summary.reasoningOutputTokens, reasoning > 0 {
                    BarMark(
                        x: .value("Tokens", reasoning),
                        y: .value("Type", "Reasoning")
                    )
                    .foregroundStyle(.purple)
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let v = value.as(UInt64.self) {
                            Text(TokenFormatter.formatTokens(v))
                        }
                    }
                }
            }
            .frame(height: 120)
        }
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("상세 정보")
                .font(.subheadline)
                .fontWeight(.medium)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                statRow("Input Tokens", TokenFormatter.formatTokens(summary.inputTokens))
                statRow("Output Tokens", TokenFormatter.formatTokens(summary.outputTokens))
                if let v = summary.cacheCreationInputTokens {
                    statRow("Cache Create", TokenFormatter.formatTokens(v))
                }
                if let v = summary.cacheReadInputTokens {
                    statRow("Cache Read", TokenFormatter.formatTokens(v))
                }
                if let v = summary.cachedInputTokens {
                    statRow("Cached Input", TokenFormatter.formatTokens(v))
                }
                if let v = summary.reasoningOutputTokens {
                    statRow("Reasoning", TokenFormatter.formatTokens(v))
                }
                statRow("Total Tokens", TokenFormatter.formatTokens(summary.totalTokens))
                statRow("API Calls", "\(summary.events)")
                if let cost = summary.costUsd {
                    statRow("추정 비용", TokenFormatter.formatCost(cost))
                }
            }
        }
    }

    @ViewBuilder
    private func statRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .gridColumnAlignment(.trailing)
        }
    }

}
