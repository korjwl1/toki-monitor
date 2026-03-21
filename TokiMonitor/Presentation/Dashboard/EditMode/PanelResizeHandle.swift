import SwiftUI

/// A bottom-right corner resize handle for dashboard panels.
/// Only visible when the dashboard is in edit mode.
struct PanelResizeHandle: View {
    let panelID: UUID
    let panelType: PanelType
    let containerWidth: CGFloat
    @Bindable var viewModel: DashboardViewModel

    @State private var isDragging = false

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                resizeGrip
                    .frame(width: 12, height: 12)
                    .padding(4)
            }
        }
    }

    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(isDragging ? .primary : .tertiary)
            .frame(width: 12, height: 12)
            .contentShape(Rectangle().size(width: 20, height: 20))
            .gesture(resizeGesture)
            .onHover { hovering in
                if hovering {
                    NSCursor.crosshair.push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { _ in
                isDragging = true
            }
            .onEnded { value in
                isDragging = false

                guard let panel = viewModel.dashboardConfig.panels.first(where: { $0.id == panelID }) else {
                    return
                }

                let currentFrame = DashboardGridLayout.frame(for: panel.gridPosition, in: containerWidth)
                let newBottomRight = CGPoint(
                    x: currentFrame.maxX + value.translation.width,
                    y: currentFrame.maxY + value.translation.height
                )

                let origin = CGPoint(
                    x: currentFrame.origin.x,
                    y: currentFrame.origin.y
                )

                let snappedEnd = DashboardGridLayout.snapToGrid(point: newBottomRight, in: containerWidth)
                let snappedOrigin = DashboardGridLayout.snapToGrid(point: origin, in: containerWidth)

                var newWidth = max(snappedEnd.column - snappedOrigin.column + 1, panelType.minWidth)
                var newHeight = max(snappedEnd.row - snappedOrigin.row + 1, panelType.minHeight)

                // Clamp to grid bounds
                let maxWidth = DashboardGridLayout.columnCount - panel.gridPosition.column
                newWidth = min(newWidth, maxWidth)
                newHeight = max(newHeight, 1)

                let newPosition = GridPosition(
                    column: panel.gridPosition.column,
                    row: panel.gridPosition.row,
                    width: newWidth,
                    height: newHeight
                )

                viewModel.updatePanelPosition(id: panelID, position: newPosition)
            }
    }
}
