import Foundation
import SwiftUI

@MainActor
@Observable
final class DashboardViewModel {
    var selectedTimeRange: DashboardTimeRange = .twentyFourHours {
        didSet { fetchData() }
    }
    var timeSeriesData: TimeSeriesData?
    var isLoading = false
    var errorMessage: String?
    var enabledModels: Set<String> = []

    // MARK: - Dashboard Layout

    var isEditing = false
    var dashboardConfig: DashboardConfig

    private let reportClient: TokiReportClient
    private let configStore = DashboardConfigStore()

    init(reportClient: TokiReportClient = TokiReportClient()) {
        self.reportClient = reportClient
        self.dashboardConfig = DashboardConfigStore().load()
    }

    func fetchData() {
        isLoading = true
        errorMessage = nil

        reportClient.queryTimeSeries(timeRange: selectedTimeRange) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let data):
                    self.timeSeriesData = data
                    // Initialize enabled models to all on first load
                    if self.enabledModels.isEmpty {
                        self.enabledModels = Set(data.allModelNames)
                    } else {
                        // Add any new models
                        self.enabledModels.formUnion(data.allModelNames)
                    }
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

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
    }

    /// Color for a model, based on provider
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
        // Vary opacity for multiple models in same provider
        let opacity = 1.0 - (Double(index) * 0.25)
        return baseColor.opacity(max(opacity, 0.4))
    }
}
