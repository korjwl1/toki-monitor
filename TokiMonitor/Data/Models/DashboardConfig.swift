import Foundation

// MARK: - Dashboard Configuration (Grafana-inspired)

struct DashboardConfig: Codable, Equatable {
    var id: UUID = UUID()
    var uid: String = Self.generateUID()
    var title: String = "Default"
    var description: String?
    var tags: [String] = []
    var schemaVersion: Int = 2
    var version: Int = 1

    // Time configuration
    var time: TimeConfig = TimeConfig()
    var refresh: RefreshInterval = .off

    // Content
    var panels: [PanelConfig] = []
    var templating: TemplatingConfig = TemplatingConfig()

    // Annotations
    var annotations: [DashboardAnnotation] = []

    // Timezone
    var timezone: String = "UTC"

    // Settings
    var editable: Bool = true

    static func generateUID() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<8).map { _ in chars.randomElement()! })
    }
}

// MARK: - Time Configuration

struct TimeConfig: Codable, Equatable {
    var from: String = "now-24h"
    var to: String = "now"

    /// Parsed duration in seconds from "now-Xh/d" format
    var duration: TimeInterval {
        parseRelativeTime(from)
    }

    var granularity: TimeSeriesGranularity {
        if duration <= 3600 { return .fiveMinute }       // <= 1h: 5m buckets
        if duration <= 21600 { return .fifteenMinute }    // <= 6h: 15m buckets
        if duration <= 86400 { return .hourly }           // <= 24h: 1h buckets
        return .daily                                     // > 24h: 1d buckets
    }

    private func parseRelativeTime(_ str: String) -> TimeInterval {
        // Parse "now-6h", "now-24h", "now-7d", "now-30d" etc.
        guard str.hasPrefix("now-") else { return 86400 }
        let value = str.dropFirst(4)
        if value.hasSuffix("h"), let n = Double(value.dropLast()) {
            return n * 3600
        }
        if value.hasSuffix("d"), let n = Double(value.dropLast()) {
            return n * 86400
        }
        if value.hasSuffix("m"), let n = Double(value.dropLast()) {
            return n * 60
        }
        return 86400
    }
}

// MARK: - Refresh Interval

enum RefreshInterval: String, Codable, CaseIterable, Equatable {
    case off = ""
    case fiveSeconds = "5s"
    case tenSeconds = "10s"
    case thirtySeconds = "30s"
    case oneMinute = "1m"
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"

    var displayName: String {
        switch self {
        case .off: L.tr("끄기", "Off")
        case .fiveSeconds: "5s"
        case .tenSeconds: "10s"
        case .thirtySeconds: "30s"
        case .oneMinute: "1m"
        case .fiveMinutes: "5m"
        case .fifteenMinutes: "15m"
        case .thirtyMinutes: "30m"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .off: nil
        case .fiveSeconds: 5
        case .tenSeconds: 10
        case .thirtySeconds: 30
        case .oneMinute: 60
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .thirtyMinutes: 1800
        }
    }
}

// MARK: - Time Range Presets (for quick select)

struct TimeRangePreset: Identifiable, Equatable {
    let id: String
    let label: String
    let from: String

    static let presets: [TimeRangePreset] = [
        TimeRangePreset(id: "5m", label: L.tr("최근 5분", "Last 5 minutes"), from: "now-5m"),
        TimeRangePreset(id: "15m", label: L.tr("최근 15분", "Last 15 minutes"), from: "now-15m"),
        TimeRangePreset(id: "30m", label: L.tr("최근 30분", "Last 30 minutes"), from: "now-30m"),
        TimeRangePreset(id: "1h", label: L.tr("최근 1시간", "Last 1 hour"), from: "now-1h"),
        TimeRangePreset(id: "3h", label: L.tr("최근 3시간", "Last 3 hours"), from: "now-3h"),
        TimeRangePreset(id: "6h", label: L.tr("최근 6시간", "Last 6 hours"), from: "now-6h"),
        TimeRangePreset(id: "12h", label: L.tr("최근 12시간", "Last 12 hours"), from: "now-12h"),
        TimeRangePreset(id: "24h", label: L.tr("최근 24시간", "Last 24 hours"), from: "now-24h"),
        TimeRangePreset(id: "2d", label: L.tr("최근 2일", "Last 2 days"), from: "now-2d"),
        TimeRangePreset(id: "7d", label: L.tr("최근 7일", "Last 7 days"), from: "now-7d"),
        TimeRangePreset(id: "14d", label: L.tr("최근 14일", "Last 14 days"), from: "now-14d"),
        TimeRangePreset(id: "30d", label: L.tr("최근 30일", "Last 30 days"), from: "now-30d"),
    ]
}

// MARK: - Templating / Variables

struct TemplatingConfig: Codable, Equatable {
    var list: [DashboardVariable] = []
}

struct DashboardVariable: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var label: String?
    var type: VariableType
    var query: String = ""  // comma-separated values for custom, or query for query type
    var current: VariableSelection = VariableSelection()
    var options: [VariableOption] = []
    var multi: Bool = false
    var includeAll: Bool = false
    var hide: VariableHide = .visible
    var refresh: VariableRefresh = .onDashboardLoad

    enum VariableType: String, Codable, CaseIterable, Equatable {
        case custom
        case interval
    }

    enum VariableHide: Int, Codable, Equatable {
        case visible = 0
        case hideLabel = 1
        case hidden = 2
    }

    enum VariableRefresh: Int, Codable, Equatable {
        case never = 0
        case onDashboardLoad = 1
        case onTimeRangeChanged = 2
    }
}

struct VariableSelection: Codable, Equatable {
    var text: [String] = []
    var value: [String] = []
}

struct VariableOption: Codable, Equatable {
    var text: String
    var value: String
    var selected: Bool = false
}

// MARK: - Panel Configuration

struct PanelConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var description: String?
    var panelType: PanelType
    var metric: PanelMetric
    var gridPosition: GridPosition

    // Query targets (Grafana-style: each panel owns its queries)
    var targets: [PanelTarget] = []

    // Panel-specific display options
    var options: PanelDisplayOptions = PanelDisplayOptions()

    // Data links for drill-down
    var dataLinks: [DataLink] = []

    // Row panel: collapsed state
    var collapsed: Bool = false

    /// The effective metric for this panel — prefers first target's metric, falls back to legacy field
    var effectiveMetric: PanelMetric {
        targets.first?.metric ?? metric
    }

    /// The effective PromQL query, if any custom query is set
    var effectiveQuery: String? {
        targets.first?.query
    }
}

struct PanelTarget: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var refId: String = "A"
    var metric: PanelMetric
    var query: String?  // optional custom PromQL override
}

struct PanelDisplayOptions: Codable, Equatable {
    // Stat panel
    var colorMode: ColorMode = .value
    var graphMode: GraphMode = .none

    // Time series / bar chart
    var legendPosition: LegendPosition = .bottom
    var showLegend: Bool = true
    var tooltipMode: TooltipMode = .single
    var fillOpacity: Double = 0.1
    var lineWidth: Double = 2

    // Table
    var showHeader: Bool = true

    // Gauge
    var showThresholdMarkers: Bool = true

    // Field config
    var unit: String?
    var decimals: Int?
    var thresholds: [ThresholdStep] = []

    enum ColorMode: String, Codable, CaseIterable, Equatable {
        case value
        case background
        case none
    }

    enum GraphMode: String, Codable, CaseIterable, Equatable {
        case none
        case area
        case line
    }

    enum LegendPosition: String, Codable, CaseIterable, Equatable {
        case bottom
        case right
        case hidden
    }

    enum TooltipMode: String, Codable, CaseIterable, Equatable {
        case single
        case all
        case hidden
    }
}

struct ThresholdStep: Codable, Equatable {
    var value: Double
    var color: String  // hex color or named color
}

struct GridPosition: Codable, Equatable {
    var column: Int    // 0-23 (24-column grid like Grafana)
    var row: Int       // logical row
    var width: Int     // 1-24 columns
    var height: Int    // grid rows (1 row = 80pt)
}

// MARK: - Panel Type

enum PanelType: String, Codable, CaseIterable {
    case stat
    case timeSeries
    case barChart
    case table
    case gauge
    case rowPanel

    /// Panel types available for user creation (excludes rowPanel from general picker)
    static var creatableTypes: [PanelType] {
        [.stat, .timeSeries, .barChart, .table, .gauge]
    }

    var displayName: String {
        switch self {
        case .stat: L.dash.statPanel
        case .timeSeries: L.dash.timeSeriesPanel
        case .barChart: L.dash.barChartPanel
        case .table: L.dash.tablePanel
        case .gauge: L.dash.gaugePanel
        case .rowPanel: L.tr("행", "Row")
        }
    }

    var minWidth: Int {
        switch self {
        case .stat: 4
        case .timeSeries: 6
        case .barChart: 6
        case .table: 8
        case .gauge: 4
        case .rowPanel: 24
        }
    }

    var minHeight: Int {
        switch self {
        case .stat: 1
        case .timeSeries: 3
        case .barChart: 3
        case .table: 3
        case .gauge: 2
        case .rowPanel: 1
        }
    }

    var icon: String {
        switch self {
        case .stat: "number.square"
        case .timeSeries: "chart.xyaxis.line"
        case .barChart: "chart.bar"
        case .table: "tablecells"
        case .gauge: "gauge.open.with.lines.needle.33percent"
        case .rowPanel: "rectangle.split.1x2"
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

    /// Default PromQL template for this metric
    var defaultQuery: String {
        switch self {
        case .totalTokens: "sum(usage{since=\"$__from\"}[$__interval]) by (model)"
        case .totalCost: "sum(cost{since=\"$__from\"}[$__interval]) by (model)"
        case .apiCalls: "count(usage{since=\"$__from\"}[$__interval]) by (model)"
        case .topModel: "topk(1, sum(usage{since=\"$__from\"}[$__interval]) by (model))"
        case .tokensByModel: "usage{since=\"$__from\"}[$__interval] by (model)"
        case .costByModel: "cost{since=\"$__from\"}[$__interval] by (model)"
        case .eventsByModel: "events{since=\"$__from\"}[$__interval] by (model)"
        case .inputVsOutput: "usage{since=\"$__from\", type=\"input|output\"}[$__interval] by (model)"
        case .cacheHitRate: "rate(cache_read{since=\"$__from\"}[$__interval]) / rate(input{since=\"$__from\"}[$__interval])"
        case .reasoningTokens: "reasoning{since=\"$__from\"}[$__interval] by (model)"
        case .modelBreakdown: "usage{since=\"$__from\"}[$__interval] by (model)"
        }
    }
}

// MARK: - JSON Import/Export

extension DashboardConfig {
    /// Export dashboard as shareable JSON
    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Export as JSON string
    func exportJSONString() throws -> String {
        let data = try exportJSON()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Import dashboard from JSON data
    static func importJSON(_ data: Data) throws -> DashboardConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var config = try decoder.decode(DashboardConfig.self, from: data)
        // Generate new IDs to avoid conflicts
        config.id = UUID()
        config.uid = generateUID()
        config.version = 1
        return config
    }

    /// Import from JSON string
    static func importJSONString(_ json: String) throws -> DashboardConfig {
        guard let data = json.data(using: .utf8) else {
            throw DashboardImportError.invalidJSON
        }
        return try importJSON(data)
    }
}

enum DashboardImportError: Error, LocalizedError {
    case invalidJSON
    case incompatibleVersion

    var errorDescription: String? {
        switch self {
        case .invalidJSON: L.tr("잘못된 JSON 형식입니다", "Invalid JSON format")
        case .incompatibleVersion: L.tr("호환되지 않는 대시보드 버전입니다", "Incompatible dashboard version")
        }
    }
}

// MARK: - Schema Migration

extension DashboardConfig {
    /// Migrate from v1 (12-column grid) to v2 (24-column grid)
    static func migrateV1toV2(_ config: DashboardConfig) -> DashboardConfig {
        var migrated = config
        migrated.schemaVersion = 2
        migrated.panels = config.panels.map { panel in
            var p = panel
            // Double column positions and widths for 24-col grid
            p.gridPosition.column *= 2
            p.gridPosition.width *= 2
            // Populate targets from legacy metric field
            if p.targets.isEmpty {
                p.targets = [PanelTarget(refId: "A", metric: p.metric)]
            }
            return p
        }
        // Add default variables if none exist
        if migrated.templating.list.isEmpty {
            migrated.templating = Self.defaultTemplating
        }
        return migrated
    }

    static var defaultTemplating: TemplatingConfig {
        let providerOptions = ProviderRegistry.allProviders.map { provider in
            VariableOption(text: provider.name, value: provider.id)
        }
        return TemplatingConfig(list: [
            DashboardVariable(
                name: "provider",
                label: L.tr("프로바이더", "Provider"),
                type: .custom,
                query: "all",
                current: VariableSelection(text: ["All"], value: ["$__all"]),
                options: providerOptions,
                multi: true,
                includeAll: true
            ),
        ])
    }
}
