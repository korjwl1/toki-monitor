import Testing
import Foundation
@testable import TokiMonitor

/// Panel repeat: one panel per variable value, and what happens when there is
/// no variable to repeat over.
///
/// The second half carries as much weight as the first. A repeat whose
/// variable has gone missing — renamed, deleted, or never present in an
/// imported dashboard — must draw the panel once. Drawing it zero times loses
/// a panel from the screen with nothing to say so, and a panel that is not
/// there cannot be told from a panel that was never made.
@Suite("Panel repeat")
struct PanelRepeatTests {

    // MARK: - Fixtures

    private func panel(_ title: String = "Tokens",
                       query: String? = "sum(usage{project=\"$project\"})",
                       repeatVariable: String? = nil,
                       direction: RepeatDirection? = nil,
                       at position: GridPosition = GridPosition(column: 0, row: 0,
                                                                width: 6, height: 4))
        -> PanelConfig {
        var p = PanelConfig(title: title, panelType: .timeSeries, metric: .totalTokens,
                            gridPosition: position)
        if let query {
            p.targets = [PanelTarget(refId: "A", metric: .totalTokens, query: query)]
        }
        p.repeat = repeatVariable
        p.repeatDirection = direction
        return p
    }

    private func multiVariable(_ name: String, values: [String],
                               selected: [String]? = nil) -> DashboardVariable {
        var v = DashboardVariable(name: name, type: .custom)
        v.multi = true
        v.options = values.map { VariableOption(text: $0, value: $0) }
        let chosen = selected ?? values
        v.current = VariableSelection(text: chosen, value: chosen)
        return v
    }

    // MARK: - Expansion

    @Test("a panel repeating over three values becomes three panels")
    func expandsPerValue() {
        let panels = [panel(repeatVariable: "project")]
        let variables = [multiVariable("project", values: ["toki", "sync", "monitor"])]
        let expanded = PanelRepeat.expand(panels, variables: variables)
        #expect(expanded.count == 3)
        #expect(expanded.map(\.repeatedValue) == ["toki", "sync", "monitor"])
    }

    @Test("each copy runs the query for its own value")
    func eachCopyInterpolatesItsValue() {
        let expanded = PanelRepeat.expand(
            [panel(repeatVariable: "project")],
            variables: [multiVariable("project", values: ["toki", "sync"])]
        )
        #expect(expanded[0].targets[0].query == "sum(usage{project=\"toki\"})")
        #expect(expanded[1].targets[0].query == "sum(usage{project=\"sync\"})")
    }

    @Test("a Perses query envelope is interpolated too, not only a legacy target")
    func envelopeQueryIsInterpolated() throws {
        var p = panel(query: nil, repeatVariable: "project")
        let spec = TokiPromQLQuerySpec(datasource: nil, metric: .totalTokens,
                                       query: "sum(usage{project=\"$project\"})", hide: false)
        p.queries = [Query(spec: QuerySpec(
            name: "A",
            plugin: QueryPluginRef(kind: BuiltinQueryPluginKind.tokiPromQLQuery,
                                   spec: try JSONEncoder().encode(spec))
        ))]
        let expanded = PanelRepeat.expand(
            [p], variables: [multiVariable("project", values: ["toki", "sync"])]
        )
        let queries = expanded.map { $0.resolvedTokiQuery?.query }
        #expect(queries == ["sum(usage{project=\"toki\"})", "sum(usage{project=\"sync\"})"])
    }

    @Test("the reader's selection decides the count, not the option list")
    func selectionDecidesCount() {
        let variable = multiVariable("project", values: ["toki", "sync", "monitor"],
                                     selected: ["toki", "monitor"])
        let expanded = PanelRepeat.expand([panel(repeatVariable: "project")],
                                          variables: [variable])
        #expect(expanded.map(\.repeatedValue) == ["toki", "monitor"])
    }

    @Test("All expands over every option when the variable offers All")
    func allExpandsOverEveryOption() {
        var variable = multiVariable("project", values: ["toki", "sync"], selected: ["$__all"])
        variable.includeAll = true
        let expanded = PanelRepeat.expand([panel(repeatVariable: "project")],
                                          variables: [variable])
        #expect(expanded.map(\.repeatedValue) == ["toki", "sync"])
    }

    @Test("a duplicated value is drawn once")
    func duplicateValuesCollapse() {
        let variable = multiVariable("project", values: ["toki", "toki", "sync"])
        let expanded = PanelRepeat.expand([panel(repeatVariable: "project")],
                                          variables: [variable])
        #expect(expanded.map(\.repeatedValue) == ["toki", "sync"])
    }

    // MARK: - Missing or empty variable (T051)

    @Test("a repeat naming a variable that does not exist draws one panel")
    func missingVariableFallsBackToOnePanel() {
        let expanded = PanelRepeat.expand(
            [panel(repeatVariable: "nosuchvariable")],
            variables: [multiVariable("project", values: ["toki"])]
        )
        #expect(expanded.count == 1, "the panel must not vanish")
        #expect(expanded[0].repeatedValue == nil, "it is the original, not an instance")
        #expect(expanded[0].targets[0].query == "sum(usage{project=\"$project\"})",
                "and it is left exactly as written")
    }

    @Test("a repeat over a variable with nothing selected draws one panel")
    func emptySelectionFallsBackToOnePanel() {
        var variable = multiVariable("project", values: ["toki", "sync"])
        variable.current = VariableSelection()
        let expanded = PanelRepeat.expand([panel(repeatVariable: "project")],
                                          variables: [variable])
        #expect(expanded.count == 1)
        #expect(expanded[0].repeatedValue == nil)
    }

    @Test("an empty repeat name is not a repeat")
    func emptyRepeatNameIsNoRepeat() {
        let expanded = PanelRepeat.expand([panel(repeatVariable: "")],
                                          variables: [multiVariable("project", values: ["a"])])
        #expect(expanded.count == 1)
        #expect(expanded[0].repeatedValue == nil)
    }

    @Test("a single-select variable repeats into exactly one panel")
    func singleSelectRepeatsOnce() {
        var variable = multiVariable("project", values: ["toki", "sync"])
        variable.multi = false
        let expanded = PanelRepeat.expand([panel(repeatVariable: "project")],
                                          variables: [variable])
        #expect(expanded.count == 1)
        #expect(expanded[0].repeatedValue == "toki")
    }

    @Test("panels without a repeat pass through untouched")
    func plainPanelsAreUntouched() {
        let plain = panel("Cost")
        let expanded = PanelRepeat.expand([plain], variables: [])
        #expect(expanded == [plain])
    }

    // MARK: - Identity

    @Test("the first copy keeps the stored panel's identity")
    func firstCopyKeepsIdentity() {
        let original = panel(repeatVariable: "project")
        let expanded = PanelRepeat.expand(
            [original], variables: [multiVariable("project", values: ["toki", "sync"])]
        )
        #expect(expanded[0].id == original.id)
        #expect(expanded[0].repeatSourceID == nil)
        #expect(expanded[1].id != original.id)
        #expect(expanded[1].repeatSourceID == original.id)
    }

    /// Panel data, loading state and SwiftUI view identity are all keyed by
    /// panel id. An id that changed between two refreshes would throw the
    /// result away and restart every animation on every pass.
    @Test("a copy's id is the same on every expansion")
    func copyIDsAreStable() {
        let panels = [panel(repeatVariable: "project")]
        let variables = [multiVariable("project", values: ["toki", "sync", "monitor"])]
        let first = PanelRepeat.expand(panels, variables: variables).map(\.id)
        let second = PanelRepeat.expand(panels, variables: variables).map(\.id)
        #expect(first == second)
    }

    @Test("two values do not collide onto one id")
    func copyIDsAreDistinct() {
        let base = UUID()
        let ids = ["toki", "sync", "monitor", "", "toki2"]
            .map { PanelRepeat.instanceID(of: base, value: $0) }
        #expect(Set(ids).count == ids.count)
    }

    // MARK: - Titles

    @Test("a title naming the variable gets the value where the author put it")
    func titleSubstitutesInPlace() {
        let expanded = PanelRepeat.expand(
            [panel("$project tokens", repeatVariable: "project")],
            variables: [multiVariable("project", values: ["toki", "sync"])]
        )
        #expect(expanded.map(\.title) == ["toki tokens", "sync tokens"])
    }

    @Test("a title that does not name the variable still tells the copies apart")
    func titleGetsTheValueAppended() {
        let expanded = PanelRepeat.expand(
            [panel("Tokens", repeatVariable: "project")],
            variables: [multiVariable("project", values: ["toki", "sync"])]
        )
        #expect(expanded.map(\.title) == ["Tokens · toki", "Tokens · sync"])
    }

    // MARK: - Layout

    @Test("horizontal copies run rightwards from the panel's own column")
    func horizontalLayout() {
        let placement = PanelRepeat.positions(
            for: GridPosition(column: 6, row: 2, width: 6, height: 4),
            count: 3, direction: .horizontal
        )
        #expect(placement.frames.map(\.column) == [6, 12, 18])
        #expect(placement.frames.map(\.row) == [2, 2, 2])
        #expect(placement.extraRows == 0)
    }

    @Test("horizontal copies wrap to a new band at the right edge")
    func horizontalWraps() {
        let placement = PanelRepeat.positions(
            for: GridPosition(column: 12, row: 0, width: 6, height: 4),
            count: 4, direction: .horizontal
        )
        #expect(placement.frames.map(\.column) == [12, 18, 12, 18])
        #expect(placement.frames.map(\.row) == [0, 0, 4, 4])
        #expect(placement.extraRows == 4)
    }

    @Test("vertical copies stack downwards")
    func verticalLayout() {
        let placement = PanelRepeat.positions(
            for: GridPosition(column: 0, row: 1, width: 24, height: 3),
            count: 3, direction: .vertical
        )
        #expect(placement.frames.map(\.row) == [1, 4, 7])
        #expect(placement.frames.allSatisfy { $0.column == 0 })
        #expect(placement.extraRows == 6)
    }

    /// Acceptance scenario US4.2 in the other direction: whatever the repeat
    /// grows to, the panels under it move down instead of being drawn over.
    @Test("what a repeat grows into pushes the panels below it down")
    func expansionPushesLaterPanelsDown() {
        let repeated = panel(repeatVariable: "project",
                             direction: .vertical,
                             at: GridPosition(column: 0, row: 0, width: 12, height: 4))
        let below = panel("Below", at: GridPosition(column: 0, row: 4, width: 12, height: 4))
        let expanded = PanelRepeat.expand(
            [repeated, below],
            variables: [multiVariable("project", values: ["toki", "sync", "monitor"])]
        )
        #expect(expanded.count == 4)
        #expect(expanded.map(\.gridPosition.row) == [0, 4, 8, 12])
        #expect(expanded.last?.title == "Below")
    }

    @Test("one panel is placed exactly where it was stored")
    func singleCopyKeepsItsPosition() {
        let origin = GridPosition(column: 6, row: 3, width: 6, height: 4)
        let placement = PanelRepeat.positions(for: origin, count: 1, direction: .horizontal)
        #expect(placement.frames == [origin])
        #expect(placement.extraRows == 0)
    }

    // MARK: - Round trip

    @Test("repeat survives a save and a load")
    func repeatRoundTrips() throws {
        var p = panel(repeatVariable: "project", direction: .vertical)
        p.repeatedValue = "toki"
        p.repeatSourceID = UUID()
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(PanelConfig.self, from: data)
        #expect(back.repeat == "project")
        #expect(back.repeatDirection == .vertical)
        // Derived state is not written: how many copies there are is a fact
        // about the reader's current selection, not about the dashboard.
        #expect(back.repeatedValue == nil)
        #expect(back.repeatSourceID == nil)
    }

    @Test("a panel with no repeat writes no repeat keys")
    func noRepeatKeysWhenUnset() throws {
        let data = try JSONEncoder().encode(panel())
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"repeat\""))
        #expect(!json.contains("repeatDirection"))
    }
}
