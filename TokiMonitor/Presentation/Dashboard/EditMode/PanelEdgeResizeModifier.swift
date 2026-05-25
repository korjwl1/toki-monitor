import SwiftUI

/// Edge-based panel resize.
///
/// Each panel gets three invisible drag affordances pinned to its own
/// boundary via `GeometryReader` + explicit `.offset` — right edge strip,
/// bottom edge strip, bottom-right corner. Using positioned `Color.clear`
/// rectangles (rather than `HStack { Spacer; Color.clear }`) is what
/// guarantees the hit area is exactly the strip and does not leak into
/// adjacent panels — the earlier Spacer-based layout had subtle hit-test
/// bleed where dragging one panel's edge could affect a neighbor.
///
/// Each affordance:
/// - Sets a SwiftUI hover cursor (resizeLeftRight / resizeUpDown / crosshair).
/// - Drives the panel's `gridPosition.width` / `.height` via a `DragGesture`
///   that snaps to the grid live, so the panel resizes as the user drags
///   rather than only on release.
struct PanelEdgeResize: ViewModifier {
    let panelID: UUID
    let panelType: PanelType
    let containerWidth: CGFloat
    let isEditing: Bool
    @Bindable var viewModel: DashboardViewModel

    /// Drag area thickness on a panel's edge.
    private static let stripThickness: CGFloat = 6
    /// Side length of the bottom-right corner affordance (overlaps the two
    /// edge strips so the corner can drive both axes at once).
    private static let cornerSize: CGFloat = 14

    func body(content: Content) -> some View {
        content.overlay {
            if isEditing {
                GeometryReader { proxy in
                    let w = proxy.size.width
                    let h = proxy.size.height

                    ZStack(alignment: .topLeading) {
                        // Right edge strip (horizontal resize)
                        Color.clear
                            .frame(width: Self.stripThickness, height: h)
                            .contentShape(Rectangle())
                            .offset(x: w - Self.stripThickness, y: 0)
                            .onHover { hovering in
                                setCursor(hovering ? .resizeLeftRight : nil)
                            }
                            .gesture(resizeGesture(horizontal: true, vertical: false))

                        // Bottom edge strip (vertical resize)
                        Color.clear
                            .frame(width: w, height: Self.stripThickness)
                            .contentShape(Rectangle())
                            .offset(x: 0, y: h - Self.stripThickness)
                            .onHover { hovering in
                                setCursor(hovering ? .resizeUpDown : nil)
                            }
                            .gesture(resizeGesture(horizontal: false, vertical: true))

                        // Bottom-right corner (both axes) — drawn last so it
                        // wins over the two edge strips where they overlap.
                        Color.clear
                            .frame(width: Self.cornerSize, height: Self.cornerSize)
                            .contentShape(Rectangle())
                            .offset(x: w - Self.cornerSize, y: h - Self.cornerSize)
                            .onHover { hovering in
                                setCursor(hovering ? .crosshair : nil)
                            }
                            .gesture(resizeGesture(horizontal: true, vertical: true))
                    }
                }
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

    /// Apply a drag translation to the panel's grid position. Width and
    /// height are snapped to the grid every frame so the visual update
    /// tracks the drag.
    private func apply(translation: CGSize, horizontal: Bool, vertical: Bool) {
        guard let panel = viewModel.dashboardConfig.panels.first(where: { $0.id == panelID })
        else { return }

        let cellWidth = columnWidth(in: containerWidth) + DashboardGridLayout.gap
        let cellHeight = DashboardGridLayout.defaultRowHeight + DashboardGridLayout.gap

        var newWidth = panel.gridPosition.width
        var newHeight = panel.gridPosition.height

        if horizontal {
            let widthDelta = Int(round(translation.width / cellWidth))
            newWidth = max(panelType.minWidth, panel.gridPosition.width + widthDelta)
            // Clamp to the right edge of the 24-column grid so panels can't
            // grow past the dashboard.
            let maxWidth = DashboardGridLayout.columnCount - panel.gridPosition.column
            newWidth = min(newWidth, maxWidth)
        }

        if vertical {
            let heightDelta = Int(round(translation.height / cellHeight))
            newHeight = max(panelType.minHeight, panel.gridPosition.height + heightDelta)
        }

        guard newWidth != panel.gridPosition.width || newHeight != panel.gridPosition.height
        else { return }

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
