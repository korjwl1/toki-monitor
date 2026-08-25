import Foundation
import SwiftUI
import Combine

@MainActor
@Observable
final class DashboardViewModel {
    // MARK: - Dashboard Config
    var dashboardConfig: DashboardConfig
    var isEditing = false

    // MARK: - Multi-dashboard
    var dashboardList: [DashboardConfig] = []

    // MARK: - Sidebar
    var showSidebar = true
    var sidebarSearchText = ""
    var isEditingDashboardList = false

    // MARK: - Row collapse state (by panel ID)
    var collapsedRows: Set<UUID> = []

    // MARK: - Time & Refresh
    var timeConfig: TimeConfig {
        get { dashboardConfig.time }
        set {
            dashboardConfig.time = newValue
            saveDashboard()
            // Variables with `.onTimeRangeChanged` reload their option set
            // before the panel fetch so the new time window's labels are
            // available to subsequent query interpolation.
            refreshVariables(onTimeRangeChange: true)
            fetchData()
        }
    }

    var refreshInterval: RefreshInterval {
        get { dashboardConfig.refresh }
        set {
            dashboardConfig.refresh = newValue
            saveDashboard()
            setupAutoRefresh()
        }
    }

    // MARK: - Variables
    var variables: [DashboardVariable] {
        get { dashboardConfig.templating.list }
        set {
            dashboardConfig.templating.list = newValue
            saveDashboard()
            fetchData()
        }
    }

    // MARK: - Data State
    var timeSeriesData: TimeSeriesData?
    var dataVersion: Int = 0
    var isLoading = false
    var errorMessage: String?
    var enabledModels: Set<String> = []
    var panelData: [UUID: PanelDataState] = [:]

    /// Labels a variable's own query returned, keyed by variable id. The
    /// editor offers these instead of a hard-coded list, which could name a
    /// label the query never produces — the user then gets an empty dropdown
    /// and nothing to explain it.
    var discoveredLabelKeys: [UUID: [String]] = [:]

    /// For an ad hoc variable: which labels its query returned and which
    /// values each one takes. The reader picks a key and then a value, so a
    /// flat list would not do — a value must only be offered under the key it
    /// actually belongs to.
    var adHocKeyValues: [UUID: [String: [String]]] = [:]

    // MARK: - Annotations
    var annotations: [DashboardAnnotation] = []

// MARK: - Version Store
    let versionStore = DashboardVersionStore()

// MARK: - Explore
    var exploreQuery = ""
    /// The result as frames. Explore used to hold a `TimeSeriesData`, which
    /// carries one series name and fixed measure columns — so a query grouped
    /// by two dimensions arrived flattened and a query returning a column the
    /// legacy shape has no slot for arrived empty. Frames are what every panel
    /// reads; Explore reads the same thing (contract Q5 / data-model Frame).
    var exploreFrames: FrameSet?
    /// The query actually sent, after interpolation — what a promoted panel
    /// should carry, and what Inspect would show.
    var exploreExecutedQuery: String?
    /// Why the last run produced nothing. Explore used to set the result to
    /// `nil` on failure, which draws the same "enter a query" screen as never
    /// having run one: a rejected query looked like an idle Explore
    /// (contract Q2).
    var exploreError: String?
    /// Whether that error was the backend refusing the query rather than the
    /// transport failing. A refusal is fixed by editing; retrying it unchanged
    /// fails identically.
    var exploreErrorIsRefusal = false
    /// What the selected backend is expected to make of the query, before it
    /// is sent (contract Q3).
    var exploreValidation: QueryValidation?
    /// Explore's OWN time range. Sharing the dashboard's meant trying a query
    /// over a wider window silently moved every panel behind it, and narrowing
    /// the dashboard silently re-scoped the experiment.
    var exploreTime = TimeConfig(from: "now-6h", to: "now")
    var exploreQueryHistory: [ExploreQueryEntry] = []
    var isExploreLoading = false

    // MARK: - Auto-refresh
    private var refreshTimer: Timer?
    private var fetchTask: Task<Void, Never>?
    private var variableRefreshTask: Task<Void, Never>?
    private var exploreTask: Task<Void, Never>?

    // MARK: - Dependencies
    let reportClient: TokiReportClient
    private let serverQueryClient: ServerQueryClient
    /// Active query client, swapped when `dataSource` changes.
    private var queryClient: any QueryDataSource
    private let configStore = DashboardConfigStore()
    private let annotationStore = AnnotationStore()
    // Singletons-as-DI: defaults to `.shared` so existing call sites still
    // work, but tests can inject a stub. Replaces direct `.shared` reaches
    // scattered across the ViewModel.
    private let datasourceRegistry: DatasourceRegistry
    private let variablePluginRegistry: VariablePluginRegistry
    private let syncManager: SyncManager
    private let fetchCoordinator: PanelFetchCoordinator

    /// Current datasource selector (Perses-style). Persisted via UserDefaults.
    /// Built-ins map to `BuiltinDatasourceKind.localCLI` / `.promQLProxy`.
    var activeDatasource: DatasourceSelector = DatasourceSelector(kind: BuiltinDatasourceKind.localCLI) {
        didSet {
            persistActiveDatasource()
            queryClient = resolveQueryClient()
            // Clear all cached panel data so stale results from the other source don't show
            panelData.removeAll()
            timeSeriesData = nil
            // Re-fetch variable options too — a `TokiLabelValuesVariable`
            // plugin reads from the active client, so switching backends
            // can yield a different label set.
            refreshVariables()
            fetchData()
        }
    }

    /// Which query dialect Explore should suggest for. The two backends do
    /// not accept the same subset, and completing someone into syntax their
    /// backend ignores yields a plausible number from a different expression
    /// than the one on screen.
    var suggestionDialect: PromQLSuggester.Dialect {
        activeDatasource.kind == BuiltinDatasourceKind.promQLProxy ? .server : .local
    }

    /// Legacy enum-style accessor. Bridges the old `dataSource` API used by the
    /// toolbar picker to the new selector model so view code stays unchanged.
    var dataSource: DashboardDataSource {
        get { activeDatasource.kind == BuiltinDatasourceKind.promQLProxy ? .server : .local }
        set {
            let kind = newValue == .server ? BuiltinDatasourceKind.promQLProxy
                                           : BuiltinDatasourceKind.localCLI
            activeDatasource = DatasourceSelector(kind: kind)
        }
    }

    private func persistActiveDatasource() {
        guard let data = try? JSONEncoder().encode(activeDatasource) else { return }
        UserDefaults.standard.set(data, forKey: "activeDatasourceSelector")
    }

    private func loadPersistedDatasource() -> DatasourceSelector? {
        // Prefer new selector key; fall back to legacy enum string.
        if let data = UserDefaults.standard.data(forKey: "activeDatasourceSelector"),
           let sel = try? JSONDecoder().decode(DatasourceSelector.self, from: data) {
            return sel
        }
        if let raw = UserDefaults.standard.string(forKey: "dashboardDataSource"),
           let legacy = DashboardDataSource(rawValue: raw) {
            let kind = legacy == .server ? BuiltinDatasourceKind.promQLProxy
                                         : BuiltinDatasourceKind.localCLI
            return DatasourceSelector(kind: kind)
        }
        return nil
    }

    private func resolveQueryClient() -> any QueryDataSource {
        // Server gating: if the selector points to the proxy but sync isn't
        // configured or the token is expired, fall back to local.
        if activeDatasource.kind == BuiltinDatasourceKind.promQLProxy {
            guard syncManager.isConfigured && !syncManager.isTokenExpired else {
                return datasourceRegistry.resolve(kind: BuiltinDatasourceKind.localCLI) ?? reportClient
            }
        }
        if let plugin = datasourceRegistry.resolve(activeDatasource) {
            return plugin
        }
        // Last-resort fallback so the dashboard never goes black.
        return reportClient
    }

    init(reportClient: TokiReportClient = TokiReportClient(),
         serverQueryClient: ServerQueryClient = ServerQueryClient(),
         datasourceRegistry: DatasourceRegistry = .shared,
         variablePluginRegistry: VariablePluginRegistry = .shared,
         syncManager: SyncManager = .shared) {
        self.reportClient = reportClient
        self.serverQueryClient = serverQueryClient
        self.datasourceRegistry = datasourceRegistry
        self.variablePluginRegistry = variablePluginRegistry
        self.syncManager = syncManager
        self.fetchCoordinator = PanelFetchCoordinator(datasourceRegistry: datasourceRegistry)
        self.queryClient = reportClient  // default; updated below after activeDatasource is set
        self.dashboardConfig = DashboardConfigStore().load()
        self.dashboardList = DashboardConfigStore().loadDashboardList()
        if let persisted = loadPersistedDatasource() {
            self.activeDatasource = persisted
        }
        self.queryClient = resolveQueryClient()
        registerInlineDatasources()
        populateProviderOptions()
        refreshVariables()
        loadAnnotations()
        loadExploreHistory()
        setupAutoRefresh()
    }

    deinit {
        // Timer.scheduledTimer puts the timer on the RunLoop which retains
        // it until `invalidate()` is called — without this, a destroyed
        // ViewModel still ticks fetchData() every refresh interval. The
        // in-flight Task likewise needs cancelling so its closure body
        // doesn't keep self alive past deinit.
        //
        // deinit is nonisolated under Swift 6 strict concurrency, so we
        // hop back onto MainActor explicitly. Safe because the runtime
        // guarantees deinit runs after the last MainActor-isolated reach.
        MainActor.assumeIsolated {
            refreshTimer?.invalidate()
            fetchTask?.cancel()
            variableRefreshTask?.cancel()
            exploreTask?.cancel()
        }
    }

    /// Re-run all variable plugin loaders and refresh their `options` lists.
    /// Called on dashboard load and whenever a load-triggering event occurs
    /// (time-range change, manual refresh).
    ///
    /// Loads happen in parallel and the results are written back **atomically**
    /// at the end. Earlier this loop mutated `templating.list` after each
    /// `await`, which let an interleaving user edit (variable add/remove)
    /// be clobbered by `saveDashboard()` at the end of the loop.
    ///
    /// `onTimeRangeChange` filters the set to variables with the
    /// `.onTimeRangeChanged` refresh policy. The default (`false`)
    /// includes both `.onDashboardLoad` and `.onTimeRangeChanged`. The
    /// `.never` policy is always skipped.
    func refreshVariables(onTimeRangeChange: Bool = false) {
        let time = dashboardConfig.time
        let resolved: [String: String] = Dictionary(
            uniqueKeysWithValues: dashboardConfig.templating.list.map {
                ($0.name, $0.current.value.joined(separator: "|"))
            }
        )
        let context = VariableLoadContext(
            time: time,
            resolvedVariables: resolved,
            queryClient: queryClient
        )
        let pairs: [(UUID, VariablePluginRef)] = dashboardConfig.templating.list
            .filter { v in
                switch v.refresh {
                case .never: return false
                case .onTimeRangeChanged: return true
                case .onDashboardLoad: return !onTimeRangeChange
                }
            }
            .compactMap { v in v.plugin.map { (v.id, $0) } }
        guard !pairs.isEmpty else { return }
        // Cancel any in-flight refresh so a slower previous load can't
        // overwrite a faster, newer one (datasource switch race).
        variableRefreshTask?.cancel()
        let registry = variablePluginRegistry
        variableRefreshTask = Task { [weak self] in
            // Collect all results before touching the model — keeps the
            // writeback atomic with respect to concurrent user edits.
            var results: [(UUID, [VariableOption])] = []
            results.reserveCapacity(pairs.count)
            for (varID, pluginRef) in pairs {
                if Task.isCancelled { return }
                guard let loader = registry.loader(for: pluginRef.kind) else { continue }
                guard let options = try? await loader.loadOptions(specData: pluginRef.spec, context: context)
                else { continue }
                results.append((varID, options))
            }
            if Task.isCancelled { return }
            guard let self else { return }
            for (varID, options) in results {
                if let idx = self.dashboardConfig.templating.list.firstIndex(where: { $0.id == varID }) {
                    self.dashboardConfig.templating.list[idx].options = options
                    // A variable that has never been selected interpolates to
                    // an empty string, which silently produces a different
                    // query rather than a visible error. `includeAll` already
                    // answers for itself, so only the rest are seeded — and a
                    // constant or a textbox default arrives this way.
                    var v = self.dashboardConfig.templating.list[idx]
                    if v.current.value.isEmpty, !v.includeAll, let first = v.sortedOptions.first {
                        v.current = VariableSelection(text: [first.text], value: [first.value])
                        self.dashboardConfig.templating.list[idx] = v
                    }
                }
            }
            self.saveDashboard()
        }
    }

    /// Ad hoc filters: replace the whole set and refetch. Every panel narrows,
    /// including panels written before the filter existed — that is the point
    /// of the kind, and why it does not go through `$name` substitution.
    func setAdHocFilters(_ filters: [AdHocFilter], variableID: UUID) {
        guard let idx = dashboardConfig.templating.list.firstIndex(where: { $0.id == variableID })
        else { return }
        dashboardConfig.templating.list[idx].adHocFilters = filters.isEmpty ? nil : filters
        saveDashboard()
        fetchData()
    }

    /// Ask an ad hoc variable's query which labels and values it offers.
    /// Best-effort: a failure leaves the previous answer in place rather than
    /// emptying the picker mid-edit.
    func discoverAdHocKeyValues(for variable: DashboardVariable) {
        guard let ref = variable.plugin,
              let loader = variablePluginRegistry.loader(for: ref.kind) as? AdHocVariableLoader
        else { return }
        let context = variableLoadContext()
        let id = variable.id
        Task { [weak self] in
            guard let map = try? await loader.loadKeyValues(specData: ref.spec, context: context),
                  !map.isEmpty, let self
            else { return }
            self.adHocKeyValues[id] = map
        }
    }

    private func variableLoadContext() -> VariableLoadContext {
        VariableLoadContext(
            time: dashboardConfig.time,
            resolvedVariables: Dictionary(
                uniqueKeysWithValues: dashboardConfig.templating.list.map {
                    ($0.name, $0.current.value.joined(separator: "|"))
                }
            ),
            queryClient: queryClient
        )
    }

    /// Ask a label-values variable which labels its query actually returns.
    /// Best-effort: on failure the editor keeps whatever it already knew, so a
    /// transient query error does not empty the picker.
    func discoverLabelKeys(for variable: DashboardVariable) {
        guard let ref = variable.plugin,
              let loader = variablePluginRegistry.loader(for: ref.kind)
                as? TokiLabelValuesVariableLoader
        else { return }
        let context = variableLoadContext()
        let id = variable.id
        Task { [weak self] in
            guard let keys = try? await loader.loadLabelKeys(specData: ref.spec, context: context),
                  !keys.isEmpty, let self
            else { return }
            self.discoveredLabelKeys[id] = keys
        }
    }

    /// Clean up stale variables and populate provider options
    private func populateProviderOptions() {
        // Remove stale interval variable (now auto-determined)
        dashboardConfig.templating.list.removeAll { $0.name == "interval" }

        // Populate provider options from supported providers only
        guard let index = dashboardConfig.templating.list.firstIndex(where: { $0.name == "provider" }) else { return }
        let providerOptions = ProviderRegistry.configurableProviders.compactMap { provider -> VariableOption? in
            guard let tokiId = provider.tokiProviderId else { return nil }
            return VariableOption(text: provider.name, value: tokiId)
        }
        dashboardConfig.templating.list[index].options = providerOptions

        // Migrate stale current selection values (e.g. "anthropic" → "claude_code")
        let validValues = Set(providerOptions.map(\.value) + ["$__all", ""])
        let currentValues = dashboardConfig.templating.list[index].current.value
        let hasStale = currentValues.contains { !validValues.contains($0) }
        if hasStale {
            dashboardConfig.templating.list[index].current = VariableSelection(text: ["All"], value: ["$__all"])
        }
        saveDashboard()
    }

    // MARK: - Data Fetching

    func dataState(for panelID: UUID) -> PanelDataState {
        panelData[panelID] ?? .idle
    }

    func fetchData() {
        fetchTask?.cancel()

        let allPanels = dashboardConfig.panels.filter { $0.panelType != .rowPanel }
        let time = dashboardConfig.time
        let variables = dashboardConfig.templating.list

        // Mark all panels as loading, keeping the current data as `previous` so
        // charts render the last values during refresh instead of blinking empty.
        for panel in allPanels {
            panelData[panel.id] = .loading(
                previous: panelData[panel.id]?.timeSeriesData,
                previousFrames: panelData[panel.id]?.frames
            )
        }
        isLoading = true
        errorMessage = nil

        // Project panels need toki's special `period: "<ts>|<project>"`
        // parsing in local mode — kept on the VM. Regular panels flow
        // through `PanelFetchCoordinator`.
        let projectPanels = allPanels.filter { panelTokensByProject($0) }
        let regularPanels = allPanels.filter { !panelTokensByProject($0) }

        let coordinator = fetchCoordinator
        let defaultClient = queryClient
        let activeSelector = activeDatasource

        fetchTask = Task { [weak self] in
            let results = await coordinator.fetchRegular(
                panels: regularPanels,
                time: time,
                variables: variables,
                activeDatasource: activeSelector,
                defaultClient: defaultClient
            )

            if Task.isCancelled { return }
            guard let self else { return }

            var projectResults: [UUID: PanelDataState] = [:]
            if !projectPanels.isEmpty {
                projectResults = await self.fetchProjectPanels(projectPanels, time: time)
            }
            if Task.isCancelled { return }

            // Final cancel check before the writeback — without it a
            // newer fetch arriving between the previous checkpoint and
            // the dictionary assignment could be clobbered by stale
            // results landing here.
            if Task.isCancelled { return }
            for (id, state) in results { self.panelData[id] = state }
            for (id, state) in projectResults { self.panelData[id] = state }

            // Backward compatibility: global timeSeriesData from first
            // loaded regular panel. Order matches user's panel order.
            if let firstLoaded = regularPanels.first(where: { self.panelData[$0.id]?.timeSeriesData != nil }),
               let data = self.panelData[firstLoaded.id]?.timeSeriesData {
                self.timeSeriesData = data
                self.enabledModels = Set(data.allModelNames)
                self.dataVersion += 1
            }

            self.isLoading = false
        }
    }

    /// Resolve a panel's effective metric without three JSON decodes.
    /// Used by `fetchData` to split project panels from regular ones.
    private func panelTokensByProject(_ panel: PanelConfig) -> Bool {
        if let m = panel.resolvedTokiQuery?.metric { return m == .tokensByProject }
        return (panel.targets.first?.metric ?? panel.metric) == .tokensByProject
    }

    // MARK: - Query Interpolation
    //
    // Delegated to `Domain/VariableResolver` — the interpolation logic
    // is pure (templating list + time → string) and lived in the VM only
    // for historical reasons. Tests can hit `VariableResolver.interpolate`
    // directly without spinning up a ViewModel.

    func interpolateQuery(_ template: String, time: TimeConfig? = nil) -> String {
        VariableResolver.interpolate(
            template: template,
            time: time ?? dashboardConfig.time,
            variables: dashboardConfig.templating.list
        )
    }

    /// Fetch project-grouped data. toki returns "date|project" in period field.
    private func fetchProjectPanels(_ panels: [PanelConfig], time: TimeConfig) async -> [UUID: PanelDataState] {
        var out: [UUID: PanelDataState] = [:]
        let template = PanelMetric.tokensByProject.defaultQuery
        let query = interpolateQuery(template, time: time)
        // After the datasource refactor, `queryClient` is always a
        // `DatasourcePlugin` wrapper (never a bare `ServerQueryClient`),
        // so the old `is ServerQueryClient` check evaluated false in
        // server mode too and silently routed every project panel
        // through the local CLI. Check the plugin type instead, with
        // the wrapped `ServerQueryClient` case retained as a safety net
        // for any future direct injection.
        let isServer = queryClient is PromQLProxyDatasource || queryClient is ServerQueryClient

        if isServer {
            // Server mode: use PromQL query via server proxy
            do {
                let result = try await queryClient.queryPromQL(query: query, time: time)
                for panel in panels {
                    out[panel.id] = .loaded(result.timeSeries, frames: result.frames)
                }
            } catch {
                for panel in panels {
                    out[panel.id] = .error(error.localizedDescription)
                }
            }
            return out
        }

        // Local mode: use toki query with project-specific parsing
        do {
            let startEpoch = Int(time.fromDate.timeIntervalSince1970)
            let endEpoch = Int(time.toDate.timeIntervalSince1970)
            let cliArgs = ["query", "-z", "UTC", "--output-format", "json",
                           "--start", "\(startEpoch)", "--end", "\(endEpoch)",
                           "--step", time.bucketString, query]
            let rawData = try await CLIProcessRunner.run(
                executable: TokiPath.resolved,
                arguments: cliArgs
            )

            struct ProjectReport: Codable {
                let providers: [String: [ProjectPeriod]]?
            }
            struct ProjectPeriod: Codable {
                let period: String
                struct ModelUsage: Codable {
                    let input_tokens: UInt64
                    let output_tokens: UInt64
                }
                let usage_per_models: [ModelUsage]?
            }

            guard let report = try? JSONDecoder().decode(ProjectReport.self, from: rawData) else {
                for panel in panels { out[panel.id] = .error("Parse error") }
                return out
            }

            // Build TimeSeriesData where "model" is actually the project name
            var projectTotals: [String: UInt64] = [:]
            for (_, periods) in report.providers ?? [:] {
                for period in periods {
                    let parts = period.period.split(separator: "|", maxSplits: 1)
                    let project = parts.count > 1 ? String(parts[1]) : period.period
                    let tokens = period.usage_per_models?.reduce(UInt64(0)) { $0 + $1.input_tokens + $1.output_tokens } ?? 0
                    projectTotals[project, default: 0] += tokens
                }
            }

            // Create synthetic TimeSeriesData with projects as "models"
            let summaries = projectTotals.map { project, tokens in
                TokiModelSummary(
                    model: project,
                    inputTokens: tokens, outputTokens: 0, totalTokens: tokens,
                    events: 0, costUsd: nil,
                    cacheCreationInputTokens: nil, cacheReadInputTokens: nil,
                    cachedInputTokens: nil, reasoningOutputTokens: nil
                )
            }
            let point = TimeSeriesPoint(date: Date(), models: summaries)
            let data = TimeSeriesData(points: [point], granularity: .daily)

            for panel in panels {
                // Synthesized locally rather than fetched, so there are no
                // frames to attach — Inspect reports that honestly instead of
                // showing an empty frame set as if the query returned nothing.
                out[panel.id] = .loaded(data, frames: FrameSet())
            }
        } catch {
            for panel in panels {
                out[panel.id] = .error(error.localizedDescription)
            }
        }
        return out
    }

    /// Run one panel's queries the way the dashboard would, WITHOUT touching
    /// the dashboard's own state.
    ///
    /// The panel editor needs this: its preview has to show the effect of the
    /// query being edited, and that panel is not saved yet — writing its result
    /// into `panelData` would put an unsaved query's answer on the dashboard
    /// behind the editor.
    func fetchPreview(for panel: PanelConfig) async -> PanelDataState {
        let time = dashboardConfig.time
        if panelTokensByProject(panel) {
            return await fetchProjectPanels([panel], time: time)[panel.id] ?? .idle
        }
        let results = await fetchCoordinator.fetchRegular(
            panels: [panel],
            time: time,
            variables: dashboardConfig.templating.list,
            activeDatasource: activeDatasource,
            defaultClient: queryClient
        )
        return results[panel.id] ?? .idle
    }

    // Project name resolution moved to `Domain/ProjectNameResolver`. Call
    // `ProjectNameResolver.cleanProjectName(_:)` directly.

    // MARK: - Time Range

    func setTimeRange(from: String, to: String = "now") {
        timeConfig = TimeConfig(from: from, to: to)
    }

    func setTimeRangePreset(_ preset: TimeRangePreset) {
        setTimeRange(from: preset.from)
    }

    /// Current time range display label
    var timeRangeLabel: String {
        let time = dashboardConfig.time
        // Check preset match
        if let preset = TimeRangePreset.presets.first(where: { $0.from == time.from }) {
            return preset.label
        }
        // Absolute time range
        if !time.isRelative {
            let fmt = DateFormatter()
            fmt.dateFormat = "M/d HH:mm"
            return "\(fmt.string(from: time.fromDate)) ~ \(fmt.string(from: time.toDate))"
        }
        return time.from
    }

    func setAbsoluteTimeRange(from: Date, to: Date) {
        timeConfig = TimeConfig.absolute(from: from, to: to)
    }

    // MARK: - Auto-Refresh

    private func setupAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard let interval = dashboardConfig.refresh.interval else { return }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchData()
            }
        }
    }

    // MARK: - Variable Management

    func updateVariable(id: UUID, selection: VariableSelection) {
        guard let index = dashboardConfig.templating.list.firstIndex(where: { $0.id == id }) else { return }
        dashboardConfig.templating.list[index].current = selection
        saveDashboard()
        fetchData()
    }

    func addVariable(_ variable: DashboardVariable) {
        var v = variable
        Self.normalizeVariable(&v)
        dashboardConfig.templating.list.append(v)
        saveDashboard()
        refreshVariables()
    }

    /// Backfill a variable's `plugin` envelope so `refreshVariables`'s
    /// plugin-loader path can find it. The settings sheet creates
    /// variables with `plugin == nil`; without this step they would
    /// silently never refresh (the loader loop `compactMap`s on `plugin`).
    /// Mirrors `DashboardMigrator.migrateV3toV4`'s variable branch.
    static func normalizeVariable(_ v: inout DashboardVariable) {
        guard v.plugin == nil else { return }
        switch v.type {
        case .custom:
            let spec = StaticListVariableSpec(values: v.options)
            let data = (try? JSONEncoder().encode(spec)) ?? Data()
            v.plugin = VariablePluginRef(
                kind: BuiltinVariablePluginKind.staticList, spec: data
            )
        case .interval:
            let parsed = v.query
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let values = parsed.isEmpty ? IntervalVariableSpec().values : parsed
            let spec = IntervalVariableSpec(values: values)
            let data = (try? JSONEncoder().encode(spec)) ?? Data()
            v.plugin = VariablePluginRef(
                kind: BuiltinVariablePluginKind.interval, spec: data
            )
        }
    }

    func removeVariable(id: UUID) {
        dashboardConfig.templating.list.removeAll { $0.id == id }
        saveDashboard()
    }

    /// Get current value for a variable by name
    func variableValue(named name: String) -> [String] {
        guard let variable = dashboardConfig.templating.list.first(where: { $0.name == name }) else {
            return []
        }
        return variable.current.value
    }

    // MARK: - Model Filter

    func toggleModel(_ model: String) {
        if enabledModels.contains(model) {
            enabledModels.remove(model)
        } else {
            enabledModels.insert(model)
        }
    }

    func selectAllModels() {
        if let data = timeSeriesData {
            enabledModels = Set(data.allModelNames)
        }
    }

    func deselectAllModels() {
        enabledModels.removeAll()
    }

    // MARK: - Computed

    var filteredModelNames: [String] {
        timeSeriesData?.allModelNames.filter { enabledModels.contains($0) } ?? []
    }

    var totalTokens: UInt64 { timeSeriesData?.totalTokens ?? 0 }
    var totalCost: Double { timeSeriesData?.totalCost ?? 0 }
    var totalEvents: Int { timeSeriesData?.totalEvents ?? 0 }
    var topModel: String? { timeSeriesData?.topModel }

    // MARK: - Panel Management

    func addPanel(_ panel: PanelConfig) {
        var p = panel
        Self.normalizePanel(&p)
        dashboardConfig.panels.append(p)
        syncLayoutsWithPanels()
        saveDashboard()
    }

    func removePanel(id: UUID) {
        dashboardConfig.panels.removeAll { $0.id == id }
        syncLayoutsWithPanels()
        saveDashboard()
    }

    func updatePanel(_ panel: PanelConfig) {
        guard let index = dashboardConfig.panels.firstIndex(where: { $0.id == panel.id }) else { return }
        var p = panel
        Self.normalizePanel(&p)
        dashboardConfig.panels[index] = p
        syncLayoutsWithPanels()
        saveDashboard()
    }

    /// Update a panel's position and persist immediately. Use for one-shot
    /// commits (e.g. dropping a panel into a new cell on `.onEnded`).
    func updatePanelPosition(id: UUID, position: GridPosition) {
        guard let index = dashboardConfig.panels.firstIndex(where: { $0.id == id }) else { return }
        dashboardConfig.panels[index].gridPosition = position
        resolveOverlaps(anchorPanelID: id)
        syncLayoutsWithPanels()
        saveDashboard()
    }

    /// Update a panel's position in memory only — no disk persist, no
    /// version commit. Use during continuous drag / resize so the UI
    /// reflects the new size every frame without thrashing UserDefaults.
    /// Pair with `commitPanelPositionChange()` on `.onEnded`.
    func setPanelPositionInMemory(id: UUID, position: GridPosition) {
        guard let index = dashboardConfig.panels.firstIndex(where: { $0.id == id }) else { return }
        dashboardConfig.panels[index].gridPosition = position
        resolveOverlaps(anchorPanelID: id)
        syncLayoutsWithPanels()
    }

    /// Push every panel that collides with the anchor (the just-resized
    /// or just-moved panel) downward. The anchor stays at its new
    /// position; other panels yield by setting their `row` to
    /// `anchor.row + anchor.height`. The pass repeats greedily so a
    /// pushed panel can in turn push panels below it (cascade).
    ///
    /// Without this, growing a panel vertically leaves panels in the
    /// rows immediately below it visually overlapping the grown panel
    /// — see the screenshot in PR feedback. The reflow keeps the grid
    /// non-overlapping at the cost of cell positions changing on
    /// resize, which mirrors how Grafana / Perses behave.
    private func resolveOverlaps(anchorPanelID: UUID) {
        guard let anchorIdx = dashboardConfig.panels.firstIndex(where: { $0.id == anchorPanelID })
        else { return }
        // Snapshot all positions; mutate via this dict to avoid index drift.
        var positions: [UUID: GridPosition] = Dictionary(
            uniqueKeysWithValues: dashboardConfig.panels.map { ($0.id, $0.gridPosition) }
        )
        let anchorPos = positions[anchorPanelID]!

        // Process every other panel in (row, column) order so a panel
        // higher up gets settled before the one it might subsequently
        // push. The anchor is treated as immovable; everything else
        // can fall.
        let others = dashboardConfig.panels
            .filter { $0.id != anchorPanelID }
            .map(\.id)
            .sorted { (a, b) in
                let pa = positions[a]!
                let pb = positions[b]!
                if pa.row != pb.row { return pa.row < pb.row }
                return pa.column < pb.column
            }

        // Each settled panel becomes a new immovable rect against which
        // later panels must also clear. Cascades naturally because the
        // settled set grows row by row.
        var settled: [(id: UUID, rect: GridPosition)] = [(anchorPanelID, anchorPos)]
        for id in others {
            var pos = positions[id]!
            var changed = true
            // Fixed-point: each push may now overlap a different
            // settled rect, so loop until clear of everything.
            while changed {
                changed = false
                for s in settled where Self.rectsOverlap(pos, s.rect) {
                    pos.row = s.rect.row + s.rect.height
                    changed = true
                }
            }
            positions[id] = pos
            settled.append((id, pos))
        }

        // Write the resolved positions back into the model.
        for i in 0..<dashboardConfig.panels.count {
            if let p = positions[dashboardConfig.panels[i].id],
               p != dashboardConfig.panels[i].gridPosition {
                dashboardConfig.panels[i].gridPosition = p
            }
        }
        _ = anchorIdx // silence unused-var when anchor is not re-fetched
    }

    /// Inclusive grid-cell overlap between two `GridPosition` rects.
    /// Treats positions as half-open `[col, col+w) × [row, row+h)`.
    private static func rectsOverlap(_ a: GridPosition, _ b: GridPosition) -> Bool {
        let aRight  = a.column + a.width
        let bRight  = b.column + b.width
        let aBottom = a.row + a.height
        let bBottom = b.row + b.height
        let colsOverlap = a.column < bRight && b.column < aRight
        let rowsOverlap = a.row    < bBottom && b.row    < aBottom
        return colsOverlap && rowsOverlap
    }

    /// Persist the dashboard after a drag / resize completes. Single
    /// `saveDashboard()` call at the end, instead of one per drag tick.
    func commitPanelPositionChange() {
        saveDashboard()
    }

    /// True while a panel is being moved or resized. Used by edge-resize
    /// strips to disable their own hit-testing on the actively-dragged
    /// panel — otherwise a drag and a resize can stomp each other.
    var draggingPanelID: UUID?

    /// Bring a panel's Perses-shaped envelope fields (`plugin`, `queries`)
    /// back into sync with its legacy authoritative fields (`panelType`,
    /// `options`, `targets`). Called on every add/update so the on-disk JSON
    /// stays accurate after edit-mode mutations.
    static func normalizePanel(_ panel: inout PanelConfig) {
        // Plugin envelope: re-encode whenever the encoded spec no longer
        // matches the current options — not merely when it is absent or of the
        // wrong kind. Renderers read the LEGACY options, so an options edit
        // that kept the same visualization (say lineWidth 2 -> 4) left the
        // stored spec at the old value: the screen showed 4 while exported
        // JSON said 2. For a feature whose point is sharing, the exported
        // document silently disagreeing with the screen is the worst failure
        // mode.
        let expectedKind = BuiltinPanelPluginKind.kind(for: panel.panelType)
        let currentSpec = panel.options.encodedSpec(forPanelPluginKind: expectedKind) ?? Data()
        let needsPluginRebuild = panel.plugin == nil
            || panel.plugin?.kind != expectedKind
            || panel.plugin?.spec != currentSpec
        if needsPluginRebuild {
            panel.plugin = PanelPluginRef(kind: expectedKind, spec: currentSpec)
        }

        // Queries envelope: rebuild when targets shape *or content* drifts
        // from the queries we last emitted. The earlier count-only guard
        // missed the common case where the user edits a single target's
        // PromQL string — count stays the same, but `panel.queries` would
        // still encode the old string, and `effectiveQuery` (which prefers
        // queries over targets) would run the stale query on next fetch.
        let sourceTargets = panel.targets.isEmpty
            ? [PanelTarget(refId: "A", metric: panel.metric)]
            : panel.targets
        if !queriesMatch(panel.queries, targets: sourceTargets) {
            // Carry the existing per-query datasource forward. `PanelTarget`
            // has no datasource field, so rebuilding from targets alone wrote
            // `nil` and silently erased a query-level override every time an
            // unrelated field (metric, PromQL text) was edited.
            let decoder = JSONDecoder()
            let existingDatasources: [DatasourceSelector?] = (panel.queries ?? []).map { q in
                guard let spec = try? decoder.decode(TokiPromQLQuerySpec.self, from: q.spec.plugin.spec)
                else { return nil }
                return spec.datasource
            }
            panel.queries = sourceTargets.enumerated().map { index, target in
                let spec = TokiPromQLQuerySpec(
                    datasource: existingDatasources.indices.contains(index)
                        ? existingDatasources[index] : nil,
                    metric: target.metric,
                    query: target.query,
                    hide: target.hide ? true : nil
                )
                let specData = (try? JSONEncoder().encode(spec)) ?? Data()
                return Query(
                    kind: BuiltinQueryKind.timeSeriesQuery,
                    spec: QuerySpec(
                        name: target.refId,
                        plugin: QueryPluginRef(
                            kind: BuiltinQueryPluginKind.tokiPromQLQuery,
                            spec: specData
                        )
                    )
                )
            }
        }
    }

    /// Compare the existing `queries` envelope to a list of targets. Returns
    /// false if anything material differs — count, refId, metric, or
    /// query-string-override — so `normalizePanel` rebuilds.
    private static func queriesMatch(_ queries: [Query]?, targets: [PanelTarget]) -> Bool {
        guard let queries, queries.count == targets.count else { return false }
        let decoder = JSONDecoder()
        for (q, target) in zip(queries, targets) {
            guard q.kind == BuiltinQueryKind.timeSeriesQuery,
                  q.spec.plugin.kind == BuiltinQueryPluginKind.tokiPromQLQuery,
                  let spec = try? decoder.decode(TokiPromQLQuerySpec.self, from: q.spec.plugin.spec)
            else { return false }
            if q.spec.name != target.refId { return false }
            if spec.metric != target.metric { return false }
            if spec.query != target.query { return false }
            // `hide` decides whether the query renders, and the fetch path
            // reads it from the envelope — so a stale value here means the
            // eye in the editor and the panel on screen disagree.
            if (spec.hide ?? false) != target.hide { return false }
            // Datasource is deliberately NOT compared: it lives only on the
            // query envelope (PanelTarget has no such field), so a difference
            // here is not drift from the targets — treating it as drift would
            // rebuild and destroy the very value being preserved above.
        }
        return true
    }

    /// Keep `dashboardConfig.layouts[0].items` in sync with the canonical
    /// `panels` array. Adds, removes, and re-positions items so the
    /// Perses-shaped on-disk layout stays accurate. Bails out when no
    /// layouts have been initialized yet (pre-v4 in-memory state).
    private func syncLayoutsWithPanels() {
        guard var layouts = dashboardConfig.layouts, !layouts.isEmpty else { return }
        var spec = layouts[0].spec
        let existingByKey = Dictionary(uniqueKeysWithValues:
            spec.items.compactMap { item -> (String, LayoutGridItem)? in
                guard let key = item.content.panelKey else { return nil }
                return (key, item)
            }
        )
        spec.items = dashboardConfig.panels.map { panel in
            let key = panel.id.uuidString
            // Preserve any layout-only metadata (e.g. future fields) when the
            // panel already had an item; refresh x/y/width/height from the
            // panel's authoritative `gridPosition`.
            var item = existingByKey[key] ?? LayoutGridItem(
                x: panel.gridPosition.column, y: panel.gridPosition.row,
                width: panel.gridPosition.width, height: panel.gridPosition.height,
                content: JSONRef(panelKey: key)
            )
            item.x = panel.gridPosition.column
            item.y = panel.gridPosition.row
            item.width = panel.gridPosition.width
            item.height = panel.gridPosition.height
            item.content = JSONRef(panelKey: key)
            return item
        }
        layouts[0].spec = spec
        dashboardConfig.layouts = layouts
    }

    // MARK: - Row Panel Management

    func addRow(title: String = "New Row") {
        let position = DashboardGridLayout.firstAvailablePosition(
            width: 24, height: 1, existing: dashboardConfig.panels
        )
        let row = PanelConfig(
            title: title,
            panelType: .rowPanel,
            metric: .totalTokens,
            gridPosition: position
        )
        dashboardConfig.panels.append(row)
        saveDashboard()
    }

    func toggleRowCollapse(panelID: UUID) {
        if collapsedRows.contains(panelID) {
            collapsedRows.remove(panelID)
        } else {
            collapsedRows.insert(panelID)
        }
        // Also update the panel's collapsed field
        if let idx = dashboardConfig.panels.firstIndex(where: { $0.id == panelID }) {
            dashboardConfig.panels[idx].collapsed.toggle()
            saveDashboard()
        }
    }

    /// Returns panels grouped by rows. Panels before first row are in their own group.
    var panelsGroupedByRow: [(row: PanelConfig?, panels: [PanelConfig])] {
        var groups: [(row: PanelConfig?, panels: [PanelConfig])] = []
        let sorted = dashboardConfig.panels.sorted { $0.gridPosition.row < $1.gridPosition.row }
        var currentRow: PanelConfig?
        var currentPanels: [PanelConfig] = []

        for panel in sorted {
            if panel.panelType == .rowPanel {
                // Save previous group
                if currentRow != nil || !currentPanels.isEmpty {
                    groups.append((row: currentRow, panels: currentPanels))
                }
                currentRow = panel
                currentPanels = []
            } else {
                currentPanels.append(panel)
            }
        }
        // Save last group
        if currentRow != nil || !currentPanels.isEmpty {
            groups.append((row: currentRow, panels: currentPanels))
        }

        return groups
    }

    /// Visible panels accounting for collapsed rows
    var visiblePanels: [PanelConfig] {
        var visible: [PanelConfig] = []
        let sorted = dashboardConfig.panels.sorted { $0.gridPosition.row < $1.gridPosition.row }
        var inCollapsedRow = false

        for panel in sorted {
            if panel.panelType == .rowPanel {
                visible.append(panel)
                inCollapsedRow = collapsedRows.contains(panel.id) || panel.collapsed
            } else if !inCollapsedRow {
                visible.append(panel)
            }
        }

        return visible
    }

    // MARK: - Save / Persist

    /// Set when a save did not happen. The screen is then showing something
    /// the disk does not have, and the only thing that can tell the user is
    /// this (계약 C6). Cleared by the next save that succeeds.
    var saveFailure: String?

    /// Whether the open dashboard was written against a schema beyond this
    /// build. Such a document opens read-only: this build must not decide what
    /// a future schema looks like (계약 C2).
    var isReadOnlyDashboard: Bool { dashboardConfig.isReadOnlyForThisBuild }

    @discardableResult
    func saveDashboard() -> DashboardSaveOutcome {
        let single = configStore.save(dashboardConfig)
        let inList = configStore.updateDashboardInList(dashboardConfig)
        for outcome in [single, inList] {
            if case let .failed(reason) = outcome {
                saveFailure = reason
                return outcome
            }
        }
        saveFailure = nil
        return single
    }

    func saveDashboardWithVersion(message: String = "") {
        dashboardConfig.version += 1
        saveDashboard()
        versionStore.saveVersion(for: dashboardConfig, message: message)
    }

    func resetToDefault() {
        configStore.resetToDefault()
        dashboardConfig = DashboardConfigStore.defaultConfig
        setupAutoRefresh()
    }

    // MARK: - JSON Import/Export

    func exportDashboard() {
        configStore.exportToFile(dashboardConfig)
    }

    /// Wrapper for the dashboard-list editor (reorder-on-confirm).
    func saveEditedDashboardList(_ list: [DashboardConfig]) {
        configStore.saveDashboardList(list)
    }

    /// Export a *specific* dashboard from the list, not necessarily the
    /// currently-active one. Used by the sidebar's per-row export menu.
    func exportDashboardToFile(_ config: DashboardConfig) {
        configStore.exportToFile(config)
    }

    /// Reload the dashboard list cache from disk after an external mutation.
    func reloadDashboardList() {
        dashboardList = configStore.loadDashboardList()
    }

    func importDashboard() {
        guard var imported = configStore.importFromFile() else {
            // Distinguish a failed import from a cancelled one: the store sets
            // a reason only for the former. Swallowing it made a malformed
            // file look exactly like pressing Cancel.
            if let reason = configStore.lastImportError {
                errorMessage = reason
            }
            return
        }
        errorMessage = nil
        // Migrate imported config and normalize each panel so plugin /
        // queries envelopes are accurate (imports might originate from
        // older exports or be hand-edited).
        imported = DashboardMigrator.migrate(imported)
        imported.panels = imported.panels.map { panel in
            var p = panel
            Self.normalizePanel(&p)
            return p
        }
        dashboardConfig = imported
        saveDashboard()
        fetchData()
    }

    // MARK: - Dashboard List

    func loadDashboardList() -> [DashboardConfig] {
        dashboardList = configStore.loadDashboardList()
        return dashboardList
    }

    func switchDashboard(_ config: DashboardConfig) {
        dashboardConfig = config
        // Leaving edit mode on while switching into a read-only document would
        // offer drag handles and a delete button that cannot write (계약 C2).
        if config.isReadOnlyForThisBuild { isEditing = false }
        registerInlineDatasources()
        populateProviderOptions()
        refreshVariables()
        saveDashboard()
        configStore.activeDashboardUID = config.uid
        collapsedRows = Set(config.panels.filter(\.collapsed).map(\.id))
        loadAnnotations()
        setupAutoRefresh()
        fetchData()
    }

    /// Register dashboard-inline datasource instances with the global registry
    /// so panels with `queries[*].plugin.spec.datasource.name` set can be
    /// resolved against them. Called on init and every dashboard switch.
    ///
    /// Clears previously-registered names first so a stale name from
    /// dashboard A (e.g. "prod") doesn't resolve against dashboard B,
    /// which would otherwise let a removed datasource keep serving panels.
    ///
    /// Per-instance spec differentiation is not yet wired (each name
    /// still aliases the kind's default plugin), but the unregister step
    /// at least bounds the surface to "names declared by this dashboard."
    private func registerInlineDatasources() {
        datasourceRegistry.clearNamed()
        for (_, instance) in dashboardConfig.datasources {
            if let plugin = datasourceRegistry.resolve(kind: instance.kind) {
                datasourceRegistry.registerNamed(name: instance.name, plugin: plugin)
            }
        }
    }

    func switchDashboard(uid: String) {
        guard let config = configStore.dashboard(for: uid) else { return }
        switchDashboard(config)
    }

    func createNewDashboard(title: String = "New Dashboard") {
        var config = DashboardConfig()
        config.title = title
        config.templating = DashboardConfig.defaultTemplating
        // Run through the same migration as persisted dashboards so plugin /
        // queries / layouts envelopes are populated up-front. New dashboards
        // start empty so this is mostly a no-op, but it keeps the invariant
        // that any in-memory dashboard is v4-shaped.
        config = DashboardMigrator.migrate(config)
        configStore.addDashboard(config)
        dashboardList = configStore.loadDashboardList()
        switchDashboard(config)
    }

    func deleteDashboard(uid: String) {
        configStore.deleteDashboard(uid: uid)
        dashboardList = configStore.loadDashboardList()
        if dashboardConfig.uid == uid {
            if let first = dashboardList.first {
                switchDashboard(first)
            } else {
                createNewDashboard()
            }
        }
    }

    func reorderDashboards(from source: IndexSet, to destination: Int) {
        dashboardList.move(fromOffsets: source, toOffset: destination)
    }

    func finishEditingDashboardList() {
        isEditingDashboardList = false
        configStore.saveDashboardList(dashboardList)
    }

    func moveDashboardUp(uid: String) {
        var list = configStore.loadDashboardList()
        guard let index = list.firstIndex(where: { $0.uid == uid }), index > 0 else { return }
        list.swapAt(index, index - 1)
        configStore.saveDashboardList(list)
        dashboardList = list
    }

    func moveDashboardDown(uid: String) {
        var list = configStore.loadDashboardList()
        guard let index = list.firstIndex(where: { $0.uid == uid }), index < list.count - 1 else { return }
        list.swapAt(index, index + 1)
        configStore.saveDashboardList(list)
        dashboardList = list
    }

    func duplicateDashboard(uid: String) {
        if let dup = configStore.duplicateDashboard(uid: uid) {
            dashboardList = configStore.loadDashboardList()
            switchDashboard(dup)
        }
    }

    var filteredDashboardList: [DashboardConfig] {
        if sidebarSearchText.isEmpty {
            return dashboardList
        }
        let query = sidebarSearchText.lowercased()
        return dashboardList.filter {
            $0.title.lowercased().contains(query) ||
            $0.tags.contains(where: { $0.lowercased().contains(query) })
        }
    }

    // MARK: - Annotations

    func loadAnnotations() {
        annotations = annotationStore.annotations(for: dashboardConfig.uid)
    }

    func addAnnotation(timestamp: Date, text: String, tags: [String] = [], colorHex: String = "#FF6600") {
        let annotation = DashboardAnnotation(
            dashboardUID: dashboardConfig.uid,
            timestamp: timestamp,
            text: text,
            tags: tags,
            colorHex: colorHex
        )
        annotationStore.addAnnotation(annotation)
        loadAnnotations()
    }

    func removeAnnotation(id: UUID) {
        annotationStore.removeAnnotation(id: id)
        loadAnnotations()
    }

    // MARK: - Explore

    func runExploreQuery() {
        guard !exploreQuery.isEmpty else { return }
        isExploreLoading = true
        exploreError = nil
        exploreErrorIsRefusal = false

        // Save to history
        let entry = ExploreQueryEntry(query: exploreQuery)
        exploreQueryHistory.insert(entry, at: 0)
        if exploreQueryHistory.count > 50 {
            exploreQueryHistory = Array(exploreQueryHistory.prefix(50))
        }
        saveExploreHistory()

        let client = queryClient
        let time = exploreTime
        let checked = QueryValidation.check(
            template: exploreQuery, time: time,
            variables: dashboardConfig.templating.list, backend: suggestionDialect
        )
        exploreValidation = checked.validation
        let interpolated = checked.query
        exploreExecutedQuery = interpolated

        // Cancel any in-flight explore query first — otherwise a slower
        // previous response can race in and overwrite the result of a
        // faster newer one (run twice → last-typed query loses).
        exploreTask?.cancel()
        exploreTask = Task { [weak self] in
            do {
                let result = try await client.queryPromQL(query: interpolated, time: time)
                if Task.isCancelled { return }
                guard let self else { return }
                self.isExploreLoading = false
                self.exploreFrames = result.frames
                self.exploreError = nil
            } catch {
                if Task.isCancelled { return }
                guard let self else { return }
                self.isExploreLoading = false
                // The previous result is dropped along with the failure: a
                // chart left on screen under an error message is read as the
                // answer to the query that just failed.
                self.exploreFrames = nil
                self.exploreError = error.localizedDescription
                self.exploreErrorIsRefusal = DatasourceRefusal.isRefusal(error)
            }
        }
    }

    /// Put the explored query on the dashboard as a panel (contract Q5 /
    /// User Story 1). Explore exists to try a query; if the only way to keep
    /// one is to retype it into the editor, the trying and the keeping are two
    /// unrelated activities and the reader does the second one by hand.
    @discardableResult
    func promoteExploreToPanel(title: String, panelType: PanelType = .timeSeries) -> PanelConfig? {
        let template = exploreQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return nil }
        let metric: PanelMetric = .tokensByModel
        // The query is stored as the TEMPLATE the reader typed, not as the
        // interpolated string that was sent: a panel with `$__interval` baked
        // into it would keep Explore's bucket width forever.
        let panel = PanelConfig(
            title: title.isEmpty ? template : title,
            panelType: panelType,
            metric: metric,
            gridPosition: GridPosition(column: 0, row: nextFreeRow, width: 12, height: 4),
            targets: [PanelTarget(refId: "A", metric: metric, query: template)]
        )
        addPanel(panel)
        fetchData()
        return panel
    }

    /// The first row below everything already placed.
    private var nextFreeRow: Int {
        dashboardConfig.panels
            .map { $0.gridPosition.row + $0.gridPosition.height }
            .max() ?? 0
    }

    private func loadExploreHistory() {
        guard let data = UserDefaults.standard.data(forKey: "exploreQueryHistory"),
              let items = try? JSONDecoder().decode([ExploreQueryEntry].self, from: data)
        else { return }
        exploreQueryHistory = items
    }

    private func saveExploreHistory() {
        guard let data = try? JSONEncoder().encode(exploreQueryHistory) else { return }
        UserDefaults.standard.set(data, forKey: "exploreQueryHistory")
    }

    // MARK: - Color

    /// Fixed model colors — known models get brand-consistent colors, unknown get auto-assigned
    private static let knownModelColors: [(prefix: String, color: Color)] = [
        // Anthropic/Claude: warm tones (orange/amber/red family)
        ("claude-opus", Color(red: 0.93, green: 0.55, blue: 0.10)),     // bright orange
        ("claude-sonnet", Color(red: 0.80, green: 0.40, blue: 0.60)),   // mauve/plum
        ("claude-haiku", Color(red: 0.75, green: 0.20, blue: 0.20)),    // crimson
        ("claude", Color(red: 0.90, green: 0.50, blue: 0.25)),          // fallback orange
        // OpenAI: green family
        ("gpt", Color(red: 0.20, green: 0.65, blue: 0.45)),             // teal green
        ("o1", Color(red: 0.30, green: 0.75, blue: 0.40)),              // bright green
        ("o3", Color(red: 0.15, green: 0.55, blue: 0.50)),              // dark teal
        // Google: blue family
        ("gemini", Color(red: 0.25, green: 0.50, blue: 0.85)),          // google blue
    ]

    private static let fallbackPalette: [Color] = [
        .purple, .teal, .indigo, .mint, .pink, .brown, .cyan
    ]

    // Cache the unknown-model → palette-index map so we don't re-sort and
    // re-filter allModelNames on every colorForModel call (invoked per row/series
    // during view body evaluation). @ObservationIgnored so refreshing the cache
    // doesn't register as an observable mutation.
    @ObservationIgnored private var colorCacheVersion: Int = -1
    @ObservationIgnored private var unknownModelIndex: [String: Int] = [:]

    func colorForModel(_ model: String) -> Color {
        let lower = model.lowercased()
        // Check known models first
        for known in Self.knownModelColors {
            if lower.contains(known.prefix) {
                return known.color
            }
        }
        // Fallback: stable index from ALL models. Recompute the ordering only
        // when the underlying data changes (dataVersion bump).
        if colorCacheVersion != dataVersion {
            colorCacheVersion = dataVersion
            var idx: [String: Int] = [:]
            var next = 0
            for m in (timeSeriesData?.allModelNames ?? []).sorted()
            where !Self.knownModelColors.contains(where: { m.lowercased().contains($0.prefix) }) {
                idx[m] = next
                next += 1
            }
            unknownModelIndex = idx
        }
        let index = unknownModelIndex[model] ?? 0
        return Self.fallbackPalette[index % Self.fallbackPalette.count]
    }

    // MARK: - Data Links

    func resolveDataLink(_ link: DataLink, context: [String: String] = [:]) -> String {
        var url = link.url
        // Interpolate variables
        for variable in dashboardConfig.templating.list {
            let value = variable.current.value.first ?? ""
            url = url.replacingOccurrences(of: "${\(variable.name)}", with: value)
        }
        // Interpolate context
        for (key, value) in context {
            url = url.replacingOccurrences(of: "${\(key)}", with: value)
        }
        // Built-in variables
        url = url.replacingOccurrences(of: "${__from}", with: dashboardConfig.time.from)
        url = url.replacingOccurrences(of: "${__to}", with: dashboardConfig.time.to)
        return url
    }
}
