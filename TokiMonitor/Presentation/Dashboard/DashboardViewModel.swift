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
    var isLoading = false
    var errorMessage: String?
    var enabledModels: Set<String> = []

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
        let providerOptions = ProviderRegistry.configurableProviders.map { provider in
            VariableOption(text: provider.name, value: provider.id)
        }
        dashboardConfig.templating.list[index].options = providerOptions
        saveDashboard()
    }

    nonisolated func cleanupTimer() {
        // Timer cleanup is handled by setupAutoRefresh setting nil
    }

    // MARK: - Data Fetching

    func fetchData() {
        isLoading = true
        errorMessage = nil

        let time = dashboardConfig.time

        reportClient.queryTimeSeriesFromConfig(time: time) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let data):
                    self.timeSeriesData = data
                    if self.enabledModels.isEmpty {
                        self.enabledModels = Set(data.allModelNames)
                    } else {
                        self.enabledModels.formUnion(data.allModelNames)
                    }
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
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
        let from = dashboardConfig.time.from
        // Find matching preset
        if let preset = TimeRangePreset.presets.first(where: { $0.from == from }) {
            return preset.label
        }
        return from
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

        reportClient.queryPromQL(query: exploreQuery) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isExploreLoading = false
                switch result {
                case .success(let pointsByDate):
                    var points = pointsByDate.map { TimeSeriesPoint(date: $0.key, models: $0.value) }
                        .sorted { $0.date < $1.date }
                    self.exploreResults = TimeSeriesData(points: points, granularity: .hourly)
                case .failure:
                    self.exploreResults = nil
                }
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

    func colorForModel(_ model: String) -> Color {
        let provider = ProviderRegistry.resolve(model: model)
        let modelsForProvider = filteredModelNames.filter {
            ProviderRegistry.resolve(model: $0).id == provider.id
        }
        let index = modelsForProvider.firstIndex(of: model) ?? 0
        let baseColor = provider.color
        if modelsForProvider.count <= 1 {
            return baseColor
        }
        let opacity = 1.0 - (Double(index) * 0.25)
        return baseColor.opacity(max(opacity, 0.4))
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
