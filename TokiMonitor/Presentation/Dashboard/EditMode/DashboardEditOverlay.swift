import SwiftUI

/// Background grid overlay shown when the dashboard is in edit mode.
/// Displays subtle column and row boundary lines.
struct DashboardEditOverlay: View {
    let containerWidth: CGFloat
    let totalHeight: CGFloat

    private let columnCount = DashboardGridLayout.columnCount
    private let rowHeight = DashboardGridLayout.rowHeight
    private let gap = DashboardGridLayout.gap

    var body: some View {
        Canvas { context, size in
            let columnWidth = (containerWidth - gap * CGFloat(columnCount - 1)) / CGFloat(columnCount)
            let cellWidth = columnWidth + gap
            let cellHeight = rowHeight + gap

            let lineColor = Color.secondary.opacity(0.15)

            // Vertical lines at column boundaries
            for col in 0...columnCount {
                let x = CGFloat(col) * cellWidth - gap / 2
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(lineColor), lineWidth: 0.5)
            }

            // Horizontal lines at row boundaries
            let rowCount = Int(ceil(size.height / cellHeight)) + 1
            for row in 0...rowCount {
                let y = CGFloat(row) * cellHeight - gap / 2
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(lineColor), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}
