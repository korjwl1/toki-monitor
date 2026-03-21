import Foundation

/// Persists dashboard layout configuration via UserDefaults.
@MainActor
final class DashboardConfigStore {
    private static let userDefaultsKey = "dashboardConfig"

    func load() -> DashboardConfig {
        guard let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
              let config = try? JSONDecoder().decode(DashboardConfig.self, from: data)
        else {
            return Self.defaultConfig
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

    // MARK: - Default Layout

    /// 7 panels matching the current dashboard layout:
    /// - 4 stat cards in row 0 (3 columns wide each at columns 0, 3, 6, 9)
    /// - Token trend timeSeries at (0,1) spanning 12x3
    /// - Cost trend timeSeries at (0,4) spanning 6x3
    /// - API trend barChart at (6,4) spanning 6x3
    static var defaultConfig: DashboardConfig {
        DashboardConfig(
            name: "Default",
            panels: [
                // Row 0: stat cards
                PanelConfig(
                    title: L.dash.totalTokens,
                    panelType: .stat,
                    metric: .totalTokens,
                    gridPosition: GridPosition(column: 0, row: 0, width: 3, height: 1)
                ),
                PanelConfig(
                    title: L.dash.totalCost,
                    panelType: .stat,
                    metric: .totalCost,
                    gridPosition: GridPosition(column: 3, row: 0, width: 3, height: 1)
                ),
                PanelConfig(
                    title: L.dash.apiCalls,
                    panelType: .stat,
                    metric: .apiCalls,
                    gridPosition: GridPosition(column: 6, row: 0, width: 3, height: 1)
                ),
                PanelConfig(
                    title: L.dash.topModel,
                    panelType: .stat,
                    metric: .topModel,
                    gridPosition: GridPosition(column: 9, row: 0, width: 3, height: 1)
                ),
                // Row 1-3: token trend (full width)
                PanelConfig(
                    title: L.dash.tokenTrend,
                    panelType: .timeSeries,
                    metric: .tokensByModel,
                    gridPosition: GridPosition(column: 0, row: 1, width: 12, height: 3)
                ),
                // Row 4-6: cost trend (left half)
                PanelConfig(
                    title: L.dash.costTrend,
                    panelType: .timeSeries,
                    metric: .costByModel,
                    gridPosition: GridPosition(column: 0, row: 4, width: 6, height: 3)
                ),
                // Row 4-6: API trend (right half)
                PanelConfig(
                    title: L.dash.apiTrend,
                    panelType: .barChart,
                    metric: .eventsByModel,
                    gridPosition: GridPosition(column: 6, row: 4, width: 6, height: 3)
                ),
            ]
        )
    }
}
