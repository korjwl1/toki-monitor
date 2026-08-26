import Foundation

/// Coordinates a single dashboard refresh: expands each panel into the queries
/// it declares, groups identical (query, datasource) pairs so they share one
/// round trip, executes the groups concurrently, and returns the per-panel
/// `PanelDataState`.
///
/// Was previously inlined into `DashboardViewModel.fetchData`. Splitting it out
/// turns resolve/group/execute logic into a pure function the VM calls — and
/// lets a test exercise the grouping + routing without an Observable / SwiftUI
/// / Timer surrounding it.
///
/// **Every refId runs** (contract Q5). It used to resolve one query per panel —
/// `targets.first`, or the first `queries` envelope — while the editor happily
/// accepted B, C, D and saved and exported them. A reader could write a second
/// query, watch the panel redraw, and believe they were looking at it. They
/// were looking at A.
///
/// Project-typed panels (`PanelMetric.tokensByProject`) need toki's special
/// `period: "<ts>|<project>"` parsing in local mode, which still lives on the
/// VM because it talks to `CLIProcessRunner` directly. This coordinator only
/// owns the regular path; the VM glues both together.
@MainActor
struct PanelFetchCoordinator {
    let datasourceRegistry: DatasourceRegistry

    init(datasourceRegistry: DatasourceRegistry = .shared) {
        self.datasourceRegistry = datasourceRegistry
    }

    /// One target of one panel: exactly what gets executed, with the query
    /// already interpolated.
    struct PlannedQuery: Equatable, Sendable {
        let panelID: UUID
        let refId: String
        let query: String
        let datasource: DatasourceSelector?
        /// Executed either way; excluded from what the panel renders.
        let hidden: Bool
        /// Whether the reader's ad hoc filters reached this query text
        /// (contract Q4). `QueryRewriter` returns the query untouched when it
        /// cannot find a selector to edit, so a panel can be showing unfiltered
        /// data while the toolbar shows a filter. Carried here so the result
        /// can say so.
        let appliedFilters: AppliedFilters

        var key: PanelQueryKey { PanelQueryKey(query: query, datasource: datasource) }
    }

    // MARK: - Planning

    /// Expand `panel` into its queries, in refId order.
    ///
    /// Three shapes, in precedence order, matching what the rest of the app
    /// treats as authoritative: Perses `queries` envelopes, legacy `targets`,
    /// and — for a panel that has neither — the metric's default query, which
    /// is what a freshly added panel runs before it has ever been edited.
    static func plan(for panel: PanelConfig,
                     time: TimeConfig,
                     variables: [DashboardVariable]) -> [PlannedQuery] {
        let sources = querySources(of: panel)
        return sources.enumerated().map { index, source in
            let template = source.query ?? source.metric.defaultQuery
            let resolved = VariableResolver.interpolateReporting(
                template: template, time: time, variables: variables
            )
            return PlannedQuery(
                panelID: panel.id,
                refId: source.refId ?? Self.refId(at: index),
                query: resolved.query,
                datasource: source.datasource ?? panel.effectiveDatasource,
                hidden: source.hidden,
                appliedFilters: resolved.appliedFilters
            )
        }
    }

    private struct QuerySource {
        var refId: String?
        var metric: PanelMetric
        var query: String?
        var datasource: DatasourceSelector?
        var hidden: Bool
    }

    private static func querySources(of panel: PanelConfig) -> [QuerySource] {
        let decoder = JSONDecoder()
        if let queries = panel.queries, !queries.isEmpty {
            return queries.map { q in
                let spec = q.spec.plugin.kind == BuiltinQueryPluginKind.tokiPromQLQuery
                    ? try? decoder.decode(TokiPromQLQuerySpec.self, from: q.spec.plugin.spec)
                    : nil
                return QuerySource(
                    refId: q.spec.name,
                    metric: spec?.metric ?? panel.metric,
                    query: spec?.query,
                    datasource: spec?.datasource,
                    hidden: spec?.hide ?? false
                )
            }
        }
        if !panel.targets.isEmpty {
            return panel.targets.map {
                QuerySource(refId: $0.refId, metric: $0.metric, query: $0.query,
                            datasource: nil, hidden: $0.hide)
            }
        }
        return [QuerySource(refId: "A", metric: panel.metric, query: nil,
                            datasource: nil, hidden: false)]
    }

    /// A..Z, then A again — the editor caps a panel at 26 queries, so the wrap
    /// is unreachable and exists only to keep this total.
    private static func refId(at index: Int) -> String {
        guard let scalar = UnicodeScalar(65 + (index % 26)) else { return "A" }
        return String(Character(scalar))
    }

    // MARK: - Fetching

    /// Fetch every panel in `panels`. Returns the resulting state map keyed by
    /// `panel.id`. Caller is responsible for writing the results back to its
    /// `panelData` dictionary.
    func fetchRegular(
        panels: [PanelConfig],
        time: TimeConfig,
        variables: [DashboardVariable],
        activeDatasource: DatasourceSelector,
        defaultClient: any QueryDataSource
    ) async -> [UUID: PanelDataState] {
        let plans: [UUID: [PlannedQuery]] = panels.reduce(into: [:]) { out, panel in
            out[panel.id] = Self.plan(for: panel, time: time, variables: variables)
        }

        // Group by (interpolated query, datasource). Two panels — or two
        // targets of one panel — with the same query but different per-query
        // datasource overrides hit different backends and cannot share a
        // round-trip.
        var pendingKeys: [PanelQueryKey] = []
        var seen = Set<PanelQueryKey>()
        for panel in panels {
            for planned in plans[panel.id] ?? [] where seen.insert(planned.key).inserted {
                pendingKeys.append(planned.key)
            }
        }

        let results = await execute(
            keys: pendingKeys, time: time,
            activeDatasource: activeDatasource, defaultClient: defaultClient
        )

        var out: [UUID: PanelDataState] = [:]
        for panel in panels {
            out[panel.id] = Self.assemble(plans[panel.id] ?? [], results: results)
        }
        return out
    }

    /// Run the distinct queries, at most `maxConcurrent` in flight.
    ///
    /// `LocalCLIDatasource` forks a `toki` subprocess per query, so an unbounded
    /// task group on a 50-panel dashboard would briefly spawn 50 processes and
    /// could thrash the system. 8 in flight matches typical CPU parallelism and
    /// keeps subprocess pressure bounded without serializing fast PromQL-proxy
    /// queries unnecessarily.
    private func execute(
        keys: [PanelQueryKey],
        time: TimeConfig,
        activeDatasource: DatasourceSelector,
        defaultClient: any QueryDataSource
    ) async -> [PanelQueryKey: Result<QueryResult, Error>] {
        let registry = datasourceRegistry
        let resolveClient: (PanelQueryKey) -> any QueryDataSource = { key in
            if let ds = key.datasource,
               ds != activeDatasource,
               let plugin = registry.resolve(ds) {
                return plugin
            }
            return defaultClient
        }
        var results: [PanelQueryKey: Result<QueryResult, Error>] = [:]
        let maxConcurrent = 8
        await withTaskGroup(of: (PanelQueryKey, Result<QueryResult, Error>).self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < keys.count else { return }
                let key = keys[nextIndex]
                nextIndex += 1
                let client = resolveClient(key)
                group.addTask {
                    do {
                        let result = try await client.queryPromQL(query: key.query, time: time)
                        return (key, .success(result))
                    } catch {
                        return (key, .failure(error))
                    }
                }
            }
            for _ in 0..<min(maxConcurrent, keys.count) { enqueueNext() }
            for await result in group {
                results[result.0] = result.1
                enqueueNext()
            }
        }
        return results
    }

    // MARK: - Assembly

    /// Fold one panel's query results into the state it renders.
    ///
    /// The rules are contract Q5's, and each exists because the alternative
    /// hides something:
    ///
    /// - A hidden target is executed and then left out of the render. It is not
    ///   skipped, because `hide` is a statement about the legend, not about
    ///   whether the query should run.
    /// - One target failing does not blank the others. The failure is carried
    ///   in `FrameSet.errors` under its refId, so the panel draws what it has
    ///   AND says which query did not answer.
    /// - Only when every visible target fails does the panel itself fail, and
    ///   then it fails with all the reasons rather than the first.
    static func assemble(_ plans: [PlannedQuery],
                         results: [PanelQueryKey: Result<QueryResult, Error>]) -> PanelDataState {
        let visible = plans.filter { !$0.hidden }
        // Nothing to draw because the reader hid everything: an empty result,
        // not a failure. A failure would claim the queries did not answer.
        guard !visible.isEmpty else {
            return .loaded(TimeSeriesData(points: [], granularity: .hourly), frames: FrameSet())
        }

        var frames: [Frame] = []
        var errors: [String: String] = [:]
        var legacySeries: TimeSeriesData?
        var succeeded = 0
        // Filters the reader set that this panel's queries could not be given.
        // Collected before anything is executed, because the fact does not
        // depend on the answer: a query that returns nothing, or fails, is
        // still a query the filter never reached (contract Q4).
        let filterNotices = Self.unappliedFilterNotices(visible)

        for planned in visible {
            switch results[planned.key] {
            case .success(let result):
                succeeded += 1
                // The datasource labels every frame it builds `A`; which query
                // in THIS panel produced it is known only here.
                frames += result.frames.frames.map { frame in
                    var tagged = frame
                    tagged.refId = planned.refId
                    return tagged
                }
                for (_, message) in result.frames.errors { errors[planned.refId] = message }
                // Renderers that still read the legacy shape get the first
                // visible query's series. Everything a second query produces
                // reaches the screen through frames; there is no honest way to
                // merge two arbitrary queries into one `TimeSeriesData`, and
                // summing them would invent a total nobody asked for.
                if legacySeries == nil { legacySeries = result.timeSeries }
            case .failure(let error):
                errors[planned.refId] = error.localizedDescription
            case nil:
                errors[planned.refId] = L.tr("실행되지 않았습니다.", "Was not executed.")
            }
        }

        guard succeeded > 0 else {
            // Every visible query failed — the panel has nothing, and says so
            // with each refId's own reason.
            let reasons = visible.compactMap { planned -> String? in
                guard let message = errors[planned.refId] else { return nil }
                return visible.count > 1 ? "\(planned.refId): \(message)" : message
            }
            return .error(reasons.joined(separator: "\n"))
        }

        return .loaded(
            legacySeries ?? TimeSeriesData(points: [], granularity: .hourly),
            frames: FrameSet(frames: frames, errors: errors, setNotices: filterNotices)
        )
    }

    /// One notice per query whose ad hoc filters did not land.
    ///
    /// `QueryRewriter` returns a query it cannot place a filter into unchanged
    /// — the right call, since a guessed edit yields a query that still parses
    /// and answers a different question. The consequence is a panel showing
    /// every project while the toolbar shows `project = toki`, and nothing but
    /// this saying so.
    ///
    /// The refId leads the line only when the panel has more than one visible
    /// query; on a one-query panel it would be noise.
    static func unappliedFilterNotices(_ visible: [PlannedQuery]) -> [String] {
        visible.compactMap { planned -> String? in
            guard planned.appliedFilters.hasUnapplied,
                  let reason = planned.appliedFilters.reason
            else { return nil }
            return visible.count > 1 ? "\(planned.refId): \(reason)" : reason
        }
    }
}

/// Grouping key used to batch queries that share both an interpolated PromQL
/// query *and* a datasource selector. Two queries with the same string but
/// different per-query datasources (Perses style) must hit different backends,
/// so they cannot share a group.
struct PanelQueryKey: Hashable, Sendable {
    let query: String
    let datasource: DatasourceSelector?
}
