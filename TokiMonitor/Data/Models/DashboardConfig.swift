import Foundation

// MARK: - Dashboard Configuration

struct DashboardConfig: Codable, Equatable {
    var id: UUID = UUID()
    var name: String = "Default"
    var panels: [PanelConfig] = []
    var version: Int = 1
}

struct PanelConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var panelType: PanelType
    var metric: PanelMetric
    var gridPosition: GridPosition
}

struct GridPosition: Codable, Equatable {
    var column: Int    // 0-11 (12-column grid)
    var row: Int       // logical row
    var width: Int     // 1-12 columns
    var height: Int    // grid rows (1 row = 80pt)
}

// MARK: - Panel Type

enum PanelType: String, Codable, CaseIterable {
    case stat
    case timeSeries
    case barChart
    case table
    case gauge

    var displayName: String {
        switch self {
        case .stat: L.dash.statPanel
        case .timeSeries: L.dash.timeSeriesPanel
        case .barChart: L.dash.barChartPanel
        case .table: L.dash.tablePanel
        case .gauge: L.dash.gaugePanel
        }
    }

    var minWidth: Int {
        switch self {
        case .stat: 3
        case .timeSeries: 4
        case .barChart: 4
        case .table: 6
        case .gauge: 2
        }
    }

    var minHeight: Int {
        switch self {
        case .stat: 1
        case .timeSeries: 2
        case .barChart: 2
        case .table: 2
        case .gauge: 1
        }
    }
}

// MARK: - Panel Metric

enum PanelMetric: String, Codable, CaseIterable {
    case totalTokens
    case totalCost
    case apiCalls
    case topModel
    case tokensByModel
    case costByModel
    case eventsByModel
    case inputVsOutput
    case cacheHitRate
    case reasoningTokens
    case modelBreakdown

    var displayName: String {
        switch self {
        case .totalTokens: L.dash.metricTotalTokens
        case .totalCost: L.dash.metricTotalCost
        case .apiCalls: L.dash.metricApiCalls
        case .topModel: L.dash.metricTopModel
        case .tokensByModel: L.dash.metricTokensByModel
        case .costByModel: L.dash.metricCostByModel
        case .eventsByModel: L.dash.metricEventsByModel
        case .inputVsOutput: L.dash.metricInputVsOutput
        case .cacheHitRate: L.dash.metricCacheHitRate
        case .reasoningTokens: L.dash.metricReasoningTokens
        case .modelBreakdown: L.dash.metricModelBreakdown
        }
    }

    var compatiblePanelTypes: [PanelType] {
        switch self {
        case .totalTokens, .totalCost, .apiCalls, .topModel:
            return [.stat, .gauge]
        case .tokensByModel, .costByModel, .eventsByModel:
            return [.timeSeries, .barChart]
        case .inputVsOutput:
            return [.barChart, .timeSeries]
        case .cacheHitRate:
            return [.stat, .gauge, .timeSeries]
        case .reasoningTokens:
            return [.stat, .timeSeries, .barChart]
        case .modelBreakdown:
            return [.table, .barChart]
        }
    }

    var icon: String {
        switch self {
        case .totalTokens: "number"
        case .totalCost: "dollarsign.circle"
        case .apiCalls: "arrow.up.arrow.down"
        case .topModel: "star.fill"
        case .tokensByModel: "chart.xyaxis.line"
        case .costByModel: "chart.xyaxis.line"
        case .eventsByModel: "chart.bar"
        case .inputVsOutput: "arrow.left.arrow.right"
        case .cacheHitRate: "memorychip"
        case .reasoningTokens: "brain"
        case .modelBreakdown: "tablecells"
        }
    }
}
