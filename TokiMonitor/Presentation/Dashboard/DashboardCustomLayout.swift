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
    /// Cached extents derived from `frames`. Recomputing `maxX` / `maxY`
    /// from a `[UUID: CGRect]` per pass costs O(panels) work that the
    /// `Layout` protocol's cache slot exists to amortize — drag-induced
    /// reflows can run this many times per second on a busy dashboard.
    struct Cache {
        let maxX: CGFloat
        let maxY: CGFloat
    }

    /// Grid frame for each panel, keyed by panel id. Computed by the
    /// caller using `DashboardGridLayout.frame(for:in:rowHeight:)`.
    let frames: [UUID: CGRect]

    func makeCache(subviews: Subviews) -> Cache {
        Cache(
            maxX: frames.values.map(\.maxX).max() ?? 0,
            maxY: frames.values.map(\.maxY).max() ?? 0
        )
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        // Width respects the container's proposal so the layout shrinks
        // gracefully if the parent constrains us; falls back to the
        // panel grid's intrinsic right edge otherwise. Height grows with
        // the bottom-most panel, but is also capped by `proposal.height`
        // when one is given — without the cap, embedding this layout
        // outside the dashboard's ScrollView (snapshot tests, previews)
        // overflows the proposed container.
        let intrinsicWidth = proposal.width ?? cache.maxX
        let intrinsicHeight = cache.maxY
        let height: CGFloat
        if let proposedHeight = proposal.height, proposedHeight.isFinite {
            height = min(intrinsicHeight, proposedHeight)
        } else {
            height = intrinsicHeight
        }
        return CGSize(width: intrinsicWidth, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        for subview in subviews {
            guard let id = subview[PanelIDKey.self] else {
                #if DEBUG
                assertionFailure("Subview in DashboardCustomLayout is missing `.panelID(_:)`")
                #endif
                continue
            }
            guard let f = frames[id] else { continue }
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
