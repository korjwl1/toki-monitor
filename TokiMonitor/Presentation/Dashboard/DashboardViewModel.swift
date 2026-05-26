import Foundation
import SwiftUI
import Combine

/// Grouping key used by `DashboardViewModel.fetchData` to batch panels that
/// share both an interpolated PromQL query *and* a datasource selector. Two
/// panels with the same query string but different per-query datasources
/// (Perses style) must hit different backends, so they cannot share a group.
fileprivate struct PanelQueryKey: Hashable {
    let query: String
    let datasource: DatasourceSelector?
}

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

    // MARK: - Annotations
    var annotations: [DashboardAnnotation] = []

// MARK: - Version Store
    let versionStore = DashboardVersionStore()

// MARK: - Explore
    var exploreQuery = ""
    var exploreResults: TimeSeriesData?
    var exploreQueryHistory: [ExploreQueryEntry] = []
    var isExploreLoading = false

    // MARK: - Auto-refresh
    private var refreshTimer: Timer?
    private var fetchTask: Task<Void, Never>?
    private var variableRefreshTask: Task<Void, Never>?
    private var exploreTask: Task<Void, Never>?

    // MARK: - Dependencies
    private let reportClient: TokiReportClient
    private let serverQueryClient: ServerQueryClient
    /// Active query client, swapped when `dataSource` changes.
    private var queryClient: any QueryDataSource
    let configStore = DashboardConfigStore()
    private let annotationStore = AnnotationStore()

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
            guard SyncManager.shared.isConfigured && !SyncManager.shared.isTokenExpired else {
                return DatasourceRegistry.shared.resolve(kind: BuiltinDatasourceKind.localCLI) ?? reportClient
            }
        }
        if let plugin = DatasourceRegistry.shared.resolve(activeDatasource) {
            return plugin
        }
        // Last-resort fallback so the dashboard never goes black.
        return reportClient
    }

    init(reportClient: TokiReportClient = TokiReportClient(),
         serverQueryClient: ServerQueryClient = ServerQueryClient()) {
        self.reportClient = reportClient
        self.serverQueryClient = serverQueryClient
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
    func refreshVariables() {
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
            .compactMap { v in v.plugin.map { (v.id, $0) } }
        guard !pairs.isEmpty else { return }
        // Cancel any in-flight refresh so a slower previous load can't
        // overwrite a faster, newer one (datasource switch race).
        variableRefreshTask?.cancel()
        variableRefreshTask = Task { [weak self] in
            for (varID, pluginRef) in pairs {
                if Task.isCancelled { return }
                guard let loader = VariablePluginRegistry.shared.loader(for: pluginRef.kind) else { continue }
                guard let options = try? await loader.loadOptions(specData: pluginRef.spec, context: context)
                else { continue }
                if Task.isCancelled { return }
                guard let self else { return }
                if let idx = self.dashboardConfig.templating.list.firstIndex(where: { $0.id == varID }) {
                    self.dashboardConfig.templating.list[idx].options = options
                }
            }
            if Task.isCancelled { return }
            self?.saveDashboard()
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

        let panels = dashboardConfig.panels.filter { $0.panelType != .rowPanel }
        let time = dashboardConfig.time

        // Mark all panels as loading (no stale data preserved)
        for panel in panels {
            panelData[panel.id] = .loading(previous: nil)
        }
        isLoading = true
        errorMessage = nil

        fetchTask = Task { [weak self] in
            guard let self else { return }

            // Resolve each panel's typed PromQL spec exactly once. The
            // previous code called `panel.effective{Metric,Query,Datasource}`
            // three times per panel per fetch — each one JSON-decoded the
            // same `query.spec.plugin.spec` blob.
            struct ResolvedPanel {
                let panel: PanelConfig
                let metric: PanelMetric
                let queryString: String?
                let datasource: DatasourceSelector?
            }
            let resolved: [ResolvedPanel] = panels.map { panel in
                let spec = panel.resolvedTokiQuery
                let metric = spec?.metric ?? panel.targets.first?.metric ?? panel.metric
                let queryString = spec?.query ?? panel.targets.first?.query
                return ResolvedPanel(
                    panel: panel,
                    metric: metric,
                    queryString: queryString,
                    datasource: panel.effectiveDatasource
                )
            }

            try? Task.checkCancellation()

            // Separate project panels (need special parsing) from regular panels
            let projectPanels = resolved.filter { $0.metric == .tokensByProject }.map(\.panel)
            let regularResolved = resolved.filter { $0.metric != .tokensByProject }

            // Build interpolated queries and group by (query, datasource) — a
            // panel may carry a per-query datasource override (Perses style),
            // in which case it must not be batched with panels hitting a
            // different backend.
            var queryGroups: [PanelQueryKey: [PanelConfig]] = [:]
            for r in regularResolved {
                let template = r.queryString ?? r.metric.defaultQuery
                let interpolated = interpolateQuery(template, time: time)
                let key = PanelQueryKey(query: interpolated, datasource: r.datasource)
                queryGroups[key, default: []].append(r.panel)
            }

            // Execute all queries concurrently. Each group resolves its own
            // client: per-panel datasource selector wins; otherwise the
            // dashboard's active client is used.
            let defaultClient = self.queryClient
            let activeSelector = self.activeDatasource
            var queryResults: [(PanelQueryKey, Result<TimeSeriesData, Error>)] = []
            await withTaskGroup(of: (PanelQueryKey, Result<TimeSeriesData, Error>).self) { group in
                for (key, _) in queryGroups {
                    let client: any QueryDataSource = {
                        if let ds = key.datasource,
                           ds != activeSelector,
                           let plugin = DatasourceRegistry.shared.resolve(ds) {
                            return plugin
                        }
                        return defaultClient
                    }()
                    group.addTask {
                        do {
                            let result = try await client.queryPromQLAsTimeSeries(query: key.query, time: time)
                            return (key, .success(result))
                        } catch {
                            return (key, .failure(error))
                        }
                    }
                }

                for await result in group {
                    queryResults.append(result)
                }
            }

            try? Task.checkCancellation()
            if Task.isCancelled { return }

            // Fetch project panels concurrently
            if !projectPanels.isEmpty {
                await fetchProjectPanels(projectPanels, time: time)
            }

            if Task.isCancelled { return }

            // Apply all results in one batch (single UI update)
            for (key, result) in queryResults {
                let affectedPanels = queryGroups[key] ?? []
                switch result {
                case .success(let data):
                    for panel in affectedPanels {
                        self.panelData[panel.id] = .loaded(data)
                    }
                case .failure(let error):
                    for panel in affectedPanels {
                        self.panelData[panel.id] = .error(error.localizedDescription)
                    }
                }
            }

            // Backward compatibility: set global timeSeriesData from first loaded regular panel
            if let firstLoaded = regularResolved.first(where: { panelData[$0.panel.id]?.timeSeriesData != nil }),
               let data = panelData[firstLoaded.panel.id]?.timeSeriesData {
                self.timeSeriesData = data
                self.enabledModels = Set(data.allModelNames)
                self.dataVersion += 1
            }

            self.isLoading = false
        }
    }

    // MARK: - Query Interpolation

    func interpolateQuery(_ template: String, time: TimeConfig? = nil) -> String {
        let t = time ?? dashboardConfig.time

        var query = template
        query = query.replacingOccurrences(of: "$__interval", with: t.bucketString)

        // Provider variable — special-cased: expands to a label matcher
        // expression rather than a bare value, because the query templates
        // embed it inside `{$provider}` placeholder positions.
        let selectedProvider: String? = {
            let raw = variableValue(named: "provider")
            let filtered = raw.filter { !$0.isEmpty && $0 != "All" && $0 != "all" && $0 != "$__all" }
            return filtered.first(where: { ["claude_code", "codex"].contains($0) })
        }()
        if let provider = selectedProvider {
            query = query.replacingOccurrences(of: "$provider", with: "provider=\"\(provider)\"")
        } else {
            query = query.replacingOccurrences(of: ", $provider", with: "")
            query = query.replacingOccurrences(of: "$provider", with: "")
        }

        // Generic variable interpolation — supports both `${name}` and `$name`
        // (Perses-style). Cascading: a variable's value can reference another
        // variable via the same syntax; we iterate to a fixed point so chains
        // resolve in one pass.
        //
        // Build the bare-form regex objects once per call (instead of
        // recompiling per fixpoint iteration × variable). The old code did
        // `templating.list.count × 4` `NSRegularExpression` constructions
        // per panel fetch — a 5-variable dashboard cost 20 regex compiles
        // per refresh just for interpolation.
        struct Compiled {
            let variable: DashboardVariable
            let value: String
            let bareForm: NSRegularExpression?
        }
        let compiled: [Compiled] = dashboardConfig.templating.list
            .filter { $0.name != "provider" }
            .map { v in
                let escaped = NSRegularExpression.escapedPattern(for: v.name)
                let pattern = "\\$\(escaped)(?![A-Za-z0-9_])"
                return Compiled(
                    variable: v,
                    value: interpolatedValue(for: v),
                    bareForm: try? NSRegularExpression(pattern: pattern)
                )
            }

        for _ in 0..<4 {
            let before = query
            for c in compiled {
                query = query.replacingOccurrences(of: "${\(c.variable.name)}", with: c.value)
                if let regex = c.bareForm {
                    let range = NSRange(query.startIndex..., in: query)
                    query = regex.stringByReplacingMatches(
                        in: query, range: range,
                        withTemplate: NSRegularExpression.escapedTemplate(for: c.value)
                    )
                }
            }
            if query == before { break }
        }

        return query
    }

    /// Resolve a variable to the string that should replace `$name` /
    /// `${name}`. Honors multi-select (joined as PromQL regex alternation),
    /// the "All" selection (→ `customAllValue`), and the optional
    /// `capturingRegexp` post-filter.
    private func interpolatedValue(for variable: DashboardVariable) -> String {
        let selection = variable.current.value
        // "All" sentinel — emit customAllValue (default `.*`)
        if variable.includeAll && (selection.contains("$__all") || selection.isEmpty) {
            return variable.effectiveCustomAllValue
        }

        let filtered = selection.filter { !$0.isEmpty && $0 != "$__all" }
        if filtered.isEmpty { return "" }

        let values: [String]
        if let pattern = variable.capturingRegexp, !pattern.isEmpty,
           let regex = try? NSRegularExpression(pattern: pattern) {
            values = filtered.map { raw in
                let range = NSRange(raw.startIndex..., in: raw)
                guard let m = regex.firstMatch(in: raw, range: range),
                      m.numberOfRanges > 1,
                      let r = Range(m.range(at: 1), in: raw)
                else { return raw }
                return String(raw[r])
            }
        } else {
            values = filtered
        }

        if variable.multi && values.count > 1 {
            return values.joined(separator: "|")
        }
        return values.first ?? ""
    }

    /// Fetch project-grouped data. toki returns "date|project" in period field.
    private func fetchProjectPanels(_ panels: [PanelConfig], time: TimeConfig) async {
        let template = PanelMetric.tokensByProject.defaultQuery
        let query = interpolateQuery(template, time: time)
        let isServer = queryClient is ServerQueryClient

        if isServer {
            // Server mode: use PromQL query via server proxy
            do {
                let data = try await queryClient.queryPromQLAsTimeSeries(query: query, time: time)
                for panel in panels {
                    panelData[panel.id] = .loaded(data)
                }
            } catch {
                for panel in panels {
                    panelData[panel.id] = .error(error.localizedDescription)
                }
            }
            return
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
                for panel in panels { panelData[panel.id] = .error("Parse error") }
                return
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
                panelData[panel.id] = .loaded(data)
            }
        } catch {
            for panel in panels {
                panelData[panel.id] = .error(error.localizedDescription)
            }
        }
    }

    /// Cache for resolved project names to avoid repeated FileManager.fileExists
    /// calls. `NSCache` bounds the size automatically (system evicts under
    /// memory pressure) — replaces the previous unbounded `[String: String]`
    /// dictionary that grew indefinitely across project paths.
    private static let projectNameCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 256
        return cache
    }()

    /// Extract last folder name from toki project paths.
    /// Claude Code encodes paths with - instead of /. Recover by splitting on -
    /// then greedily rebuilding the path, trying / then - then _ as joiners.
    static func cleanProjectName(_ raw: String) -> String {
        let key = raw as NSString
        if let cached = projectNameCache.object(forKey: key) {
            return cached as String
        }
        let result = resolveProjectName(raw)
        projectNameCache.setObject(result as NSString, forKey: key)
        return result
    }

    private static func resolveProjectName(_ raw: String) -> String {
        if raw.contains("/") {
            return URL(fileURLWithPath: raw).lastPathComponent
        }

        let segments = raw.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard segments.count > 1 else { return raw }

        let fm = FileManager.default
        var basePath = ""
        var projectStartIdx = 0

        // Build base path by consuming segments as directory levels
        for (i, segment) in segments.enumerated() {
            let candidate = basePath.isEmpty ? "/" + segment : basePath + "/" + segment
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                basePath = candidate
                projectStartIdx = i + 1
            } else {
                break
            }
        }

        // Remaining segments form the project name — try to find it on disk
        guard projectStartIdx < segments.count else {
            return URL(fileURLWithPath: basePath).lastPathComponent
        }

        let remaining = Array(segments[projectStartIdx...])

        // Greedily accumulate remaining segments, trying -, _ joiners to match a real folder
        var projectName = remaining[0]
        for seg in remaining.dropFirst() {
            // Try extending the project folder name with different joiners
            let candidates = [
                (basePath + "/" + projectName + "-" + seg, projectName + "-" + seg),
                (basePath + "/" + projectName + "_" + seg, projectName + "_" + seg),
            ]
            var found = false
            for (path, name) in candidates {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    projectName = name
                    found = true
                    break
                }
            }
            if !found {
                // This segment is a subdirectory — use what we have as base, reset project
                let subPath = basePath + "/" + projectName
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue {
                    basePath = subPath
                    projectName = seg
                } else {
                    projectName += "-" + seg
                }
            }
        }

        return projectName
    }

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
        dashboardConfig.templating.list.append(variable)
        saveDashboard()
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
        syncLayoutsWithPanels()
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
        // Plugin envelope: re-encode spec from current options when the kind
        // mismatches the panel type, or when no spec has been written yet.
        let expectedKind = BuiltinPanelPluginKind.kind(for: panel.panelType)
        let needsPluginRebuild = panel.plugin == nil
            || panel.plugin?.kind != expectedKind
            || (panel.plugin?.spec.isEmpty ?? true)
        if needsPluginRebuild {
            let specData = panel.options.encodedSpec(forPanelPluginKind: expectedKind) ?? Data()
            panel.plugin = PanelPluginRef(kind: expectedKind, spec: specData)
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
            panel.queries = sourceTargets.map { target in
                let spec = TokiPromQLQuerySpec(
                    datasource: nil, metric: target.metric, query: target.query
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

    func saveDashboard() {
        configStore.save(dashboardConfig)
        configStore.updateDashboardInList(dashboardConfig)
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

    func importDashboard() {
        guard var imported = configStore.importFromFile() else { return }
        // Migrate imported config to v4 and normalize each panel so plugin /
        // queries envelopes are accurate (imports might originate from
        // older exports or be hand-edited).
        if imported.schemaVersion < 4 {
            imported = DashboardConfig.migrateV3toV4(imported)
        }
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
    private func registerInlineDatasources() {
        for (_, instance) in dashboardConfig.datasources {
            if let plugin = DatasourceRegistry.shared.resolve(kind: instance.kind) {
                DatasourceRegistry.shared.registerNamed(name: instance.name, plugin: plugin)
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
        config = DashboardConfig.migrateV3toV4(config)
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

        // Save to history
        let entry = ExploreQueryEntry(query: exploreQuery)
        exploreQueryHistory.insert(entry, at: 0)
        if exploreQueryHistory.count > 50 {
            exploreQueryHistory = Array(exploreQueryHistory.prefix(50))
        }
        saveExploreHistory()

        let client = queryClient
        let time = dashboardConfig.time
        let interpolated = interpolateQuery(exploreQuery, time: time)

        // Cancel any in-flight explore query first — otherwise a slower
        // previous response can race in and overwrite the result of a
        // faster newer one (run twice → last-typed query loses).
        exploreTask?.cancel()
        exploreTask = Task { [weak self] in
            do {
                let data = try await client.queryPromQLAsTimeSeries(query: interpolated, time: time)
                if Task.isCancelled { return }
                guard let self else { return }
                self.isExploreLoading = false
                self.exploreResults = data
            } catch {
                if Task.isCancelled { return }
                guard let self else { return }
                self.isExploreLoading = false
                self.exploreResults = nil
            }
        }
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

    func colorForModel(_ model: String) -> Color {
        let lower = model.lowercased()
        // Check known models first
        for known in Self.knownModelColors {
            if lower.contains(known.prefix) {
                return known.color
            }
        }
        // Fallback: stable index from ALL models
        let allModels = (timeSeriesData?.allModelNames ?? []).sorted()
        let unknownModels = allModels.filter { m in
            !Self.knownModelColors.contains(where: { m.lowercased().contains($0.prefix) })
        }
        let index = unknownModels.firstIndex(of: model) ?? 0
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
