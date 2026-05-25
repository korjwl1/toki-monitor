import SwiftUI

/// Custom `Layout` that places each dashboard panel at its grid frame.
///
/// Why this exists (and why `.position()` / `.offset()` did not work):
///
/// `.offset()` only translates a view visually — the layout position
/// and hit-test region stay at (0, 0). All panels in a ZStack ended
/// up with overlapping hit areas at the origin, and the last-drawn
/// panel intercepted gestures meant for any other panel.
///
/// `.position(x:y:)` looks like it fixes that, but it actually wraps
/// the child in a *new view that takes up all available space*
/// (Apple docs, Hacking with Swift). The child shows up at (x, y), but
/// the outer wrapper still occupies the entire container. Inside that
/// wrapper, `GeometryReader.proxy.size` returns the *container* size,
/// not the panel size — so every panel's `.overlay { GeometryReader }`
/// reported the full dashboard width and placed its right-edge resize
/// strip at the dashboard's right edge. All panels' strips stacked at
/// the same coordinate; the top-most one (last drawn) stole the gesture.
///
/// `Layout`'s `placeSubviews` calls `subview.place(at:anchor:proposal:)`
/// with the exact rect we choose. Each subview's outer frame matches
/// that rect, so `GeometryReader` inside an `.overlay` reports the
/// panel size and the resize strip sits on the panel's actual edge.
struct DashboardCustomLayout: Layout {
    /// Grid frame for each panel, keyed by panel id. Computed by the
    /// caller using `DashboardGridLayout.frame(for:in:rowHeight:)`.
    let frames: [UUID: CGRect]

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxY = frames.values.map(\.maxY).max() ?? 0
        // Width is whatever the container offers; height grows with the
        // bottom-most panel so the surrounding ScrollView can overflow.
        return CGSize(
            width: proposal.width ?? frames.values.map(\.maxX).max() ?? 0,
            height: maxY
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for subview in subviews {
            guard let id = subview[PanelIDKey.self], let f = frames[id] else { continue }
            subview.place(
                at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: f.width, height: f.height)
            )
        }
    }
}

/// Layout value key used by `DashboardCustomLayout` to look up each
/// subview's grid frame. Attach via `.panelID(_:)` in the layout body.
private struct PanelIDKey: LayoutValueKey {
    static let defaultValue: UUID? = nil
}

extension View {
    /// Attach a panel id so `DashboardCustomLayout` can place this view
    /// at the panel's grid frame.
    func panelID(_ id: UUID) -> some View {
        layoutValue(key: PanelIDKey.self, value: id)
    }
}
