import SwiftUI

/// Time series panel render.
///
/// `TimeSeriesChartView` already held the chart itself; what lived inline in
/// `CustomDashboardView` was the argument wiring around it. That wiring moves
/// here so the dispatch in `CustomDashboardView` names one view per panel type
/// (contract R2). What this file used to contain — an area/line chart reading
/// `viewModel.timeSeriesData` directly — was never instantiated.
struct TimeSeriesPanelView: View {
    let panel: PanelConfig
    let data: TimeSeriesData?
    let frames: FrameSet?
    @Bindable var viewModel: DashboardViewModel
    let dateFormat: Date.FormatStyle

    var body: some View {
        TimeSeriesChartView(
            metric: panel.effectiveMetric,
            data: data,
            frames: frames,
            panel: panel,
            viewModel: viewModel,
            dateFormat: dateFormat
        )
    }
}
