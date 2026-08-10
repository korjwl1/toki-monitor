import Testing
import Foundation
@testable import TokiMonitor

/// Ad hoc is the one kind that is not opt-in. Every other variable appears in
/// a query because the author wrote `$name`; this one narrows panels that were
/// written before it existed. These tests pin where it applies and where it
/// deliberately does not.
@Suite("Ad hoc filter variable")
struct AdHocVariableTests {

    private func adHoc(_ filters: [AdHocFilter]) -> DashboardVariable {
        var v = DashboardVariable(name: "filters", type: .custom)
        v.plugin = VariablePluginRef(kind: BuiltinVariablePluginKind.adHoc, spec: Data())
        v.adHocFilters = filters
        return v
    }

    private func interpolate(_ template: String, _ vars: [DashboardVariable]) -> String {
        VariableResolver.interpolate(template: template, time: TimeConfig(), variables: vars)
    }

    @Test("a filter reaches a query that never mentions it")
    func appliesWithoutBeingReferenced() {
        let v = adHoc([AdHocFilter(key: "project", op: .equals, value: "toki")])
        #expect(interpolate("sum(toki_tokens_total[1h]) by (model)", [v])
                == "sum(toki_tokens_total{project=\"toki\"}[1h]) by (model)")
    }

    @Test("filters from several ad hoc variables all apply")
    func severalVariables() {
        let a = adHoc([AdHocFilter(key: "project", op: .equals, value: "toki")])
        let b = adHoc([AdHocFilter(key: "model", op: .matches, value: "opus.*")])
        let out = interpolate("usage[1h]", [a, b])
        #expect(out.contains("project=\"toki\""))
        #expect(out.contains("model=~\"opus.*\""))
    }

    @Test("no filters leaves the query byte-identical")
    func noFiltersNoChange() {
        #expect(interpolate("sum(usage[1h])", [adHoc([])]) == "sum(usage[1h])")
        var empty = adHoc([])
        empty.adHocFilters = nil
        #expect(interpolate("sum(usage[1h])", [empty]) == "sum(usage[1h])")
    }

    /// A dashboard with no ad hoc variable must not pay for the feature.
    @Test("other variable kinds contribute no filters")
    func otherKindsAreNotAdHoc() {
        var list = DashboardVariable(name: "m", type: .custom)
        list.plugin = VariablePluginRef(kind: BuiltinVariablePluginKind.staticList, spec: Data())
        list.adHocFilters = [AdHocFilter(key: "x", op: .equals, value: "y")]
        #expect(VariableResolver.adHocFilters(in: [list]).isEmpty,
                "the filters field only means anything on an ad hoc variable")
        #expect(interpolate("usage[1h]", [list]) == "usage[1h]")
    }

    /// Applied after substitution: the reader typed a value into a filter box,
    /// not a template, so `$` in it is a character.
    @Test("a filter value is a value, not a template")
    func filterValueIsNotATemplate() {
        var other = DashboardVariable(name: "env", type: .custom)
        other.current = VariableSelection(text: ["prod"], value: ["prod"])
        let v = adHoc([AdHocFilter(key: "project", op: .equals, value: "$env")])
        let out = interpolate("usage[1h]", [v, other])
        #expect(out.contains("project=\"$env\""), "not substituted to prod")
    }

    /// The filters are the reader's session state; they persist with the
    /// dashboard, so they have to survive a round-trip.
    @Test("filters round-trip through the dashboard's own encoding")
    func roundTrips() throws {
        let v = adHoc([AdHocFilter(key: "project", op: .notMatches, value: "test.*")])
        var config = DashboardConfig()
        config.templating.list = [v]
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DashboardConfig.self, from: data)
        let restored = try #require(decoded.templating.list.first?.adHocFilters?.first)
        #expect(restored.key == "project")
        #expect(restored.op == .notMatches)
        #expect(restored.value == "test.*")
    }

    /// Existing dashboards predate the field entirely.
    @Test("a dashboard without the field decodes and stays unfiltered")
    func absentFieldDecodes() throws {
        let json = """
        {"name":"v","type":"custom","query":"","current":{"text":[],"value":[]},
         "options":[],"multi":false,"includeAll":false,"hide":0,"refresh":1,
         "id":"\(UUID().uuidString)"}
        """
        let v = try JSONDecoder().decode(DashboardVariable.self, from: Data(json.utf8))
        #expect(v.adHocFilters == nil)
        #expect(VariableResolver.adHocFilters(in: [v]).isEmpty)
    }
}
