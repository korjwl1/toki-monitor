import SwiftUI

struct ProviderRowView: View {
    let summary: ProviderSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: summary.provider.icon)
                .font(.title3)
                .foregroundStyle(summary.provider.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.provider.name)
                    .font(.headline)
                Text("\(formatTokens(summary.totalInput)) in / \(formatTokens(summary.totalOutput)) out")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let cost = summary.estimatedCost {
                    Text(formatCost(cost))
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                } else {
                    Text("--")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("\(summary.eventCount) calls")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatTokens(_ count: UInt64) -> String {
        if count < 1000 {
            return "\(count)"
        } else if count < 1_000_000 {
            return String(format: "%.1fK", Double(count) / 1000)
        } else {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        } else if cost < 1 {
            return String(format: "$%.3f", cost)
        } else {
            return String(format: "$%.2f", cost)
        }
    }
}
