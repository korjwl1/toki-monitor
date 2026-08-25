import SwiftUI

/// Table panel render.
///
/// Moved here verbatim from `CustomDashboardView.tableContent` so that a panel
/// type has exactly one render implementation in the app (contract R2). What
/// this file used to contain — a six-column table aggregating `TimeSeriesData`
/// itself, plus a top-level `ModelRow` shadowing
/// `PanelDataExtractor.ModelRow` — was never instantiated.
struct TablePanelView: View {
    let data: TimeSeriesData?
    let frames: FrameSet?

    var body: some View {
        let rows = PanelSeries.rows(frames: frames, data: data)
        if rows.isEmpty {
            Text("-")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows) {
                TableColumn(L.dash.axisModel, value: \.model)
                TableColumn(L.dash.axisTokens) { row in
                    Text(TokenFormatter.formatTokens(row.tokens))
                        .monospacedDigit()
                }
                TableColumn(L.dash.axisCost) { row in
                    Text(TokenFormatter.formatCost(row.cost))
                        .monospacedDigit()
                }
            }
        }
    }
}
