import Testing
import Foundation
@testable import TokiMonitor

/// `normalizePanel` rebuilds the Perses `queries` envelope from the legacy
/// `targets` array whenever it detects drift. `PanelTarget` has no datasource
/// field, so the rebuild used to write `datasource: nil` — silently erasing a
/// per-query datasource override every time an unrelated field was edited.
@Suite("Panel normalization preserves per-query datasource")
@MainActor
struct PanelNormalizationTests {

    private func panelWithDatasource(_ selector: DatasourceSelector) -> PanelConfig {
        var panel = PanelConfig(
            title: "p", panelType: .timeSeries, metric: .tokensByModel,
            gridPosition: GridPosition(column: 0, row: 0, width: 12, height: 3)
        )
        panel.targets = [PanelTarget(refId: "A", metric: .tokensByModel)]
        let spec = TokiPromQLQuerySpec(datasource: selector, metric: .tokensByModel, query: nil)
        panel.queries = [Query(
            kind: BuiltinQueryKind.timeSeriesQuery,
            spec: QuerySpec(
                name: "A",
                plugin: QueryPluginRef(
                    kind: BuiltinQueryPluginKind.tokiPromQLQuery,
                    spec: (try? JSONEncoder().encode(spec)) ?? Data()
                )
            )
        )]
        return panel
    }

    private func datasource(of panel: PanelConfig) -> DatasourceSelector? {
        guard let q = panel.queries?.first,
              let spec = try? JSONDecoder().decode(
                  TokiPromQLQuerySpec.self, from: q.spec.plugin.spec)
        else { return nil }
        return spec.datasource
    }

    @Test("editing an unrelated field does not erase the datasource override")
    func datasourceSurvivesRebuild() {
        let selector = DatasourceSelector(kind: "toki", name: "server")
        var panel = panelWithDatasource(selector)
        #expect(datasource(of: panel) == selector)

        // Edit the PromQL text — this is what triggers the rebuild.
        panel.targets[0].query = "sum(toki_tokens_total[1h])"
        DashboardViewModel.normalizePanel(&panel)

        #expect(datasource(of: panel) == selector,
                "the per-query datasource must survive a targets-driven rebuild")
        // And the edit itself must land.
        #expect(panel.resolvedTokiQuery?.query == "sum(toki_tokens_total[1h])")
    }

    @Test("a panel with no datasource override stays nil rather than inventing one")
    func absentDatasourceStaysAbsent() {
        var panel = PanelConfig(
            title: "p", panelType: .stat, metric: .totalTokens,
            gridPosition: GridPosition(column: 0, row: 0, width: 6, height: 1)
        )
        panel.targets = [PanelTarget(refId: "A", metric: .totalTokens)]
        DashboardViewModel.normalizePanel(&panel)
        #expect(datasource(of: panel) == nil)
    }
}

/// Renderers consume the LEGACY `options`, so a stale `plugin.spec` is not a
/// display bug — it is an EXPORT bug: the shared JSON describes a panel the
/// user is not looking at.
@Suite("Panel plugin spec tracks options")
@MainActor
struct PanelPluginSpecTests {

    @Test("editing options that keep the same visualization updates the exported spec")
    func specFollowsOptions() throws {
        var panel = PanelConfig(
            title: "p", panelType: .timeSeries, metric: .tokensByModel,
            gridPosition: GridPosition(column: 0, row: 0, width: 12, height: 3)
        )
        DashboardViewModel.normalizePanel(&panel)
        let before = try #require(panel.plugin?.spec)

        panel.options.lineWidth = (panel.options.lineWidth == 4) ? 2 : 4
        DashboardViewModel.normalizePanel(&panel)
        let after = try #require(panel.plugin?.spec)

        #expect(after != before,
                "the exported plugin spec must not keep describing the old options")
        #expect(panel.plugin?.kind == BuiltinPanelPluginKind.kind(for: .timeSeries))
    }

    @Test("normalizing twice with no edit in between is stable")
    func normalizationIsIdempotent() throws {
        var panel = PanelConfig(
            title: "p", panelType: .stat, metric: .totalTokens,
            gridPosition: GridPosition(column: 0, row: 0, width: 6, height: 1)
        )
        DashboardViewModel.normalizePanel(&panel)
        let first = try #require(panel.plugin?.spec)
        DashboardViewModel.normalizePanel(&panel)
        #expect(panel.plugin?.spec == first, "no edit must produce no churn")
    }
}

/// A dashboard's identity is its UID. Matching on title as well meant an edit
/// could overwrite a DIFFERENT dashboard that happened to share a name — which
/// a rename or an import can produce, since neither enforces uniqueness after
/// creation.
@Suite("Dashboard identity is the UID")
@MainActor
struct DashboardIdentityTests {

    @Test("import surfaces a reason instead of looking like a cancel")
    func importErrorIsDescribed() throws {
        // Valid JSON, wrong shape for a dashboard.
        let data = try #require(#"{"title": 42}"#.data(using: .utf8))
        #expect(throws: (any Error).self) {
            _ = try DashboardConfig.importJSON(data)
        }
    }

    @Test("a well-formed export round-trips and takes a fresh identity")
    func exportRoundTrips() throws {
        var original = DashboardConfig(title: "Shared")
        original.panels = [PanelConfig(
            title: "p", panelType: .stat, metric: .totalTokens,
            gridPosition: GridPosition(column: 0, row: 0, width: 6, height: 1)
        )]
        let json = try original.exportJSONString()
        let imported = try DashboardConfig.importJSONString(json)

        #expect(imported.title == original.title)
        #expect(imported.panels.count == 1)
        // Import must not adopt the source's identity, or updating one would
        // silently rewrite the other.
        #expect(imported.uid != original.uid)
        #expect(imported.id != original.id)
    }
}
