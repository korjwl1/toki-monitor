import SwiftUI

/// Edge-based panel resize. Three invisible drag strips overlay the right
/// edge, bottom edge, and bottom-right corner of a panel; each one updates
/// `gridPosition.width` and/or `.height` while the user drags, with grid
/// snapping applied every frame so the panel resizes live rather than only
/// committing on release.
///
/// Replaces the old in-panel ↘ glyph (`PanelResizeHandle`), which placed
/// the affordance inside the card and only updated on drag end.
struct PanelEdgeResize: ViewModifier {
    let panelID: UUID
    let panelType: PanelType
    let containerWidth: CGFloat
    let isEditing: Bool
    @Bindable var viewModel: DashboardViewModel

    /// Drag area thickness on the panel edges. Sits just inside the dashed
    /// border so the user lands on the affordance when targeting the visible
    /// edge.
    private static let stripThickness: CGFloat = 6
    private static let cornerSize: CGFloat = 14

    func body(content: Content) -> some View {
        content.overlay {
            if isEditing {
                ZStack {
                    rightEdgeStrip
                    bottomEdgeStrip
                    bottomRightCorner
                }
            }
        }
    }

    // MARK: - Strips

    private var rightEdgeStrip: some View {
        HStack {
            Spacer()
            Color.clear
                .frame(width: Self.stripThickness)
                .contentShape(Rectangle())
                .onHover { hovering in
                    setCursor(hovering ? .resizeLeftRight : nil)
                }
                .gesture(resizeGesture(horizontal: true, vertical: false))
        }
    }

    private var bottomEdgeStrip: some View {
        VStack {
            Spacer()
            Color.clear
                .frame(height: Self.stripThickness)
                .contentShape(Rectangle())
                .onHover { hovering in
                    setCursor(hovering ? .resizeUpDown : nil)
                }
                .gesture(resizeGesture(horizontal: false, vertical: true))
        }
    }

    private var bottomRightCorner: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Color.clear
                    .frame(width: Self.cornerSize, height: Self.cornerSize)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        setCursor(hovering ? .crosshair : nil)
                    }
                    .gesture(resizeGesture(horizontal: true, vertical: true))
            }
        }
    }

    // MARK: - Gesture

    private func resizeGesture(horizontal: Bool, vertical: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                apply(translation: value.translation, horizontal: horizontal, vertical: vertical)
            }
            .onEnded { value in
                apply(translation: value.translation, horizontal: horizontal, vertical: vertical)
                setCursor(nil)
            }
    }

    /// Convert a drag translation into a new `GridPosition` and commit it
    /// through the view model. Snaps width/height to the column/row grid
    /// on every frame so the panel grows in discrete steps.
    private func apply(translation: CGSize, horizontal: Bool, vertical: Bool) {
        guard let panel = viewModel.dashboardConfig.panels.first(where: { $0.id == panelID })
        else { return }

        let cellWidth = columnWidth(in: containerWidth) + DashboardGridLayout.gap
        let cellHeight = DashboardGridLayout.defaultRowHeight + DashboardGridLayout.gap

        var newWidth = panel.gridPosition.width
        var newHeight = panel.gridPosition.height

        if horizontal {
            let dx = translation.width
            let widthDelta = Int(round(dx / cellWidth))
            newWidth = max(panelType.minWidth, panel.gridPosition.width + widthDelta)
            // Clamp to right edge of grid.
            let maxWidth = DashboardGridLayout.columnCount - panel.gridPosition.column
            newWidth = min(newWidth, maxWidth)
        }

        if vertical {
            let dy = translation.height
            let heightDelta = Int(round(dy / cellHeight))
            newHeight = max(panelType.minHeight, panel.gridPosition.height + heightDelta)
        }

        if newWidth == panel.gridPosition.width && newHeight == panel.gridPosition.height {
            return
        }

        let newPosition = GridPosition(
            column: panel.gridPosition.column,
            row: panel.gridPosition.row,
            width: newWidth,
            height: newHeight
        )
        viewModel.updatePanelPosition(id: panelID, position: newPosition)
    }

    private func columnWidth(in containerWidth: CGFloat) -> CGFloat {
        let gaps = DashboardGridLayout.gap * CGFloat(DashboardGridLayout.columnCount - 1)
        return (containerWidth - gaps) / CGFloat(DashboardGridLayout.columnCount)
    }

    private func setCursor(_ cursor: NSCursor?) {
        if let cursor {
            cursor.push()
        } else {
            NSCursor.pop()
        }
    }
}

extension View {
    func panelEdgeResize(
        panelID: UUID,
        panelType: PanelType,
        containerWidth: CGFloat,
        isEditing: Bool,
        viewModel: DashboardViewModel
    ) -> some View {
        modifier(PanelEdgeResize(
            panelID: panelID,
            panelType: panelType,
            containerWidth: containerWidth,
            isEditing: isEditing,
            viewModel: viewModel
        ))
    }
}
