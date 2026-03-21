import SwiftUI

/// Renders a stat panel for the customizable dashboard.
/// Displays a large number with an icon label, matching StatCard styling.
struct StatPanelView: View {
    let metric: PanelMetric
    @Bindable var viewModel: DashboardViewModel

    var body: some View {
        GroupBox {
            Text(formattedValue)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(metric.displayName, systemImage: metric.icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var formattedValue: String {
        guard viewModel.timeSeriesData != nil else {
            return "-"
        }

        switch metric {
        case .totalTokens:
            return TokenFormatter.formatTokens(viewModel.totalTokens)
        case .totalCost:
            return TokenFormatter.formatCost(viewModel.totalCost)
        case .apiCalls:
            return "\(viewModel.totalEvents)"
        case .topModel:
            return shortModelName(viewModel.topModel ?? "-")
        default:
            return "-"
        }
    }

    private func shortModelName(_ model: String) -> String {
        if model.count > 15 {
            return String(model.prefix(15)) + "…"
        }
        return model
    }
}
