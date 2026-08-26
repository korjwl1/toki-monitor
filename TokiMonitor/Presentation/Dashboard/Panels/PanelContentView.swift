import SwiftUI

/// One panel's drawing, chosen by panel type.
///
/// Lifted out of `CustomDashboardView` so that the dashboard and the panel
/// EDITOR draw a panel the same way. The editor used to render the literal word
/// "미리보기" for six of the eight panel types, and for the seventh — stat — it
/// read `viewModel.timeSeriesData`, a global holding whichever panel happened
/// to load first. So the one place whose entire job is showing the effect of a
/// query change showed either nothing or someone else's data.
///
/// Nothing about the render belongs to either caller: a panel is its config
/// plus its result. Keeping two copies would put the editor back in the
/// position of previewing something the dashboard does not draw.
struct PanelContentView: View {
    let panel: PanelConfig
    let data: TimeSeriesData?
    let frames: FrameSet?
    @Bindable var viewModel: DashboardViewModel
    let dateFormat: Date.FormatStyle

    var body: some View {
        switch panel.panelType {
        case .stat:
            StatPanelView(panel: panel, data: data, frames: frames)
        case .timeSeries:
            TimeSeriesPanelView(panel: panel, data: data, frames: frames,
                                viewModel: viewModel, dateFormat: dateFormat)
        case .barChart:
            BarChartPanelView(panel: panel, data: data, frames: frames,
                              viewModel: viewModel, dateFormat: dateFormat)
        case .pieChart:
            pieChart
        case .table:
            TablePanelView(panel: panel, data: data, frames: frames)
        case .gauge:
            GaugePanelView(panel: panel, data: data, frames: frames)
        case .stateTimeline:
            StateTimelinePanelView(panel: panel, frames: frames, dateFormat: dateFormat)
        case .rowPanel:
            EmptyView()
        case .unknown:
            UnknownPanelView(panel: panel)
        }
    }

    /// Pie has no wrapper view of its own: `PieChartView` under `Panels/` is
    /// already the single render, and this is the slice preparation feeding it.
    @ViewBuilder
    private var pieChart: some View {
        let metric = panel.effectiveMetric
        let slices = PanelSeries.breakdown(metric: metric, panel: panel,
                                           frames: frames, data: data)
        if slices.isEmpty {
            Text("-").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PieChartView(
                entries: slices.map { .init(label: $0.label, value: $0.value) },
                // Projects have no colour of their own; models do, and keeping
                // it means a model is the same colour in every panel.
                colors: metric == .tokensByProject
                    ? nil
                    : slices.map { viewModel.colorForModel($0.label) }
            )
        }
    }
}

/// The axis label format that matches a time range's bucket width. Shared for
/// the same reason as the render: a preview whose axis is formatted
/// differently from the dashboard is showing a different chart.
/// The one fallback used when a series has no field config.
///
/// It exists because there were two. `BarChartPanelView` fell back to
/// `String(Int(value))` / `"%g"` and `TimeSeriesChartView` to
/// `TokenFormatter.formatTokens`, from functions with the same name, the same
/// signature and the same doc comment — so the same series read `1500000` in a
/// bar tooltip and `1.5M` in a line tooltip on the same dashboard. Neither was
/// wrong on its own; having both was.
///
/// Whole numbers abbreviate (they are token counts in every stock panel);
/// anything with a fraction is a cost or a ratio and keeps its decimals,
/// which `formatTokens` would have truncated away.
enum PanelValueFormat {
    static func fallback(_ value: Double) -> String {
        guard value == value.rounded(), value.magnitude < 1e18 else {
            return String(format: "%g", value)
        }
        if value < 0 { return String(Int(value)) }
        return TokenFormatter.formatTokens(UInt64(value))
    }
}

enum PanelDateFormat {
    static func forBucket(seconds: Int) -> Date.FormatStyle {
        if seconds < 3600 {
            return .dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
        } else if seconds < 86400 {
            return .dateTime.month(.defaultDigits).day(.defaultDigits)
                .hour(.defaultDigits(amPM: .abbreviated))
        } else {
            return .dateTime.month(.defaultDigits).day(.defaultDigits)
        }
    }
}
