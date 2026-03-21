import Foundation

/// 12-column grid calculation engine for the customizable dashboard.
/// Each column is proportional to the container width. Rows are fixed at 80pt.
struct DashboardGridLayout {

    // MARK: - Constants

    static let columnCount = 12
    static let rowHeight: CGFloat = 80
    static let gap: CGFloat = 12

    // MARK: - Frame Calculation

    /// Returns the frame rect for a panel at the given grid position within the container width.
    static func frame(for gridPosition: GridPosition, in containerWidth: CGFloat) -> CGRect {
        let columnWidth = (containerWidth - gap * CGFloat(columnCount - 1)) / CGFloat(columnCount)

        let x = CGFloat(gridPosition.column) * (columnWidth + gap)
        let y = CGFloat(gridPosition.row) * (rowHeight + gap)
        let width = CGFloat(gridPosition.width) * columnWidth + CGFloat(gridPosition.width - 1) * gap
        let height = CGFloat(gridPosition.height) * rowHeight + CGFloat(gridPosition.height - 1) * gap

        return CGRect(x: x, y: y, width: max(width, 0), height: max(height, 0))
    }

    // MARK: - Snap to Grid

    /// Converts a point to the nearest grid column/row.
    static func snapToGrid(point: CGPoint, in containerWidth: CGFloat) -> (column: Int, row: Int) {
        let columnWidth = (containerWidth - gap * CGFloat(columnCount - 1)) / CGFloat(columnCount)
        let cellWidth = columnWidth + gap
        let cellHeight = rowHeight + gap

        let column = max(0, min(columnCount - 1, Int(round(point.x / cellWidth))))
        let row = max(0, Int(round(point.y / cellHeight)))

        return (column: column, row: row)
    }

    // MARK: - Total Height

    /// Calculates total grid height needed to contain all panels.
    static func totalHeight(for panels: [PanelConfig]) -> CGFloat {
        guard !panels.isEmpty else { return rowHeight }

        let maxRow = panels.map { $0.gridPosition.row + $0.gridPosition.height }.max() ?? 1
        return CGFloat(maxRow) * (rowHeight + gap) - gap
    }

    // MARK: - First Available Position

    /// Finds the first available grid position for a panel of the given size.
    static func firstAvailablePosition(
        width: Int,
        height: Int,
        existing: [PanelConfig]
    ) -> GridPosition {
        // Build an occupancy grid
        let maxRow = (existing.map { $0.gridPosition.row + $0.gridPosition.height }.max() ?? 0) + height + 1
        var occupied = Array(repeating: Array(repeating: false, count: columnCount), count: maxRow)

        for panel in existing {
            let pos = panel.gridPosition
            for r in pos.row..<(pos.row + pos.height) {
                for c in pos.column..<min(pos.column + pos.width, columnCount) {
                    if r < maxRow {
                        occupied[r][c] = true
                    }
                }
            }
        }

        // Scan row by row, column by column
        for row in 0..<maxRow {
            for col in 0...(columnCount - width) {
                var fits = true
                for r in row..<(row + height) {
                    for c in col..<(col + width) {
                        if r < maxRow && occupied[r][c] {
                            fits = false
                            break
                        }
                    }
                    if !fits { break }
                }
                if fits {
                    return GridPosition(column: col, row: row, width: width, height: height)
                }
            }
        }

        // Fallback: place below everything
        let nextRow = existing.map { $0.gridPosition.row + $0.gridPosition.height }.max() ?? 0
        return GridPosition(column: 0, row: nextRow, width: width, height: height)
    }
}
