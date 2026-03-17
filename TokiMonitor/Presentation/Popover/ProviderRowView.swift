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
                Text("\(TokenFormatter.formatTokens(summary.totalInput)) in / \(TokenFormatter.formatTokens(summary.totalOutput)) out")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let cost = summary.estimatedCost {
                    Text(TokenFormatter.formatCost(cost))
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
}
