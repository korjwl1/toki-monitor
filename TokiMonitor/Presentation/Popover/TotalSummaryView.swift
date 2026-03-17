import SwiftUI

struct TotalSummaryView: View {
    let total: TotalSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sum")
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("전체")
                    .font(.headline)
                Text("\(total.providerCount) providers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let cost = total.estimatedCost {
                    Text(TokenFormatter.formatCost(cost))
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                } else {
                    Text("--")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("\(total.eventCount) calls")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
