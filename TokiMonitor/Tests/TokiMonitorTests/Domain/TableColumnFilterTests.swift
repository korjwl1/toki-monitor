import Testing
import Foundation
@testable import TokiMonitor

// MARK: - The table's view-time filter
//
// Contract R7 took the toolbar's model filter away and gave hiding to the
// legend. A table has no legend — there are no series to switch off, only
// rows — so it came out of that with no way to narrow itself at all. This is
// the replacement, in the shape Grafana gives a table: an editor marks a field
// filterable, a funnel appears in that column's header, and a READER uses it
// without entering edit mode.
//
// Two things have to hold, and they are the two R1 and R7 name. The setting
// must reach the render — a "Filterable" toggle that produced no funnel would
// be the exposed-but-not-honoured failure. And using it must not fetch.

@Suite("Table column filters")
@MainActor
struct TableColumnFilterTests {

    private func panel(filterable: Bool? = nil,
                       overrides: [FieldOverride] = []) -> PanelConfig {
        var panel = PanelConfig(
            title: "By model", panelType: .table, metric: .totalTokens,
            gridPosition: GridPosition(column: 0, row: 0, width: 12, height: 4)
        )
        if filterable != nil || !overrides.isEmpty {
            panel.fieldConfig = FieldConfigSource(
                defaults: FieldDisplayConfig(filterable: filterable),
                overrides: overrides
            )
        }
        return panel
    }

    private func rows(_ names: [String]) -> [PanelDataExtractor.ModelRow] {
        names.enumerated().map { index, name in
            PanelDataExtractor.ModelRow(id: name, model: name,
                                        tokens: UInt64((index + 1) * 1000),
                                        cost: Double(index + 1), events: index + 1)
        }
    }

    private var nameColumn: TablePanelView.Column {
        TablePanelView.specs.first { $0.kind == .name }!
    }

    private var tokensColumn: TablePanelView.Column {
        TablePanelView.specs.first { $0.kind == .tokens }!
    }

    // MARK: - The state

    @Test("nothing is excluded until something is excluded")
    func emptyByDefault() {
        let filters = TableColumnFilters()
        #expect(filters.isEmpty)
        #expect(filters.columns(panelID: UUID()).isEmpty)
        #expect(!filters.hasFilter(panelID: UUID()))
    }

    @Test("setting and clearing one column")
    func setAndClear() {
        let id = UUID()
        var filters = TableColumnFilters()
        filters.set(["opus"], panelID: id, column: "model")
        #expect(filters.isExcluded("opus", panelID: id, column: "model"))
        #expect(filters.hasFilter(panelID: id, column: "model"))
        #expect(!filters.hasFilter(panelID: id, column: "total_tokens"))

        filters.set([], panelID: id, column: "model")
        #expect(filters.isEmpty,
                "back to untouched, not to an empty set left behind")
    }

    /// The same reason `SeriesVisibility` is per panel: a filter is a statement
    /// about the table it sits in, not about every table on the dashboard.
    @Test("filtering one panel does not touch another")
    func perPanel() {
        let a = UUID(), b = UUID()
        var filters = TableColumnFilters()
        filters.set(["opus"], panelID: a, column: "model")
        #expect(filters.isExcluded("opus", panelID: a, column: "model"))
        #expect(!filters.isExcluded("opus", panelID: b, column: "model"))
    }

    @Test("clearing a panel leaves the rest alone")
    func clearOnePanel() {
        let a = UUID(), b = UUID()
        var filters = TableColumnFilters()
        filters.set(["opus"], panelID: a, column: "model")
        filters.set(["sonnet"], panelID: b, column: "model")
        filters.clear(panelID: a)
        #expect(!filters.hasFilter(panelID: a))
        #expect(filters.excluded(panelID: b, column: "model") == ["sonnet"])
    }

    @Test("toggling excludes, and toggling again brings it back")
    func toggleRoundTrip() {
        let id = UUID()
        var filters = TableColumnFilters()
        filters.toggle("opus", panelID: id, column: "model")
        #expect(filters.isExcluded("opus", panelID: id, column: "model"))
        filters.toggle("opus", panelID: id, column: "model")
        #expect(filters.isEmpty)
    }

    /// Excluded rather than included, for the reason `SeriesVisibility` is
    /// hidden rather than shown: a table's rows change with every refresh, and
    /// a list of what to SHOW would silently drop a model that first appeared
    /// this hour.
    @Test("a model that turns up after the filter was set is still shown")
    func newValuesAreNotSwallowed() {
        let p = panel()
        let out: [String: Set<String>] = ["model": ["opus"]]
        let visible = TablePanelView.visibleRows(
            panel: p, rows: rows(["opus", "sonnet", "gpt-5-newly-arrived"]), excluded: out
        )
        #expect(visible.map(\.model) == ["sonnet", "gpt-5-newly-arrived"])
    }

    // MARK: - What it does to the rows

    @Test("an excluded value drops its row")
    func excludedValueDropsRow() {
        let visible = TablePanelView.visibleRows(
            panel: panel(), rows: rows(["opus", "sonnet", "haiku"]),
            excluded: ["model": ["sonnet"]]
        )
        #expect(visible.map(\.model) == ["opus", "haiku"])
    }

    @Test("no filter draws every row")
    func noFilterDrawsEverything() {
        let all = rows(["opus", "sonnet"])
        #expect(TablePanelView.visibleRows(panel: panel(), rows: all, excluded: [:])
                    .map(\.model) == ["opus", "sonnet"])
    }

    /// Two filters narrow between them. A row that cleared one and not the
    /// other is still out — a second tick that WIDENED the result would be the
    /// opposite of what the reader asking for it means.
    @Test("filters on two columns are both applied")
    func twoColumnsCompose() {
        let p = panel()
        let all = rows(["opus", "sonnet", "haiku"])
        let tokens = TablePanelView.values(of: tokensColumn, panel: p, rows: all)
        let visible = TablePanelView.visibleRows(
            panel: p, rows: all,
            excluded: ["model": ["haiku"], "total_tokens": [tokens[0]]]
        )
        #expect(visible.map(\.model) == ["sonnet"])
    }

    @Test("excluding everything leaves no rows")
    func excludeEverything() {
        let all = rows(["opus", "sonnet"])
        let names = Set(TablePanelView.values(of: nameColumn, panel: panel(), rows: all))
        #expect(TablePanelView.visibleRows(panel: panel(), rows: all,
                                           excluded: ["model": names]).isEmpty,
                "which is what the table's own note explains, without hiding the funnel")
    }

    /// The filter is over what the column SHOWS. That is the only thing the
    /// reader can see, and it is what the popover offered them — so a unit
    /// override that turns a number into "$3.00" filters on "$3.00".
    @Test("the values offered are the values drawn, unit and all")
    func valuesAreTheDrawnText() {
        let p = panel(overrides: [
            FieldOverride(matcher: .byName("total_tokens"),
                          config: FieldDisplayConfig(unit: "currencyUSD", decimals: 2)),
        ])
        let all = rows(["opus", "sonnet"])
        let offered = TablePanelView.values(of: tokensColumn, panel: p, rows: all)
        #expect(offered.allSatisfy { $0.contains("$") },
                "the override reached the tick list: \(offered)")
        let visible = TablePanelView.visibleRows(panel: p, rows: all,
                                                 excluded: ["total_tokens": [offered[0]]])
        #expect(visible.map(\.model) == ["sonnet"],
                "and the same string matched the row it came from")
    }

    /// A filter left behind on a column the table no longer has must not
    /// silently empty it.
    @Test("a filter naming a column that is not there drops nothing")
    func unknownColumnIsInert() {
        let all = rows(["opus", "sonnet"])
        let visible = TablePanelView.visibleRows(panel: panel(), rows: all,
                                                 excluded: ["events": ["3"]])
        #expect(visible.count == 2)
    }

    // MARK: - Exposed only where it is honoured (계약 R1)

    @Test("the table option reaches the render, on every column")
    func defaultReachesTheRender() {
        let on = panel(filterable: true)
        #expect(TablePanelView.specs.allSatisfy { TablePanelView.isFilterable($0, panel: on) })
        let off = panel()
        #expect(TablePanelView.specs.allSatisfy { !TablePanelView.isFilterable($0, panel: off) })
    }

    /// The column holding the model names is the one a reader most wants to
    /// filter, and it is not a measure — so it needs a stand-in field of its
    /// own for a rule to name. Typed as a string, so `allNumeric` passes it by.
    @Test("the name column is filterable and is not numeric")
    func nameColumnHasItsOwnField() {
        #expect(nameColumn.field.name == "model")
        #expect(nameColumn.field.type == .string)
        #expect(!FieldMatcher.allNumeric.matches(nameColumn.field))
        #expect(FieldMatcher.byName("model").matches(nameColumn.field))
    }

    @Test("an override can exempt one column from a filterable table")
    func overrideExemptsOneColumn() {
        let p = panel(filterable: true, overrides: [
            FieldOverride(matcher: .byName("cost_usd"),
                          config: FieldDisplayConfig(filterable: false)),
        ])
        #expect(TablePanelView.isFilterable(nameColumn, panel: p))
        let cost = TablePanelView.specs.first { $0.kind == .cost }!
        #expect(!TablePanelView.isFilterable(cost, panel: p))
    }

    @Test("an override can make one column filterable on a table that is not")
    func overrideEnablesOneColumn() {
        let p = panel(overrides: [
            FieldOverride(matcher: .byName("model"),
                          config: FieldDisplayConfig(filterable: true)),
        ])
        #expect(TablePanelView.isFilterable(nameColumn, panel: p))
        #expect(!TablePanelView.isFilterable(tokensColumn, panel: p))
    }

    /// Set on a panel type with no columns, it must not reach the render at
    /// all — `honouring` is what stops it, and this is the assertion that the
    /// property list and the resolver agree.
    @Test("a filterable rule on a line chart resolves to nothing")
    func notHonouredElsewhere() {
        var p = panel(filterable: true)
        p.panelType = .timeSeries
        #expect(p.displayConfig(for: nameColumn.field).filterable == nil,
                "the rule stays in the document; it just does not reach a chart")
        #expect(p.fieldConfig?.defaults.filterable == true)
    }

    // MARK: - Save → load

    private func roundTrip(_ p: PanelConfig) throws -> PanelConfig {
        try JSONDecoder().decode(PanelConfig.self, from: JSONEncoder().encode(p))
    }

    private func encoded(_ p: PanelConfig) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any] ?? [:]
    }

    @Test("a filterable table is still filterable after a save and a load")
    func filterableRoundTrips() throws {
        let out = try roundTrip(panel(filterable: true, overrides: [
            FieldOverride(matcher: .byName("cost_usd"),
                          config: FieldDisplayConfig(filterable: false)),
        ]))
        #expect(out.fieldConfig?.defaults.filterable == true)
        #expect(out.fieldConfig?.overrides.first?.config.filterable == false)
        #expect(TablePanelView.isFilterable(nameColumn, panel: out))
    }

    /// Adding a property must not make every table written before it churn on
    /// the next save.
    @Test("a table nobody has filtered writes no filterable key")
    func absentWritesNothing() throws {
        #expect(try encoded(panel())["fieldConfig"] == nil)
        let withUnit = try encoded(panel(overrides: [
            FieldOverride(matcher: .allNumeric, config: FieldDisplayConfig(unit: "tokens")),
        ]))
        let config = withUnit["fieldConfig"] as? [String: Any]
        let rule = (config?["overrides"] as? [[String: Any]])?.first
        #expect((rule?["config"] as? [String: Any])?["filterable"] == nil,
                "a rule that says nothing about filtering writes nothing about it")
    }

    /// 계약 C1. A panel written by a newer build keeps the keys this one has no
    /// name for — and adding `filterable` must not have cost it that.
    @Test("keys from a newer build survive alongside a filterable table")
    func unknownKeysArePreserved() throws {
        var object = try encoded(panel(filterable: true))
        object["futurePanelSetting"] = ["depth": 2]
        let decoded = try JSONDecoder().decode(
            PanelConfig.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.fieldConfig?.defaults.filterable == true)
        #expect(decoded.unknownFields["futurePanelSetting"] == .object(["depth": .int(2)]))

        let again = try encoded(decoded)
        #expect((again["futurePanelSetting"] as? [String: Any])?["depth"] as? Int == 2)
    }

    // MARK: - It does not re-run the query

    /// The claim contract R7 makes about the legend, made about the funnel:
    /// narrowing a table is a decision about the drawing, and the rows are
    /// already here. Everything between the fetched frames and the drawn rows
    /// is pure, which is what this walks.
    @Test("filtering a column redraws from the frames already fetched")
    func filteringDoesNotRefetch() async throws {
        let client = SeriesVisibilityTests.CountingDatasource()
        var p = panel(filterable: true)
        p.targets = [PanelTarget(refId: "A", metric: .totalTokens, query: "usage[1h]")]
        let states = await PanelFetchCoordinator().fetchRegular(
            panels: [p], time: TimeConfig(), variables: [],
            activeDatasource: DatasourceSelector(kind: BuiltinDatasourceKind.localCLI),
            defaultClient: client
        )
        #expect(client.count == 1, "one query for one panel")
        let fetched = states[p.id]?.frames
        let all = PanelSeries.rows(panel: p, frames: fetched, data: nil)
        #expect(Set(all.map(\.model)) == ["opus", "sonnet"])

        // The reader ticks "opus" off in the column header.
        var filters = TableColumnFilters()
        filters.toggle("opus", panelID: p.id, column: "model")

        let visible = TablePanelView.visibleRows(
            panel: p, rows: all, excluded: filters.columns(panelID: p.id)
        )
        #expect(visible.map(\.model) == ["sonnet"])
        #expect(client.count == 1,
                "and nothing was asked of the backend to make that happen")
    }
}

// MARK: - Where there is deliberately no view-time filter
//
// Grafana lets a viewer narrow a time series, a bar chart and a pie from the
// legend, and a table from its column headers. It lets them narrow a stat card
// or a gauge from nowhere: which fields those show is an editor's choice
// (`Value options` → `Fields`), and there is no viewer-facing control at all.
//
// That is the right answer here too, and for a reason stronger than parity. A
// stat card and a gauge each reduce every series into ONE number. There is
// nothing on either to point at and switch off — hiding "opus" on a card
// showing total tokens would silently change the total, which is a different
// number rather than less of the same one. Narrowing those is a QUERY-stage
// question, and template variables and ad hoc filters are what answer it: they
// rewrite what is asked for, every panel narrows together, and the change is
// visible in the executed query.
//
// So nothing was built for them. This suite is what keeps that from silently
// becoming untrue — a later change that gives either type a hidden set, a
// filterable column or a legend has to come past these.

@Suite("Stat and gauge have no view-time filter")
@MainActor
struct StatAndGaugeFilterTests {

    private func panel(_ type: PanelType) -> PanelConfig {
        PanelConfig(title: "One number", panelType: type, metric: .totalTokens,
                    gridPosition: GridPosition(column: 0, row: 0, width: 6, height: 1))
    }

    /// The funnel is the table's, and only the table's.
    @Test("neither type offers a column filter", arguments: [PanelType.stat, .gauge])
    func noColumnFilter(type: PanelType) {
        #expect(!type.honouredFieldProperties.contains(.filterable))
        var p = panel(type)
        p.fieldConfig = FieldConfigSource(defaults: FieldDisplayConfig(filterable: true))
        // Written into the document by hand, or by another tool, it resolves to
        // nothing — so there is no state in which one of these draws a funnel.
        #expect(p.displayConfig(for: Field(name: "model", values: .string([])))
                    .filterable == nil)
    }

    /// Neither type names its series, which is what a legend entry would be.
    /// A card's name is its panel title.
    @Test("neither type names a series to put in a legend",
          arguments: [PanelType.stat, .gauge])
    func noSeriesNames(type: PanelType) {
        #expect(!type.honouredFieldProperties.contains(.displayName))
    }

    /// The empty state that says "everything is switched off, here is the way
    /// back" belongs to the types that have a control to get there with.
    /// Reaching it on a card would be a dead end: nothing on it can be clicked.
    @Test("neither type can reach the all-hidden empty state")
    func noAllHiddenState() {
        let fetch = PanelDataState.loaded(TimeSeriesData(points: [], granularity: .hourly),
                                          frames: FrameSet(frames: []))
        // `hasVisibleSeries` is what produces that state, and the dashboard
        // only ever passes anything but `true` for the types with a legend —
        // so a card and a dial resolve to `.loaded` and offer no way back from
        // a place they cannot get to.
        #expect(PanelState.resolve(fetch, hasContent: true) == .loaded)
        #expect(PanelState.loaded.offersShowAllSeries == false)
    }

    /// What DOES narrow them: a variable rewrites the query, so the panel is
    /// answering a different question rather than drawing less of the same
    /// answer. Visible in the executed query, which is the difference that
    /// matters.
    @Test("an ad hoc filter narrows a stat card, at the query stage")
    func adHocFiltersAreTheAnswer() {
        // The card's own stock query, so the claim is about a panel that
        // exists rather than about a string invented for the test.
        let query = PanelMetric.totalTokens.defaultQuery
        let rewritten = QueryRewriter.applying(
            [AdHocFilter(key: "model", value: "opus")], to: query
        )
        #expect(rewritten.contains("model=\"opus\""),
                "the narrowing is in the query the backend runs: \(rewritten)")
        #expect(rewritten != query,
                "which is the difference from a render-stage filter: the question changed")
    }
}
