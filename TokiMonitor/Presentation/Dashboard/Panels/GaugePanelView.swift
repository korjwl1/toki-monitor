import SwiftUI

/// Gauge panel render.
///
/// Moved here verbatim from `CustomDashboardView.gaugeContent` so that a panel
/// type has exactly one render implementation in the app (contract R2). What
/// this file used to contain — a circular ring driven by `viewModel` totals —
/// was never instantiated, so it is not what a user has ever seen.
///
/// This is deliberately still the large-number rendering that ships today.
/// Contract R4 wants an actual gauge; that is T020, not this move.
struct GaugePanelView: View {
    let panel: PanelConfig
    let data: TimeSeriesData?
    let frames: FrameSet?

    var body: some View {
        let stat = StatPanelView.statValue(panel: panel, data: data, frames: frames)
        VStack {
            Text(stat.value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
