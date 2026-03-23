import Foundation
import AppKit

/// Persists dashboard configurations. Supports multiple dashboards,
/// JSON import/export, and schema migration.
@MainActor
final class DashboardConfigStore {
    private static let userDefaultsKey = "dashboardConfig"
    private static let dashboardListKey = "dashboardList"
    private static let activeDashboardKey = "activeDashboardUID"

    // MARK: - Single Dashboard (backward compatible)

    func load() -> DashboardConfig {
        guard let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
              var config = try? JSONDecoder().decode(DashboardConfig.self, from: data)
        else {
            return Self.defaultConfig
        }
        // Migrate if needed
        if config.schemaVersion < 2 {
            config = DashboardConfig.migrateV1toV2(config)
            save(config)
        }
        return config
    }

    func save(_ config: DashboardConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    func resetToDefault() {
        save(Self.defaultConfig)
    }

    // MARK: - Dashboard List (multiple dashboards)

    func loadDashboardList() -> [DashboardConfig] {
        guard let data = UserDefaults.standard.data(forKey: Self.dashboardListKey),
              let list = try? JSONDecoder().decode([DashboardConfig].self, from: data)
        else {
            return [load()]
        }
        return list
    }

    func saveDashboardList(_ list: [DashboardConfig]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: Self.dashboardListKey)
    }

    var activeDashboardUID: String? {
        get { UserDefaults.standard.string(forKey: Self.activeDashboardKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.activeDashboardKey) }
    }

    // MARK: - Multi-Dashboard Operations

    func addDashboard(_ config: DashboardConfig) {
        var list = loadDashboardList()
        list.append(config)
        saveDashboardList(list)
    }

    func deleteDashboard(uid: String) {
        var list = loadDashboardList()
        list.removeAll { $0.uid == uid }
        saveDashboardList(list)
    }

    func duplicateDashboard(uid: String) -> DashboardConfig? {
        let list = loadDashboardList()
        guard var original = list.first(where: { $0.uid == uid }) else { return nil }
        original.id = UUID()
        original.uid = DashboardConfig.generateUID()
        original.title = original.title + " (Copy)"
        original.version = 1
        addDashboard(original)
        return original
    }

    func updateDashboardInList(_ config: DashboardConfig) {
        var list = loadDashboardList()
        if let idx = list.firstIndex(where: { $0.uid == config.uid }) {
            list[idx] = config
        } else {
            list.append(config)
        }
        saveDashboardList(list)
    }

    func dashboard(for uid: String) -> DashboardConfig? {
        loadDashboardList().first { $0.uid == uid }
    }

    // MARK: - JSON File Import/Export

    func exportToFile(_ config: DashboardConfig) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(config.title).json"
        panel.title = L.tr("대시보드 내보내기", "Export Dashboard")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try config.exportJSON()
            try data.write(to: url)
        } catch {
            // Error handled silently — could add alert later
        }
    }

    func importFromFile() -> DashboardConfig? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = L.tr("대시보드 가져오기", "Import Dashboard")

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let data = try Data(contentsOf: url)
            return try DashboardConfig.importJSON(data)
        } catch {
            return nil
        }
    }

    // MARK: - Default Layout (24-column grid)

    /// Default dashboard with 24-column grid layout
    static var defaultConfig: DashboardConfig {
        DashboardConfig(
            title: "Default",
            time: TimeConfig(from: "now-24h", to: "now"),
            refresh: .off,
            panels: [
                // Row 0: 4 stat cards (6 cols each)
                PanelConfig(
                    title: L.dash.totalTokens,
                    panelType: .stat,
                    metric: .totalTokens,
                    gridPosition: GridPosition(column: 0, row: 0, width: 6, height: 1),
                    targets: [PanelTarget(refId: "A", metric: .totalTokens)]
                ),
                PanelConfig(
                    title: L.dash.totalCost,
                    panelType: .stat,
                    metric: .totalCost,
                    gridPosition: GridPosition(column: 6, row: 0, width: 6, height: 1),
                    targets: [PanelTarget(refId: "A", metric: .totalCost)]
                ),
                PanelConfig(
                    title: L.dash.apiCalls,
                    panelType: .stat,
                    metric: .apiCalls,
                    gridPosition: GridPosition(column: 12, row: 0, width: 6, height: 1),
                    targets: [PanelTarget(refId: "A", metric: .apiCalls)]
                ),
                PanelConfig(
                    title: L.dash.topModel,
                    panelType: .stat,
                    metric: .topModel,
                    gridPosition: GridPosition(column: 18, row: 0, width: 6, height: 1),
                    targets: [PanelTarget(refId: "A", metric: .topModel)]
                ),
                // Row 1-3: token trend (full width)
                PanelConfig(
                    title: L.dash.tokenTrend,
                    panelType: .timeSeries,
                    metric: .tokensByModel,
                    gridPosition: GridPosition(column: 0, row: 1, width: 24, height: 3),
                    targets: [PanelTarget(refId: "A", metric: .tokensByModel)]
                ),
                // Row 4-6: project distribution pie (left half) + API trend (right half)
                PanelConfig(
                    title: L.tr("프로젝트별 사용량", "Usage by Project"),
                    panelType: .pieChart,
                    metric: .tokensByProject,
                    gridPosition: GridPosition(column: 0, row: 4, width: 12, height: 3),
                    targets: [PanelTarget(refId: "A", metric: .tokensByProject)]
                ),
                PanelConfig(
                    title: L.dash.apiTrend,
                    panelType: .barChart,
                    metric: .eventsByModel,
                    gridPosition: GridPosition(column: 12, row: 4, width: 12, height: 3),
                    targets: [PanelTarget(refId: "A", metric: .eventsByModel)]
                ),
            ],
            templating: DashboardConfig.defaultTemplating
        )
    }
}
