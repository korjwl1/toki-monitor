import Foundation

// MARK: - Panel plugin (visualization)

/// Reference to a panel visualization plugin. `kind` selects the SwiftUI
/// renderer (e.g. `TimeSeriesChart`, `StatChart`), `spec` carries the
/// plugin-specific display options as a JSON-encoded blob.
///
/// During migration the legacy `PanelConfig.panelType` + `PanelConfig.options`
/// remain authoritative; `plugin` is consulted first when present so new
/// dashboards can be defined Perses-style without breaking old ones.
struct PanelPluginRef: Codable, Equatable, Sendable {
    var kind: String
    var spec: Data = Data()
}

/// Built-in panel plugin kinds. Map 1:1 to the existing `PanelType` enum so
/// migrations can do a straight rename.
enum BuiltinPanelPluginKind {
    static let timeSeriesChart = "TimeSeriesChart"
    static let statChart       = "StatChart"
    static let barChart        = "BarChart"
    static let pieChart        = "PieChart"
    static let tableChart      = "TableChart"
    static let gaugeChart      = "GaugeChart"
    static let row             = "Row"

    /// Reverse mapping back to the legacy `PanelType` enum so existing
    /// renderers (which still switch on `PanelType`) keep working.
    static func panelType(for kind: String) -> PanelType? {
        switch kind {
        case timeSeriesChart: return .timeSeries
        case statChart:       return .stat
        case barChart:        return .barChart
        case pieChart:        return .pieChart
        case tableChart:      return .table
        case gaugeChart:      return .gauge
        case row:             return .rowPanel
        default:              return nil
        }
    }

    static func kind(for panelType: PanelType) -> String {
        switch panelType {
        case .timeSeries: return timeSeriesChart
        case .stat:       return statChart
        case .barChart:   return barChart
        case .pieChart:   return pieChart
        case .table:      return tableChart
        case .gauge:      return gaugeChart
        case .rowPanel:   return row
        }
    }
}

// MARK: - Query plugin (data source side)

/// Outer query envelope. `kind` is the data-shape contract (e.g.
/// `TimeSeriesQuery` — the panel will receive time-indexed series),
/// `spec.plugin` is the concrete implementation.
///
/// Two-level kind/spec follows Perses: the outer kind lets a panel accept
/// any implementation that produces the right data shape; the inner plugin
/// kind picks the specific backend.
struct Query: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var kind: String = BuiltinQueryKind.timeSeriesQuery
    var spec: QuerySpec
}

struct QuerySpec: Codable, Equatable, Sendable {
    var name: String?
    var plugin: QueryPluginRef
}

struct QueryPluginRef: Codable, Equatable, Sendable {
    var kind: String
    var spec: Data = Data()
}

enum BuiltinQueryKind {
    /// Outer kind — the panel expects a time-indexed series response.
    static let timeSeriesQuery = "TimeSeriesQuery"
}

enum BuiltinQueryPluginKind {
    /// Inner kind — toki/PromQL backend. Same plugin handles local CLI and
    /// the sync server; the concrete `DatasourcePlugin` is resolved via the
    /// `datasource` selector inside the spec.
    static let tokiPromQLQuery = "TokiPromQLQuery"
}

/// Concrete spec for the `TokiPromQLQuery` plugin. Carries the datasource
/// selector (so different queries in one panel can target different
/// backends), an optional canned-metric identifier (legacy bridge), and an
/// optional raw PromQL override.
struct TokiPromQLQuerySpec: Codable, Equatable, Sendable {
    /// Which datasource to execute against. `nil` means "use the dashboard's
    /// `activeDatasource` selector".
    var datasource: DatasourceSelector?
    /// Legacy bridge: if set and `query` is nil, the default PromQL of this
    /// metric is used.
    var metric: PanelMetric?
    /// Raw PromQL override. Wins over `metric.defaultQuery`.
    var query: String?

    /// Resolve the effective PromQL string for this spec.
    var effectiveQuery: String? {
        if let q = query, !q.isEmpty { return q }
        return metric?.defaultQuery
    }
}
