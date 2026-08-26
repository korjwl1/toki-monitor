import Foundation

// MARK: - What a panel says to assistive technology
//
// FR-063: a panel must give a screen reader its title, its kind, its current
// state and its key value. Before this, `accessibilityLabel` appeared four
// times in the whole dashboard and three of them were badges — a VoiceOver
// reader moving across the grid heard the panel titles and nothing else, so a
// panel that had failed and a panel showing 1.2M tokens were both just a name.
//
// The composition lives here, apart from the views, for two reasons. It is a
// product decision about what gets said and in which order, which a test can
// pin without rendering anything; and every panel type has to say the same
// four things in the same order, which two implementations would not keep up.

/// The sentence a panel announces.
enum PanelAccessibility {

    /// Compose what assistive technology reads for one panel.
    ///
    /// - Parameters:
    ///   - title: the panel's own title, first because it is what the reader
    ///     is navigating by.
    ///   - typeName: what kind of panel it is, localized — "Time Series",
    ///     "Gauge". A reader who cannot see the render has no other way to know
    ///     whether "1.2M" is a lone number or the end of a line.
    ///   - state: what the panel is showing. `nil` for a panel that has no
    ///     query state — a row header — and is therefore only a name and a kind.
    ///   - value: the panel's key value, already formatted by whichever render
    ///     owns it. `nil` when there is nothing to say, which is every state
    ///     except `.loaded` and a held-over `.loading`.
    ///
    /// Order: identity, then state, then value. A reader who moves on after the
    /// first phrase still learns which panel they are on; one who waits for the
    /// second learns whether to trust what follows.
    static func announcement(title: String, typeName: String,
                             state: PanelState?, value: String?,
                             timeOverride: String? = nil) -> String {
        var parts: [String] = ["\(title), \(typeName)"]
        // Before the state and before the value, because it changes what both
        // of them MEAN. "No data in this range" is a different sentence when
        // the range is not the one the toolbar shows, and a reader who hears
        // the qualifier afterwards has already drawn the wrong conclusion.
        if let timeOverride, !timeOverride.isEmpty {
            parts.append(L.tr("대시보드와 다른 시간 범위: \(timeOverride)",
                              "on a different time range: \(timeOverride)"))
        }
        if let state {
            // `.loaded` names no state. The value IS the state — a panel that
            // speaks a number has plainly loaded — and "Result." between the
            // title and the number is a word every panel on the dashboard
            // would repeat for nothing. Every other state names itself,
            // because in every other state the silence would otherwise be the
            // only difference between "empty", "still loading" and "broken".
            if case .loaded = state {} else {
                parts.append(state.accessibilityDescription)
            }
        }
        if let value, !value.isEmpty {
            parts.append(value)
        }
        return parts.joined(separator: ". ")
    }

    /// The hint attached to a panel: what a reader can do from here.
    ///
    /// Only the actions that exist on this panel are named. A hint that offers
    /// an edit on a panel with no editor is worse than no hint.
    static func hint(canInspect: Bool, canEdit: Bool, canDelete: Bool) -> String? {
        var actions: [String] = []
        if canInspect { actions.append(L.tr("검사", "Inspect")) }
        if canEdit { actions.append(L.tr("편집", "Edit")) }
        if canDelete { actions.append(L.tr("삭제", "Delete")) }
        guard !actions.isEmpty else { return nil }
        return L.tr("사용 가능한 동작: \(actions.joined(separator: ", "))",
                    "Available actions: \(actions.joined(separator: ", "))")
    }
}
