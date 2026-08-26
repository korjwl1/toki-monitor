import Foundation

// MARK: - What a reader has filtered out of a table column
//
// The table is the one panel type with no legend, and after contract R7 removed
// the toolbar's model filter it had no way to narrow itself at view time at all.
// Grafana's answer for a table is not a legend — tables do not have one — it is
// a per-column filter: an editor marks a field "filterable", a funnel appears in
// that column's header, and a READER uses it without entering edit mode.
//
// This is the reader's half of that: which values a column is currently leaving
// out. It sits beside `SeriesVisibility` and works the same way on purpose —
// same stage (render, never the query), same scope (one panel), same lifetime
// (a glance, not a property of the dashboard). Two view-time filters that do not
// know about each other is the failure R7 exists to prevent, so these two are
// deliberately disjoint: a legend hides a SERIES on a chart, a column filter
// excludes a VALUE from a table, and no panel type has both.

/// Values a reader has excluded, per panel and per column.
///
/// Excluded rather than included, for the same reason `SeriesVisibility` is
/// hidden rather than shown: a table's rows change with every refresh. A list of
/// what to SHOW would silently drop a model that first appeared this hour; a
/// list of what to LEAVE OUT lets it through, which is what a reader who has
/// never heard of it expects.
///
/// The values are the ones the column DISPLAYS — the formatted cell text, not
/// the underlying number. That is what the reader ticked in the popover, and it
/// is the only thing they can see. Two raw values that format identically are
/// therefore excluded together, which is the same answer the screen gives.
struct TableColumnFilters: Equatable, Sendable {

    private var excludedByPanel: [UUID: [String: Set<String>]] = [:]

    init() {}

    /// Every column filter on one panel, keyed by column. Empty — the usual
    /// case — draws every row.
    func columns(panelID: UUID) -> [String: Set<String>] {
        excludedByPanel[panelID] ?? [:]
    }

    func excluded(panelID: UUID, column: String) -> Set<String> {
        excludedByPanel[panelID]?[column] ?? []
    }

    func isExcluded(_ value: String, panelID: UUID, column: String) -> Bool {
        excludedByPanel[panelID]?[column]?.contains(value) ?? false
    }

    /// Replace one column's exclusions wholesale.
    ///
    /// One setter rather than toggle/clear/invert because the popover already
    /// knows the whole set it wants — a tick, "select all" and "clear" are all
    /// the same edit from here, and splitting them would be three chances for
    /// the stored set and the ticks on screen to disagree.
    mutating func set(_ values: Set<String>, panelID: UUID, column: String) {
        var byColumn = excludedByPanel[panelID] ?? [:]
        // An empty set is the default, so it is dropped rather than stored:
        // "nothing excluded here" and "this column was never touched" are the
        // same state and should compare equal.
        byColumn[column] = values.isEmpty ? nil : values
        excludedByPanel[panelID] = byColumn.isEmpty ? nil : byColumn
    }

    mutating func toggle(_ value: String, panelID: UUID, column: String) {
        var set = excluded(panelID: panelID, column: column)
        if set.remove(value) == nil { set.insert(value) }
        self.set(set, panelID: panelID, column: column)
    }

    /// Show every row of this panel again.
    mutating func clear(panelID: UUID) {
        excludedByPanel[panelID] = nil
    }

    /// Whether this column is leaving anything out — what the header asks when
    /// it decides whether to draw the funnel filled.
    func hasFilter(panelID: UUID, column: String) -> Bool {
        !excluded(panelID: panelID, column: column).isEmpty
    }

    /// Whether any column on this panel is leaving anything out.
    func hasFilter(panelID: UUID) -> Bool {
        !(excludedByPanel[panelID]?.isEmpty ?? true)
    }

    var isEmpty: Bool { excludedByPanel.isEmpty }

    // MARK: - Applying it

    /// Keep the rows no column excludes.
    ///
    /// `cell` gives the displayed text of one column of one row — the same
    /// string the table draws and the same string the popover offered. Passed in
    /// rather than computed here because formatting is the panel's job: the unit
    /// and decimals a column shows are resolved from its field config, and a
    /// second formatting path here is a second chance to disagree with the
    /// screen.
    ///
    /// A row must clear EVERY column's filter, not any of them. Two filters that
    /// widened the result between them would be the opposite of what a reader
    /// ticking a second box is asking for.
    static func rows<Row>(_ rows: [Row], excluded: [String: Set<String>],
                          cell: (Row, String) -> String) -> [Row] {
        guard !excluded.isEmpty else { return rows }
        return rows.filter { row in
            excluded.allSatisfy { column, values in
                !values.contains(cell(row, column))
            }
        }
    }
}
