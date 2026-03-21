import SwiftUI

/// Gauge panel showing a circular ring for percentage-based metrics.
/// Supports cacheHitRate and reasoningTokens metrics.
struct GaugePanelView: View {
    let metric: PanelMetric
    @Bindable var viewModel: DashboardViewModel

    var body: some View {
        if viewModel.timeSeriesData != nil {
            gaugeContent
        } else {
            loadingPlaceholder
        }
    }

    private var gaugeContent: some View {
        VStack(spacing: 8) {
            ZStack {
                // Background ring
                Circle()
                    .stroke(lineWidth: 12)
                    .foregroundStyle(.quaternary)

                // Filled arc
                Circle()
                    .trim(from: 0, to: gaugeValue)
                    .stroke(
                        gaugeColor,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: gaugeValue)

                // Center label
                VStack(spacing: 2) {
                    Text(formattedPercentage)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))

                    Text(metric.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 100, height: 100)
            .padding(8)

            // Subtitle with raw values
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    // MARK: - Computed Values

    private var gaugeValue: CGFloat {
        guard let data = viewModel.timeSeriesData else { return 0 }

        switch metric {
        case .cacheHitRate:
            return CGFloat(computeCacheHitRate(from: data))
        case .reasoningTokens:
            return CGFloat(computeReasoningRatio(from: data))
        default:
            return 0
        }
    }

    private var formattedPercentage: String {
        let pct = gaugeValue * 100
        if pct < 1 && pct > 0 {
            return String(format: "%.1f%%", pct)
        }
        return String(format: "%.0f%%", pct)
    }

    private var subtitle: String {
        guard let data = viewModel.timeSeriesData else { return "-" }

        switch metric {
        case .cacheHitRate:
            let (read, total) = cacheTokenTotals(from: data)
            return "\(TokenFormatter.formatTokens(read)) / \(TokenFormatter.formatTokens(total))"
        case .reasoningTokens:
            let (reasoning, output) = reasoningTokenTotals(from: data)
            return "\(TokenFormatter.formatTokens(reasoning)) / \(TokenFormatter.formatTokens(output))"
        default:
            return "-"
        }
    }

    private var gaugeColor: Color {
        switch metric {
        case .cacheHitRate: .green
        case .reasoningTokens: .purple
        default: .accentColor
        }
    }

    // MARK: - Data Computation

    private func computeCacheHitRate(from data: TimeSeriesData) -> Double {
        let (read, total) = cacheTokenTotals(from: data)
        guard total > 0 else { return 0 }
        return Double(read) / Double(total)
    }

    private func cacheTokenTotals(from data: TimeSeriesData) -> (read: UInt64, total: UInt64) {
        var totalInput: UInt64 = 0
        var cacheRead: UInt64 = 0

        for point in data.points {
            for model in point.models {
                guard viewModel.enabledModels.contains(model.model) else { continue }
                totalInput += model.inputTokens
                // Claude Code uses cacheReadInputTokens, Codex uses cachedInputTokens
                cacheRead += model.cacheReadInputTokens ?? model.cachedInputTokens ?? 0
            }
        }

        return (cacheRead, totalInput)
    }

    private func computeReasoningRatio(from data: TimeSeriesData) -> Double {
        let (reasoning, output) = reasoningTokenTotals(from: data)
        guard output > 0 else { return 0 }
        return Double(reasoning) / Double(output)
    }

    private func reasoningTokenTotals(from data: TimeSeriesData) -> (reasoning: UInt64, output: UInt64) {
        var totalOutput: UInt64 = 0
        var totalReasoning: UInt64 = 0

        for point in data.points {
            for model in point.models {
                guard viewModel.enabledModels.contains(model.model) else { continue }
                totalOutput += model.outputTokens
                totalReasoning += model.reasoningOutputTokens ?? 0
            }
        }

        return (totalReasoning, totalOutput)
    }

    // MARK: - States

    private var loadingPlaceholder: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 150)
    }
}
