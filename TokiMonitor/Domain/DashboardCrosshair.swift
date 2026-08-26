import Foundation
import Observation

// MARK: - One instant, read across every time chart on the dashboard
//
// Each time series panel tracked its own hover and drew its own rule. That
// answers "what is this line worth here" and not the question a dashboard
// exists to answer — "what were the OTHER panels doing at that moment" — which
// a reader can otherwise only get by eye, across two charts whose x axes are
// the same range at different pixel widths.
//
// Shared state, deliberately tiny and deliberately not on `DashboardViewModel`:
// constructing one of those writes the developer's real dashboard file (see
// `PanelSnapshotHarness`), so anything a test needs to exercise has to be
// constructible on its own.

/// Where the reader is pointing, in dashboard time.
@MainActor
@Observable
final class DashboardCrosshair {

    /// The instant every time chart draws its rule at, or nil when the cursor
    /// is not over one.
    private(set) var date: Date?

    /// Which panel the cursor is actually in.
    ///
    /// The rule is shared; the TOOLTIP is not. A tooltip on every panel at once
    /// would cover the very charts the shared rule exists to let the reader
    /// compare, and only one of them is under the cursor to be dismissed.
    private(set) var ownerPanelID: UUID?

    init() {}

    /// The cursor moved to `date` inside `panelID`.
    func move(to date: Date, panelID: UUID?) {
        self.date = date
        self.ownerPanelID = panelID
    }

    /// The cursor left `panelID`.
    ///
    /// Only the owner may clear it. Two panels side by side both see the
    /// pointer leave as it crosses between them, and letting the one being
    /// LEFT clear the crosshair would blank the rule the one being entered has
    /// just set.
    func clear(panelID: UUID?) {
        guard ownerPanelID == panelID else { return }
        date = nil
        ownerPanelID = nil
    }

    /// Whether this panel is the one under the cursor.
    func isOwner(_ panelID: UUID?) -> Bool {
        guard let ownerPanelID else { return false }
        return ownerPanelID == panelID
    }

    /// Whether this panel should draw the shared rule: whenever there is one.
    /// A panel with no id of its own — the editor's preview — follows too, so
    /// the preview and the dashboard behind it do not disagree.
    var isActive: Bool { date != nil }
}
