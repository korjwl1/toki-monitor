import Foundation

/// 24-column responsive grid calculation engine for the customizable dashboard.
/// Column width is proportional to container width. Row height is proportional to container height.
struct DashboardGridLayout {

    // MARK: - Constants

    static let columnCount = 24
    static let gap: CGFloat = 8
    static let defaultRowHeight: CGFloat = 80

    // MARK: - Dynamic Row Height

    /// Calculate row height to fill available container height
    static func dynamicRowHeight(for panels: [PanelConfig], containerHeight: CGFloat) -> CGFloat {
        let totalRows = totalLogicalRows(for: panels)
        guard totalRows > 0 else { return defaultRowHeight }
        let totalGaps = gap * CGFloat(totalRows - 1)
        let available = containerHeight - totalGaps
        let rowHeight = available / CGFloat(totalRows)
        return max(rowHeight, 40) // minimum 40pt per row
    }

    /// Total logical rows needed
    static func totalLogicalRows(for panels: [PanelConfig]) -> Int {
        guard !panels.isEmpty else { return 1 }
        return panels.map { $0.gridPosition.row + $0.gridPosition.height }.max() ?? 1
    }

    // MARK: - Frame Calculation

    /// Returns the frame rect for a panel at the given grid position.
    static func frame(
        for gridPosition: GridPosition,
        in containerWidth: CGFloat,
        rowHeight: CGFloat = defaultRowHeight
    ) -> CGRect {
        let columnWidth = (containerWidth - gap * CGFloat(columnCount - 1)) / CGFloat(columnCount)

        let x = CGFloat(gridPosition.column) * (columnWidth + gap)
        let y = CGFloat(gridPosition.row) * (rowHeight + gap)
        let width = CGFloat(gridPosition.width) * columnWidth + CGFloat(gridPosition.width - 1) * gap
        let height = CGFloat(gridPosition.height) * rowHeight + CGFloat(gridPosition.height - 1) * gap

        return CGRect(x: x, y: y, width: max(width, 0), height: max(height, 0))
    }

    // MARK: - Snap to Grid

    static func snapToGrid(
        point: CGPoint,
        in containerWidth: CGFloat,
        rowHeight: CGFloat = defaultRowHeight
    ) -> (column: Int, row: Int) {
        let columnWidth = (containerWidth - gap * CGFloat(columnCount - 1)) / CGFloat(columnCount)
        let cellWidth = columnWidth + gap
        let cellHeight = rowHeight + gap

        let column = max(0, min(columnCount - 1, Int(round(point.x / cellWidth))))
        let row = max(0, Int(round(point.y / cellHeight)))

        return (column: column, row: row)
    }

    // MARK: - Total Height

    static func totalHeight(
        for panels: [PanelConfig],
        rowHeight: CGFloat = defaultRowHeight
    ) -> CGFloat {
        guard !panels.isEmpty else { return rowHeight }
        let maxRow = panels.map { $0.gridPosition.row + $0.gridPosition.height }.max() ?? 1
        return CGFloat(maxRow) * (rowHeight + gap) - gap
    }

    // MARK: - First Available Position

    static func firstAvailablePosition(
        width: Int,
        height: Int,
        existing: [PanelConfig]
    ) -> GridPosition {
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

        let nextRow = existing.map { $0.gridPosition.row + $0.gridPosition.height }.max() ?? 0
        return GridPosition(column: 0, row: nextRow, width: width, height: height)
    }
}
