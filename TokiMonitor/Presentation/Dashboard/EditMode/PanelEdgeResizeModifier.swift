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

    /// Captured at the first `.onChanged` of a resize gesture. The drag
    /// translation is cumulative from gesture start, so the new size must
    /// be computed against the *original* position — not the live
    /// `panel.gridPosition`, which has already been mutated by prior
    /// frames via `setPanelPositionInMemory`. Reading the live value as
    /// baseline causes the panel to grow one cell per frame after the
    /// first cell-crossing (runaway resize).
    @State private var initialPosition: GridPosition?

    /// Drag area thickness on a panel's edge.
    private static let stripThickness: CGFloat = 6
    /// Side length of the bottom-right corner affordance. Small enough that
    /// it doesn't dominate a 1-row stat panel (~80pt tall) — drift into the
    /// corner from a horizontal drag was making stat panels grow vertically
    /// when the user only wanted to change width.
    private static let cornerSize: CGFloat = 10
    /// Upper bound on panel height (in rows). Without this, a runaway
    /// vertical drag could push the persisted height arbitrarily large.
    /// 48 rows ≈ 4 viewport heights at default row height — plenty for any
    /// legitimate panel, hard ceiling against bug-driven growth.
    private static let maxPanelHeight: Int = 48

    func body(content: Content) -> some View {
        content
            .overlay {
                if isEditing && viewModel.draggingPanelID != panelID {
                    GeometryReader { proxy in
                        let w = proxy.size.width
                        let h = proxy.size.height

                        // Strips are laid out so edge and corner regions are
                        // **mutually exclusive**, not overlapping. With the old
                        // overlapping layout, the corner (which drives both
                        // axes) sat on the bottom 14pt of the right-edge strip;
                        // a tall stat panel is only 80pt, so a "drag right edge
                        // a bit left" gesture often landed in the corner zone
                        // and changed height as well. Splitting the regions
                        // means a drag on the right edge is *only* horizontal.
                        ZStack(alignment: .topLeading) {
                            // Right edge — everything above the corner zone.
                            ResizeHandleStrip(
                                cursor: .resizeLeftRight,
                                onDragChanged: { t in apply(translation: t, horizontal: true, vertical: false) },
                                onDragEnded: { t in commit(translation: t, horizontal: true, vertical: false) }
                            )
                            .frame(width: Self.stripThickness, height: max(0, h - Self.cornerSize))
                            .offset(x: w - Self.stripThickness, y: 0)

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
            // Edit mode toggling off mid-resize doesn't call `.onEnded` on
            // the strip's gesture — the overlay just disappears. Revert any
            // in-flight in-memory mutation to the captured baseline so a
            // partially-resized panel doesn't get silently committed on the
            // next save.
            .onChange(of: isEditing) { _, newValue in
                if !newValue, let baseline = initialPosition {
                    viewModel.setPanelPositionInMemory(id: panelID, position: baseline)
                    initialPosition = nil
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

        // Capture the pre-drag position on the first `.onChanged`. All
        // subsequent frames compute against this baseline so the cumulative
        // `translation` doesn't compound with prior in-memory mutations.
        let baseline = initialPosition ?? panel.gridPosition
        if initialPosition == nil {
            initialPosition = baseline
        }

        let cellWidth = columnWidth(in: containerWidth) + DashboardGridLayout.gap
        let cellHeight = rowHeight + DashboardGridLayout.gap

        var newWidth = baseline.width
        var newHeight = baseline.height

        if horizontal {
            let widthDelta = Int(round(translation.width / cellWidth))
            newWidth = max(panelType.minWidth, baseline.width + widthDelta)
            let maxWidth = DashboardGridLayout.columnCount - baseline.column
            newWidth = min(newWidth, maxWidth)
        }

        if vertical {
            let heightDelta = Int(round(translation.height / cellHeight))
            newHeight = max(panelType.minHeight, baseline.height + heightDelta)
            newHeight = min(newHeight, Self.maxPanelHeight)
        }

        guard newWidth != panel.gridPosition.width || newHeight != panel.gridPosition.height
        else { return }

        let newPosition = GridPosition(
            column: baseline.column,
            row: baseline.row,
            width: newWidth,
            height: newHeight
        )
        viewModel.setPanelPositionInMemory(id: panelID, position: newPosition)
    }

    /// Commit the resize on drag end — applies one more snap and persists.
    private func commit(translation: CGSize, horizontal: Bool, vertical: Bool) {
        apply(translation: translation, horizontal: horizontal, vertical: vertical)
        viewModel.commitPanelPositionChange()
        initialPosition = nil
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
