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
        if config.schemaVersion < 3 {
            config = DashboardConfig.migrateV2toV3(config)
            save(config)
        }
        if config.schemaVersion < 4 {
            config = DashboardConfig.migrateV3toV4(config)
            // Seed activeDatasource from the legacy global enum so the
            // dashboard remembers which backend the user was last using.
            if config.activeDatasource == nil,
               let raw = UserDefaults.standard.string(forKey: "dashboardDataSource"),
               let legacy = DashboardDataSource(rawValue: raw) {
                let kind = legacy == .server
                    ? BuiltinDatasourceKind.promQLProxy
                    : BuiltinDatasourceKind.localCLI
                config.activeDatasource = DatasourceSelector(kind: kind)
            }
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
              let raw = try? JSONDecoder().decode([DashboardConfig].self, from: data)
        else {
            return [load()]
        }
        // Apply migrations to each entry so the in-memory list always carries
        // the latest schema, even for entries written before this version.
        var migrated = false
        let list = raw.map { entry -> DashboardConfig in
            var c = entry
            if c.schemaVersion < 2 { c = DashboardConfig.migrateV1toV2(c); migrated = true }
            if c.schemaVersion < 3 { c = DashboardConfig.migrateV2toV3(c); migrated = true }
            if c.schemaVersion < 4 { c = DashboardConfig.migrateV3toV4(c); migrated = true }
            return c
        }
        if migrated { saveDashboardList(list) }
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
        var newConfig = config
        newConfig.title = uniqueTitle(config.title, in: list)
        list.append(newConfig)
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
        original.title = uniqueTitle(original.title, in: list)
        original.version = 1
        addDashboard(original)
        return original
    }

    func updateDashboardInList(_ config: DashboardConfig) {
        var list = loadDashboardList()
        // Match by title (unique key) or uid
        if let idx = list.firstIndex(where: { $0.title == config.title || $0.uid == config.uid }) {
            list[idx] = config
        }
        // Don't append if not found — prevents duplication
        saveDashboardList(list)
    }

    func dashboard(for uid: String) -> DashboardConfig? {
        loadDashboardList().first { $0.uid == uid }
    }

    /// Generate unique title by appending number if needed
    private func uniqueTitle(_ base: String, in list: [DashboardConfig]) -> String {
        let existingTitles = Set(list.map(\.title))
        if !existingTitles.contains(base) { return base }
        for i in 1... {
            let candidate = "\(base) \(i)"
            if !existingTitles.contains(candidate) { return candidate }
        }
        return base
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

    /// Default dashboard with 24-column grid layout (v4 schema).
    static var defaultConfig: DashboardConfig {
        let config = DashboardConfig(
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
        // Run through v4 migration so plugin/queries envelopes and layouts
        // are populated consistently with persisted dashboards.
        return DashboardConfig.migrateV3toV4(config)
    }
}
