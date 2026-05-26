import Foundation

/// Coordinates a single dashboard refresh: resolves each panel's typed
/// PromQL spec once, groups panels by (query, datasource), executes the
/// groups concurrently, and returns the per-panel `PanelDataState`.
///
/// Was previously inlined into `DashboardViewModel.fetchData`. Splitting
/// it out turns ~140 lines of resolve/group/execute logic into a pure
/// function the VM calls — and lets a test exercise the grouping +
/// routing logic without an Observable / SwiftUI / Timer surrounding it.
///
/// Project-typed panels (`PanelMetric.tokensByProject`) need toki's
/// special `period: "<ts>|<project>"` parsing in local mode, which still
/// lives on the VM because it talks to `CLIProcessRunner` directly. This
/// coordinator only owns the regular path; the VM glues both together.
@MainActor
struct PanelFetchCoordinator {
    let datasourceRegistry: DatasourceRegistry

    init(datasourceRegistry: DatasourceRegistry = .shared) {
        self.datasourceRegistry = datasourceRegistry
    }

    /// Fetch every panel in `panels`. Returns the resulting state map
    /// keyed by `panel.id`. Caller is responsible for writing the
    /// results back to its `panelData` dictionary.
    func fetchRegular(
        panels: [PanelConfig],
        time: TimeConfig,
        variables: [DashboardVariable],
        activeDatasource: DatasourceSelector,
        defaultClient: any QueryDataSource
    ) async -> [UUID: PanelDataState] {
        // Resolve each panel's typed PromQL spec exactly once. Calling
        // `panel.effective{Metric,Query,Datasource}` per panel × per
        // accessor JSON-decoded the same blob three times each.
        let resolved: [ResolvedPanel] = panels.map { panel in
            let spec = panel.resolvedTokiQuery
            return ResolvedPanel(
                panel: panel,
                queryString: spec?.query ?? panel.targets.first?.query,
                metric: spec?.metric ?? panel.targets.first?.metric ?? panel.metric,
                datasource: panel.effectiveDatasource
            )
        }

        // Group by (interpolated query, datasource). Two panels with the
        // same query but per-query datasource overrides hit different
        // backends and cannot share a network round-trip.
        var queryGroups: [PanelQueryKey: [PanelConfig]] = [:]
        for r in resolved {
            let template = r.queryString ?? r.metric.defaultQuery
            let interpolated = VariableResolver.interpolate(
                template: template, time: time, variables: variables
            )
            let key = PanelQueryKey(query: interpolated, datasource: r.datasource)
            queryGroups[key, default: []].append(r.panel)
        }

        // Execute concurrently, but cap in-flight tasks. `LocalCLIDatasource`
        // forks a `toki` subprocess per query, so an unbounded task group
        // on a 50-panel dashboard would briefly spawn 50 processes and
        // could thrash the system. 8 in flight matches typical CPU
        // parallelism and keeps subprocess pressure bounded without
        // serializing fast PromQL-proxy queries unnecessarily.
        let registry = datasourceRegistry
        let resolveClient: (PanelQueryKey) -> any QueryDataSource = { key in
            if let ds = key.datasource,
               ds != activeDatasource,
               let plugin = registry.resolve(ds) {
                return plugin
            }
            return defaultClient
        }
        var queryResults: [(PanelQueryKey, Result<TimeSeriesData, Error>)] = []
        let maxConcurrent = 8
        let pendingKeys = Array(queryGroups.keys)
        await withTaskGroup(of: (PanelQueryKey, Result<TimeSeriesData, Error>).self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < pendingKeys.count else { return }
                let key = pendingKeys[nextIndex]
                nextIndex += 1
                let client = resolveClient(key)
                group.addTask {
                    do {
                        let result = try await client.queryPromQLAsTimeSeries(query: key.query, time: time)
                        return (key, .success(result))
                    } catch {
                        return (key, .failure(error))
                    }
                }
            }
            for _ in 0..<min(maxConcurrent, pendingKeys.count) { enqueueNext() }
            for await result in group {
                queryResults.append(result)
                enqueueNext()
            }
        }

        // Project results back onto each contributing panel.
        var out: [UUID: PanelDataState] = [:]
        for (key, result) in queryResults {
            let affected = queryGroups[key] ?? []
            switch result {
            case .success(let data):
                for panel in affected { out[panel.id] = .loaded(data) }
            case .failure(let error):
                for panel in affected { out[panel.id] = .error(error.localizedDescription) }
            }
        }
        return out
    }

    struct ResolvedPanel {
        let panel: PanelConfig
        let queryString: String?
        let metric: PanelMetric
        let datasource: DatasourceSelector?
    }
}

/// Grouping key used to batch panels that share both an interpolated
/// PromQL query *and* a datasource selector. Two panels with the same
/// query string but different per-query datasources (Perses style) must
/// hit different backends, so they cannot share a group.
struct PanelQueryKey: Hashable, Sendable {
    let query: String
    let datasource: DatasourceSelector?
}
