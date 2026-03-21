import Foundation
import SwiftUI
import Combine

@MainActor
@Observable
final class DashboardViewModel {
    // MARK: - Dashboard Config
    var dashboardConfig: DashboardConfig
    var isEditing = false

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

    // MARK: - Auto-refresh
    private var refreshTimer: Timer?

    // MARK: - Dependencies
    private let reportClient: TokiReportClient
    private let configStore = DashboardConfigStore()

    init(reportClient: TokiReportClient = TokiReportClient()) {
        self.reportClient = reportClient
        self.dashboardConfig = DashboardConfigStore().load()
        setupAutoRefresh()
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

    func saveDashboard() {
        configStore.save(dashboardConfig)
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
        configStore.loadDashboardList()
    }

    func switchDashboard(_ config: DashboardConfig) {
        dashboardConfig = config
        saveDashboard()
        configStore.activeDashboardUID = config.uid
        setupAutoRefresh()
        fetchData()
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
}
