import SwiftUI

/// ViewModifier that enables dragging a panel to reposition it on the grid
/// in edit mode.
///
/// Uses `.offset(dragOffset)` for visual feedback during the drag (no
/// layout participation). The final snapped grid position is computed
/// against the *actual* `rowHeight` the dashboard is using — passing the
/// adaptive row height in is required, otherwise the snap target is wrong
/// when the viewport stretched rows past 80pt.
struct PanelDragModifier: ViewModifier {
    let panelID: UUID
    let containerWidth: CGFloat
    let rowHeight: CGFloat
    let isEditing: Bool
    @Bindable var viewModel: DashboardViewModel

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(dragOffset)
            .opacity(isDragging ? 0.7 : 1.0)
            .scaleEffect(isDragging ? 0.98 : 1.0)
            .animation(Motion.reveal(reduceMotion), value: isDragging)
            .gesture(dragGesture, isEnabled: isEditing)
            // SwiftUI does not call `.onEnded` when a gesture is disabled
            // mid-drag (e.g. `isEditing` flips false from a hotkey). Reset
            // the in-flight visual state explicitly so the panel doesn't
            // stay translucent at a stale offset.
            .onChange(of: isEditing) { _, newValue in
                if !newValue && isDragging {
                    isDragging = false
                    dragOffset = .zero
                    if viewModel.draggingPanelID == panelID {
                        viewModel.draggingPanelID = nil
                    }
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    viewModel.draggingPanelID = panelID
                }
                dragOffset = value.translation
            }
            .onEnded { value in
                isDragging = false
                viewModel.draggingPanelID = nil

                guard let panel = viewModel.dashboardConfig.panels.first(where: { $0.id == panelID }) else {
                    dragOffset = .zero
                    return
                }

                let currentFrame = DashboardGridLayout.frame(
                    for: panel.gridPosition,
                    in: containerWidth,
                    rowHeight: rowHeight
                )
                let newOrigin = CGPoint(
                    x: currentFrame.origin.x + value.translation.width,
                    y: currentFrame.origin.y + value.translation.height
                )

                let snapped = DashboardGridLayout.snapToGrid(
                    point: newOrigin,
                    in: containerWidth,
                    rowHeight: rowHeight
                )

                // Clamp column so panel doesn't overflow
                let maxColumn = DashboardGridLayout.columnCount - panel.gridPosition.width
                let clampedColumn = max(0, min(maxColumn, snapped.column))
                // Clamp row against an upper bound so an overshoot drag
                // (e.g. user fling past the dashboard) doesn't push the
                // row index into the millions — `snapToGrid` itself has
                // no row ceiling, and a runaway row blows up
                // `DashboardGridLayout.totalHeight` on the next render.
                let logicalRows = DashboardGridLayout.totalLogicalRows(for: viewModel.dashboardConfig.panels)
                let maxRow = max(logicalRows, panel.gridPosition.row + 1) + Self.dragRowSlack
                let clampedRow = max(0, min(maxRow, snapped.row))

                let newPosition = GridPosition(
                    column: clampedColumn,
                    row: clampedRow,
                    width: panel.gridPosition.width,
                    height: panel.gridPosition.height
                )

                viewModel.updatePanelPosition(id: panelID, position: newPosition)
                dragOffset = .zero
            }
    }

    /// Extra rows beyond the current dashboard footprint that a single drag
    /// is allowed to land in. Lets the user position below existing
    /// content without inviting unbounded row indices.
    private static let dragRowSlack: Int = 8
}

extension View {
    func panelDrag(
        panelID: UUID,
        containerWidth: CGFloat,
        rowHeight: CGFloat,
        isEditing: Bool,
        viewModel: DashboardViewModel
    ) -> some View {
        modifier(PanelDragModifier(
            panelID: panelID,
            containerWidth: containerWidth,
            rowHeight: rowHeight,
            isEditing: isEditing,
            viewModel: viewModel
        ))
    }
}
