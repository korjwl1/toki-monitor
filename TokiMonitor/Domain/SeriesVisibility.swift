import Foundation

// MARK: - Which series are hidden, and where that decision lives
//
// There used to be two filters on this dashboard that did not know about each
// other. Variables and ad hoc filters rewrite the QUERY: they change what is
// asked for, every panel narrows, and the change is visible in the executed
// query. The toolbar's model filter hid RENDERED SERIES: it changed nothing
// about the query and applied to whichever panels happened to read it.
//
// Two render-stage filters is how "I definitely switched it on and it is still
// not showing" happens — one control says the series is on, the other is what
// actually decides, and neither mentions the other. Contract R7 settles it:
// hiding a series is the legend's job and the legend's only, the query is not
// re-run, and the toolbar control is gone.
//
// This is the whole of the render-stage filter. It is per panel because a
// legend belongs to the chart it sits under: hiding `opus` on one panel is not
// a statement about every other panel, and the old filter's being global was
// most of why it surprised people.

/// The series a reader has hidden, per panel.
///
/// Hidden rather than shown on purpose. A panel's series list changes with
/// every refresh — a model that logged nothing this hour is simply absent — and
/// a list of what to SHOW would silently drop a series that came back, while a
/// list of what to hide leaves a returning series visible, which is what the
/// reader who never hid it expects.
struct SeriesVisibility: Equatable, Sendable {

    private var hiddenByPanel: [UUID: Set<String>] = [:]

    init() {}

    /// The hidden series of one panel. Empty — the usual case — draws
    /// everything.
    func hidden(for panelID: UUID) -> Set<String> {
        hiddenByPanel[panelID] ?? []
    }

    func isHidden(_ series: String, panelID: UUID) -> Bool {
        hiddenByPanel[panelID]?.contains(series) ?? false
    }

    /// Hide a shown series, or show a hidden one.
    mutating func toggle(_ series: String, panelID: UUID) {
        var set = hiddenByPanel[panelID] ?? []
        if set.remove(series) == nil { set.insert(series) }
        // An empty set is the default, so it is dropped rather than stored:
        // "nothing hidden here" and "this panel has never been touched" are the
        // same state and should compare equal.
        hiddenByPanel[panelID] = set.isEmpty ? nil : set
    }

    /// Show everything on one panel again.
    mutating func showAll(panelID: UUID) {
        hiddenByPanel[panelID] = nil
    }

    /// Whether any series is hidden on this panel — what a panel asks when it
    /// has to explain why it is empty.
    func hasHidden(panelID: UUID) -> Bool {
        !(hiddenByPanel[panelID]?.isEmpty ?? true)
    }

    var isEmpty: Bool { hiddenByPanel.isEmpty }
}
