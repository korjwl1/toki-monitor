import SwiftUI
import AppKit

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
    /// Side length of the bottom-right corner affordance. Small enough that
    /// it doesn't dominate a 1-row stat panel (~80pt tall) — drift into the
    /// corner from a horizontal drag was making stat panels grow vertically
    /// when the user only wanted to change width.
    private static let cornerSize: CGFloat = 10

    func body(content: Content) -> some View {
        content.overlay {
            if isEditing && viewModel.draggingPanelID != panelID {
                GeometryReader { proxy in
                    let w = proxy.size.width
                    let h = proxy.size.height
                    let allowsVertical = panelType.allowsVerticalResize

                    // Strips are laid out so edge and corner regions are
                    // **mutually exclusive**, not overlapping. With the old
                    // overlapping layout, the corner (which drives both
                    // axes) sat on the bottom 14pt of the right-edge strip;
                    // a tall stat panel is only 80pt, so a "drag right edge
                    // a bit left" gesture often landed in the corner zone
                    // and changed height as well. Splitting the regions
                    // means a drag on the right edge is *only* horizontal.
                    //
                    // For panel types that do not allow vertical resize
                    // (stat cards) we skip the bottom-edge and corner
                    // strips entirely and let the right-edge strip own
                    // the full panel height — there is no corner zone to
                    // carve out.
                    ZStack(alignment: .topLeading) {
                        // Right edge — full panel height for vertically
                        // locked types, otherwise stops above the corner.
                        ResizeHandleStrip(
                            cursor: .resizeLeftRight,
                            onDragChanged: { t in apply(translation: t, horizontal: true, vertical: false) },
                            onDragEnded: { t in commit(translation: t, horizontal: true, vertical: false) }
                        )
                        .frame(
                            width: Self.stripThickness,
                            height: allowsVertical ? max(0, h - Self.cornerSize) : h
                        )
                        .offset(x: w - Self.stripThickness, y: 0)

                        if allowsVertical {
                            // Bottom edge — everything left of the corner zone.
                            ResizeHandleStrip(
                                cursor: .resizeUpDown,
                                onDragChanged: { t in apply(translation: t, horizontal: false, vertical: true) },
                                onDragEnded: { t in commit(translation: t, horizontal: false, vertical: true) }
                            )
                            .frame(width: max(0, w - Self.cornerSize), height: Self.stripThickness)
                            .offset(x: 0, y: h - Self.stripThickness)

                            // Bottom-right corner — its own non-overlapping
                            // square. Drives both axes.
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

/// A single invisible drag strip.
///
/// Cursor management is delegated to AppKit via `addCursorRect(_:cursor:)`
/// rather than `NSCursor.push()` / `.pop()`. push/pop are stack ops, and
/// `.onHover` emits noisy false→true→false toggles (especially when a
/// panel re-lays out mid-hover) that can leave the cursor stack
/// permanently off-balance — chart panels stuck with a resize arrow, or
/// the stack popping below the system default. Cursor rects, by
/// contrast, are *declarative*: AppKit takes over once the mouse enters
/// the view's bounding rect and restores the previous cursor when it
/// leaves. No state, no drift.
private struct ResizeHandleStrip: View {
    let cursor: NSCursor
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void

    var body: some View {
        CursorRectView(cursor: cursor)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .onChanged { onDragChanged($0.translation) }
                    .onEnded { onDragEnded($0.translation) }
            )
    }
}

/// AppKit-backed view that sets a cursor rectangle covering its entire
/// bounds. SwiftUI re-asks for `resetCursorRects` whenever layout
/// changes, so the rect stays in sync as panels resize.
private struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorAwareView {
        let view = CursorAwareView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: CursorAwareView, context: Context) {
        nsView.cursor = cursor
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class CursorAwareView: NSView {
    var cursor: NSCursor = .arrow

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
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
