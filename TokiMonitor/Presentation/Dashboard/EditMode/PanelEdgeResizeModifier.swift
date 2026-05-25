import SwiftUI

/// Edge-based panel resize.
///
/// Three invisible drag affordances on the panel's right edge, bottom edge,
/// and bottom-right corner. Each strip is rendered via an `.overlay {
/// GeometryReader }`, which works correctly only because the parent panel
/// is placed by `DashboardCustomLayout` — the layout protocol gives the
/// panel an outer frame equal to its grid cell, so `proxy.size` here is
/// the panel size, not the container size.
///
/// Behavior:
/// - Cursor switches to resizeLeftRight / resizeUpDown / crosshair on hover,
///   guarded by a per-strip `pushed` state so push/pop stay balanced even
///   when SwiftUI emits noisy hover events.
/// - DragGesture snaps width/height to the grid every frame using the
///   *actual* `rowHeight` (the dashboard uses an adaptive row height — a
///   fixed 80pt assumption would misalign the snap).
/// - In-memory updates during the drag, single `saveDashboard` commit at
///   the end via `viewModel.commitPanelPositionChange()`.
/// - Hit-testing is disabled while another modifier on the same panel
///   (i.e. PanelDragModifier) is mid-drag, so the two gestures don't
///   stomp each other.
struct PanelEdgeResize: ViewModifier {
    let panelID: UUID
    let panelType: PanelType
    let containerWidth: CGFloat
    let rowHeight: CGFloat
    let isEditing: Bool
    @Bindable var viewModel: DashboardViewModel

    /// Drag area thickness on a panel's edge.
    private static let stripThickness: CGFloat = 6
    /// Side length of the bottom-right corner affordance.
    private static let cornerSize: CGFloat = 14

    func body(content: Content) -> some View {
        content.overlay {
            if isEditing && viewModel.draggingPanelID != panelID {
                GeometryReader { proxy in
                    let w = proxy.size.width
                    let h = proxy.size.height

                    ZStack(alignment: .topLeading) {
                        ResizeHandleStrip(
                            cursor: .resizeLeftRight,
                            onDragChanged: { t in apply(translation: t, horizontal: true, vertical: false) },
                            onDragEnded: { t in commit(translation: t, horizontal: true, vertical: false) }
                        )
                        .frame(width: Self.stripThickness, height: h)
                        .offset(x: w - Self.stripThickness, y: 0)

                        ResizeHandleStrip(
                            cursor: .resizeUpDown,
                            onDragChanged: { t in apply(translation: t, horizontal: false, vertical: true) },
                            onDragEnded: { t in commit(translation: t, horizontal: false, vertical: true) }
                        )
                        .frame(width: w, height: Self.stripThickness)
                        .offset(x: 0, y: h - Self.stripThickness)

                        // Corner is drawn last so it wins SwiftUI's
                        // ZStack hit-test on the overlapping bottom-right
                        // region. (SwiftUI hit-tests the last child first.)
                        ResizeHandleStrip(
                            cursor: .crosshair,
                            onDragChanged: { t in apply(translation: t, horizontal: true, vertical: true) },
                            onDragEnded: { t in commit(translation: t, horizontal: true, vertical: true) }
                        )
                        .frame(width: Self.cornerSize, height: Self.cornerSize)
                        .offset(x: w - Self.cornerSize, y: h - Self.cornerSize)
                    }
                }
            }
        }
    }

    // MARK: - Grid math

    /// Apply a drag translation to the panel's grid position in memory.
    /// Snaps width/height to the grid using the *adaptive* row height that
    /// the dashboard is currently rendering with.
    private func apply(translation: CGSize, horizontal: Bool, vertical: Bool) {
        guard let panel = viewModel.dashboardConfig.panels.first(where: { $0.id == panelID })
        else { return }

        let cellWidth = columnWidth(in: containerWidth) + DashboardGridLayout.gap
        let cellHeight = rowHeight + DashboardGridLayout.gap

        var newWidth = panel.gridPosition.width
        var newHeight = panel.gridPosition.height

        if horizontal {
            let widthDelta = Int(round(translation.width / cellWidth))
            newWidth = max(panelType.minWidth, panel.gridPosition.width + widthDelta)
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
        viewModel.setPanelPositionInMemory(id: panelID, position: newPosition)
    }

    /// Commit the resize on drag end — applies one more snap and persists.
    private func commit(translation: CGSize, horizontal: Bool, vertical: Bool) {
        apply(translation: translation, horizontal: horizontal, vertical: vertical)
        viewModel.commitPanelPositionChange()
    }

    private func columnWidth(in containerWidth: CGFloat) -> CGFloat {
        let gaps = DashboardGridLayout.gap * CGFloat(DashboardGridLayout.columnCount - 1)
        return (containerWidth - gaps) / CGFloat(DashboardGridLayout.columnCount)
    }
}

// MARK: - Resize handle strip

/// A single invisible drag strip with cursor management that survives
/// SwiftUI's noisy hover events.
///
/// `NSCursor.push()` and `.pop()` are stack operations. If `.onHover`
/// fires `false` while we never pushed (or `true` twice without a pop
/// in between), the cursor stack drifts permanently — the cursor stays
/// as a resize arrow over chart panels, or pops down into nothing.
/// The `pushed` flag guards push and pop to only fire on actual
/// false→true / true→false transitions.
private struct ResizeHandleStrip: View {
    let cursor: NSCursor
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void

    @State private var pushed = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering, !pushed {
                    cursor.push()
                    pushed = true
                } else if !hovering, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .onChanged { onDragChanged($0.translation) }
                    .onEnded { onDragEnded($0.translation) }
            )
    }
}

extension View {
    func panelEdgeResize(
        panelID: UUID,
        panelType: PanelType,
        containerWidth: CGFloat,
        rowHeight: CGFloat,
        isEditing: Bool,
        viewModel: DashboardViewModel
    ) -> some View {
        modifier(PanelEdgeResize(
            panelID: panelID,
            panelType: panelType,
            containerWidth: containerWidth,
            rowHeight: rowHeight,
            isEditing: isEditing,
            viewModel: viewModel
        ))
    }
}
