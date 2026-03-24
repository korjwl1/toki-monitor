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

    // MARK: - Alert Manager
    let alertManager = AlertManager()

    // MARK: - Version Store
    let versionStore = DashboardVersionStore()

    // MARK: - Playlist Manager
    let playlistManager = PlaylistManager()

    // MARK: - Explore
    var exploreQuery = ""
    var exploreResults: TimeSeriesData?
    var exploreQueryHistory: [ExploreQueryEntry] = []
    var isExploreLoading = false

    // MARK: - Auto-refresh
    private var refreshTimer: Timer?

    // MARK: - Dependencies
    private let reportClient: TokiReportClient
    let configStore = DashboardConfigStore()
    private let annotationStore = AnnotationStore()

    init(reportClient: TokiReportClient = TokiReportClient()) {
        self.reportClient = reportClient
        self.dashboardConfig = DashboardConfigStore().load()
        self.dashboardList = DashboardConfigStore().loadDashboardList()
        populateProviderOptions()
        loadAnnotations()
        loadExploreHistory()
        setupAutoRefresh()
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

    nonisolated func cleanupTimer() {
        // Timer cleanup is handled by setupAutoRefresh setting nil
    }

    // MARK: - Data Fetching

    func dataState(for panelID: UUID) -> PanelDataState {
        panelData[panelID] ?? .idle
    }

    func fetchData() {
        let panels = dashboardConfig.panels.filter { $0.panelType != .rowPanel }
        let time = dashboardConfig.time

        // Mark all panels as loading, preserving previous data
        for panel in panels {
            let previous = panelData[panel.id]?.timeSeriesData
            panelData[panel.id] = .loading(previous: previous)
        }
        isLoading = true
        errorMessage = nil

        Task {
            // Separate project panels (need special parsing) from regular panels
            let projectPanels = panels.filter { $0.effectiveMetric == .tokensByProject }
            let regularPanels = panels.filter { $0.effectiveMetric != .tokensByProject }

            // Build interpolated queries and group by unique query string
            var queryGroups: [String: [PanelConfig]] = [:]
            for panel in regularPanels {
                let template = panel.effectiveQuery ?? panel.effectiveMetric.defaultQuery
                let interpolated = interpolateQuery(template, time: time)
                queryGroups[interpolated, default: []].append(panel)
            }

            // Execute all queries concurrently, collect results
            var queryResults: [(String, Result<TimeSeriesData, Error>)] = []
            await withTaskGroup(of: (String, Result<TimeSeriesData, Error>).self) { group in
                for (query, _) in queryGroups {
                    group.addTask { [reportClient] in
                        do {
                            let result = try await reportClient.queryPromQLAsTimeSeries(query: query, time: time)
                            return (query, .success(result))
                        } catch {
                            return (query, .failure(error))
                        }
                    }
                }

                for await result in group {
                    queryResults.append(result)
                }
            }

            // Fetch project panels concurrently
            if !projectPanels.isEmpty {
                await fetchProjectPanels(projectPanels, time: time)
            }

            // Apply all results in one batch (single UI update)
            for (query, result) in queryResults {
                let affectedPanels = queryGroups[query] ?? []
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
            if let firstLoaded = regularPanels.first(where: { panelData[$0.id]?.timeSeriesData != nil }) {
                let data = panelData[firstLoaded.id]!.timeSeriesData!
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
        let sinceFmt = DateFormatter()
        sinceFmt.dateFormat = "yyyyMMddHHmmss"
        sinceFmt.timeZone = TimeZone(identifier: "UTC")

        let buffer = max(60, t.duration * 0.1)
        let sinceDate = t.fromDate.addingTimeInterval(-buffer)

        var query = template
        query = query.replacingOccurrences(of: "$__from", with: sinceFmt.string(from: sinceDate))
        if !t.isRelative {
            query = query.replacingOccurrences(of: "$__to", with: sinceFmt.string(from: t.toDate))
        } else {
            // Remove until clause for relative time
            query = query.replacingOccurrences(of: ", until=\"$__to\"", with: "")
        }
        query = query.replacingOccurrences(of: "$__interval", with: t.bucketString)

        // Provider variable
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

        // Generic variable interpolation
        for variable in dashboardConfig.templating.list {
            let value = variable.current.value.first ?? ""
            query = query.replacingOccurrences(of: "${\(variable.name)}", with: value)
        }

        return query
    }

    /// Fetch project-grouped data. toki returns "date|project" in period field.
    private func fetchProjectPanels(_ panels: [PanelConfig], time: TimeConfig) async {
        let template = PanelMetric.tokensByProject.defaultQuery
        let query = interpolateQuery(template, time: time)

        do {
            let rawData = try await CLIProcessRunner.run(
                executable: TokiPath.resolved,
                arguments: ["report", "-z", "UTC", "--output-format", "json", "query", query]
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

    /// Extract last folder name from toki project paths.
    /// Claude Code encodes paths with - instead of /. Recover by splitting on -
    /// then greedily rebuilding the path, trying / then - then _ as joiners.
    static func cleanProjectName(_ raw: String) -> String {
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
        dashboardConfig.panels.append(panel)
        saveDashboard()
    }

    func removePanel(id: UUID) {
        dashboardConfig.panels.removeAll { $0.id == id }
        saveDashboard()
    }

    func updatePanel(_ panel: PanelConfig) {
        guard let index = dashboardConfig.panels.firstIndex(where: { $0.id == panel.id }) else { return }
        dashboardConfig.panels[index] = panel
        saveDashboard()
    }

    func updatePanelPosition(id: UUID, position: GridPosition) {
        guard let index = dashboardConfig.panels.firstIndex(where: { $0.id == id }) else { return }
        dashboardConfig.panels[index].gridPosition = position
        saveDashboard()
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
        guard let imported = configStore.importFromFile() else { return }
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
        populateProviderOptions()
        saveDashboard()
        configStore.activeDashboardUID = config.uid
        collapsedRows = Set(config.panels.filter(\.collapsed).map(\.id))
        loadAnnotations()
        setupAutoRefresh()
        fetchData()
    }

    func switchDashboard(uid: String) {
        guard let config = configStore.dashboard(for: uid) else { return }
        switchDashboard(config)
    }

    func createNewDashboard(title: String = "New Dashboard") {
        var config = DashboardConfig()
        config.title = title
        config.templating = DashboardConfig.defaultTemplating
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

        Task {
            do {
                let pointsByDate = try await reportClient.queryPromQL(query: exploreQuery)
                self.isExploreLoading = false
                let points = pointsByDate.map { TimeSeriesPoint(date: $0.key, models: $0.value) }
                    .sorted { $0.date < $1.date }
                self.exploreResults = TimeSeriesData(points: points, granularity: .hourly)
            } catch {
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
