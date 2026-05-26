import Foundation

// MARK: - Dashboard Configuration (Grafana-inspired)

struct DashboardConfig: Codable, Equatable {
    var id: UUID = UUID()
    var uid: String = Self.generateUID()
    var title: String = "Default"
    var description: String?
    var tags: [String] = []
    var schemaVersion: Int = 3
    var version: Int = 1

    // Time configuration
    var time: TimeConfig = TimeConfig()
    var refresh: RefreshInterval = .off

    // Content
    var panels: [PanelConfig] = []
    var templating: TemplatingConfig = TemplatingConfig()

    // Perses-style inline datasources scoped to this dashboard.
    // Built-in defaults are provided by `DatasourceRegistry`; entries here
    // override or supplement them for this dashboard only.
    var datasources: [String: DatasourceInstance] = [:]

    // The active datasource selector for this dashboard. When nil, the
    // first registered default is used.
    var activeDatasource: DatasourceSelector?

    // Perses-style layouts. Optional; when nil the renderer drives off
    // `panels[].gridPosition` directly. v4+ encoders populate this so the
    // on-disk JSON is Perses-compatible.
    var layouts: [DashboardLayout]?

    // Annotations
    var annotations: [DashboardAnnotation] = []

    // Settings
    var editable: Bool = true

    // MARK: - Perses-style layout helpers
    //
    // The in-memory renderer still reads from `panels[].gridPosition`, but
    // these accessors let downstream code address panels by id-keyed `$ref`
    // (the Perses way) and pull positions out of a layout when one exists.

    /// Panels keyed by their stable id (UUID string). Mirrors Perses'
    /// `panels` map on disk.
    var panelMap: [String: PanelConfig] {
        Dictionary(uniqueKeysWithValues: panels.map { ($0.id.uuidString, $0) })
    }

    /// Panels in the order they appear in the first layout's `items`. Falls
    /// back to `panels` order when no layout is set.
    var panelsInLayoutOrder: [PanelConfig] {
        guard let layout = layouts?.first else { return panels }
        let map = panelMap
        return layout.spec.items.compactMap { item in
            guard let key = item.content.panelKey else { return nil }
            return map[key]
        }
    }

    /// The layout grid item that points at this panel, if any.
    func gridItem(for panel: PanelConfig) -> LayoutGridItem? {
        let key = panel.id.uuidString
        for layout in layouts ?? [] {
            if let item = layout.spec.items.first(where: { $0.content.panelKey == key }) {
                return item
            }
        }
        return nil
    }

    /// Effective grid position for a panel — layout-derived when available,
    /// otherwise the panel's own `gridPosition`. Both should agree post-v4;
    /// this just defines which side wins on disagreement (layout wins).
    func effectiveGridPosition(for panel: PanelConfig) -> GridPosition {
        if let item = gridItem(for: panel) {
            return GridPosition(column: item.x, row: item.y,
                                width: item.width, height: item.height)
        }
        return panel.gridPosition
    }

    static func generateUID() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<8).map { _ in chars.randomElement()! })
    }
}

// MARK: - Time Configuration

struct TimeConfig: Codable, Equatable {
    var from: String = "now-24h"
    var to: String = "now"

    /// Whether this is a relative time range (now-Xh) vs absolute (ISO date)
    var isRelative: Bool {
        from.hasPrefix("now")
    }

    /// Parsed duration in seconds
    var duration: TimeInterval {
        if isRelative {
            return parseRelativeTime(from)
        } else {
            // Absolute: parse ISO dates
            guard let fromDate = parseAbsoluteTime(from),
                  let toDate = parseAbsoluteTime(to) else { return 86400 }
            return toDate.timeIntervalSince(fromDate)
        }
    }

    /// Resolved start date
    var fromDate: Date {
        if isRelative {
            return Date().addingTimeInterval(-parseRelativeTime(from))
        } else {
            return parseAbsoluteTime(from) ?? Date().addingTimeInterval(-86400)
        }
    }

    /// Resolved end date
    var toDate: Date {
        if to == "now" || isRelative {
            return Date()
        } else {
            return parseAbsoluteTime(to) ?? Date()
        }
    }

    /// Bucket size in seconds — duration ÷ 15, minimum 1s
    var bucketSeconds: Int {
        return max(1, Int(duration / 15.0))
    }

    /// PromQL bucket string — converts seconds to compound duration (e.g. "4m", "12m30s", "1h20m")
    var bucketString: String {
        var secs = bucketSeconds
        var parts: [String] = []

        let hours = secs / 3600
        if hours > 0 {
            parts.append("\(hours)h")
            secs %= 3600
        }

        let minutes = secs / 60
        if minutes > 0 {
            parts.append("\(minutes)m")
            secs %= 60
        }

        if secs > 0 {
            parts.append("\(secs)s")
        }

        return parts.isEmpty ? "1s" : parts.joined()
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

    private func parseAbsoluteTime(_ str: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: str)
    }

    /// Create absolute time config from dates
    static func absolute(from: Date, to: Date) -> TimeConfig {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return TimeConfig(from: fmt.string(from: from), to: fmt.string(from: to))
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
    // `static var presets` lives in Presentation extension (localized labels).
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

    // MARK: - Perses-style fields (optional for v3 backward compat — Swift's
    // synthesized Codable does not apply default values when the JSON key is
    // missing, so these stay Optional and read through `effective*` computed
    // accessors below.)

    /// Value substituted for `$name` when the "All" item is selected.
    /// Defaults to `.*` (Prometheus regex match-all) via `effectiveCustomAllValue`.
    var customAllValue: String?

    /// Optional regex applied to each option's value before storage.
    /// Use a single capture group; the group's content replaces the value.
    var capturingRegexp: String?

    /// Sort order applied to options before the toolbar menu renders them.
    var sort: VariableSort?

    /// Perses-style plugin reference. When set, the registered loader for
    /// `plugin.kind` populates `options` instead of the legacy `query`/
    /// hand-managed `options` array. v3 dashboards that come in without a
    /// plugin keep their existing options unchanged.
    var plugin: VariablePluginRef?

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

    // MARK: - Effective accessors (apply defaults when Optional is nil)

    var effectiveCustomAllValue: String { customAllValue ?? ".*" }
    var effectiveSort: VariableSort { sort ?? .none }

    /// Options after `sort` is applied — the order the toolbar should render.
    var sortedOptions: [VariableOption] {
        effectiveSort.apply(options)
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

    // MARK: - Perses-style fields (optional; nil means "use legacy fields")

    /// Perses-style visualization plugin reference. When set, takes precedence
    /// over `panelType` for rendering decisions.
    var plugin: PanelPluginRef?

    /// Perses-style query envelopes. When non-empty, takes precedence over
    /// `targets` during data fetching.
    var queries: [Query]?

    /// Decoded `TokiPromQLQuerySpec` from this panel's first query envelope,
    /// or nil. A single decode lookup that all three `effective*`
    /// accessors share — calling them in a tight loop (fetchData) used
    /// to JSON-decode the same blob three times per panel per refresh.
    var resolvedTokiQuery: TokiPromQLQuerySpec? {
        guard let q = queries?.first,
              q.spec.plugin.kind == BuiltinQueryPluginKind.tokiPromQLQuery
        else { return nil }
        return try? JSONDecoder().decode(TokiPromQLQuerySpec.self, from: q.spec.plugin.spec)
    }

    /// The effective metric for this panel — prefers first target's metric, falls back to legacy field
    var effectiveMetric: PanelMetric {
        if let m = resolvedTokiQuery?.metric { return m }
        return targets.first?.metric ?? metric
    }

    /// The effective PromQL query, if any custom query is set
    var effectiveQuery: String? {
        if let q = resolvedTokiQuery?.query { return q }
        return targets.first?.query
    }

    /// Optional per-query datasource selector. Returns the first non-nil
    /// selector across `queries`, or nil to use the dashboard default.
    var effectiveDatasource: DatasourceSelector? {
        guard let queries else { return nil }
        let decoder = JSONDecoder()
        for q in queries {
            guard q.spec.plugin.kind == BuiltinQueryPluginKind.tokiPromQLQuery,
                  let spec = try? decoder.decode(TokiPromQLQuerySpec.self, from: q.spec.plugin.spec),
                  let ds = spec.datasource
            else { continue }
            return ds
        }
        return nil
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
    case pieChart
    case table
    case gauge
    case rowPanel

    /// Panel types available for user creation (excludes rowPanel from general picker)
    static var creatableTypes: [PanelType] {
        [.stat, .timeSeries, .barChart, .pieChart, .table, .gauge]
    }

    var minWidth: Int {
        switch self {
        case .stat: 4
        case .timeSeries: 6
        case .barChart: 6
        case .pieChart: 6
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
        case .pieChart: 3
        case .table: 3
        case .gauge: 2
        case .rowPanel: 1
        }
    }

    // `displayName` and `icon` live in Presentation extension (localized).
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
    case tokensByProject

    var compatiblePanelTypes: [PanelType] {
        switch self {
        case .totalTokens, .totalCost, .apiCalls, .topModel:
            return [.stat, .gauge]
        case .tokensByModel, .costByModel, .eventsByModel:
            return [.timeSeries, .barChart, .pieChart]
        case .inputVsOutput:
            return [.barChart, .timeSeries]
        case .cacheHitRate:
            return [.stat, .gauge, .timeSeries]
        case .reasoningTokens:
            return [.stat, .timeSeries, .barChart]
        case .modelBreakdown:
            return [.table, .barChart]
        case .tokensByProject:
            return [.pieChart, .barChart, .table]
        }
    }

    // `displayName` and `icon` live in Presentation extension (localized).

    /// Default PromQL query.
    /// Uses standard PromQL syntax accepted by both the local toki CLI and
    /// the toki-sync server PromQL proxy (VictoriaMetrics backend).
    /// $provider replaced by interpolateQuery; time range passed separately
    /// (--since/--until for CLI, start/end query params for server).
    var defaultQuery: String {
        switch self {
        case .totalTokens, .topModel:
            "sum by (model) (increase(usage{$provider}[$__interval]))"
        case .totalCost, .costByModel:
            "sum by (model) (increase(cost{$provider}[$__interval]))"
        case .apiCalls, .eventsByModel:
            "sum by (model) (increase(events{$provider}[$__interval]))"
        case .cacheHitRate, .reasoningTokens,
             .tokensByModel, .modelBreakdown, .inputVsOutput:
            "sum by (model) (increase(usage{$provider}[$__interval]))"
        case .tokensByProject:
            "sum by (project) (increase(usage{$provider}[$__interval]))"
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
    // `errorDescription` is provided by a Presentation extension so the
    // localized string lookup stays out of the Data layer.
}

// MARK: - Schema Migration

extension DashboardConfig {
    static var defaultTemplating: TemplatingConfig {
        let providerOptions = ProviderRegistry.configurableProviders.compactMap { provider -> VariableOption? in
            guard let tokiId = provider.tokiProviderId else { return nil }
            return VariableOption(text: provider.name, value: tokiId)
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
