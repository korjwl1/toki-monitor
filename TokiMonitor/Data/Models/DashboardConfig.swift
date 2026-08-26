import Foundation

// MARK: - Dashboard Configuration (Grafana-inspired)

struct DashboardConfig: Codable, Equatable {
    var id: UUID = UUID()
    var uid: String = Self.generateUID()
    var title: String = "Default"
    var description: String?
    var tags: [String] = []
    // Match `DashboardMigrator.currentVersion` so freshly-constructed
    // configs (e.g. `DashboardConfig()` inside the VM) are already
    // v4-shaped. Anything legacy still loads via the migrator chain,
    // but in-memory creators no longer rely on a follow-up migrate to
    // populate the v4 envelopes.
    var schemaVersion: Int = 4
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

    /// Dashboard-level keys written by a build newer than this one, kept
    /// verbatim so a load→save here does not erase them (계약 C1).
    var unknownFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, uid, title, description, tags, schemaVersion, version
        case time, refresh, panels, templating, datasources, activeDatasource
        case layouts, annotations, editable
    }

    static let knownKeys: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))

    /// True when the document was written against a schema this build does not
    /// understand. Such a document opens read-only and is written back as the
    /// original bytes rather than re-encoded (계약 C2).
    var isReadOnlyForThisBuild: Bool {
        schemaVersion > DashboardMigrator.currentVersion
    }

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

// MARK: - DashboardConfig Codable (unknown-key preserving)
//
// Written by hand rather than synthesized so that keys this build has no field
// for survive the round trip. The implementations live in an extension so the
// memberwise initializer is still synthesized for the callers that use it.

extension DashboardConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        uid = try c.decode(String.self, forKey: .uid)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        tags = try c.decode([String].self, forKey: .tags)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        version = try c.decode(Int.self, forKey: .version)
        time = try c.decode(TimeConfig.self, forKey: .time)
        refresh = try c.decode(RefreshInterval.self, forKey: .refresh)
        panels = try c.decode([PanelConfig].self, forKey: .panels)
        templating = try c.decode(TemplatingConfig.self, forKey: .templating)
        // Optional, and this is not a style preference. Every dashboard the
        // shipped release wrote predates this key, so a required decode here
        // throws keyNotFound on every existing installation, the store falls
        // back to a freshly-uid'd default, and the user's dashboard looks
        // factory-reset. PanelDisplayOptions below carries a comment about
        // exactly this hazard; it was reintroduced one level up.
        datasources = try c.decodeIfPresent([String: DatasourceInstance].self, forKey: .datasources) ?? [:]
        activeDatasource = try c.decodeIfPresent(DatasourceSelector.self, forKey: .activeDatasource)
        layouts = try c.decodeIfPresent([DashboardLayout].self, forKey: .layouts)
        annotations = try c.decode([DashboardAnnotation].self, forKey: .annotations)
        editable = try c.decode(Bool.self, forKey: .editable)
        unknownFields = decoder.unknownFields(besides: Self.knownKeys)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(uid, forKey: .uid)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(tags, forKey: .tags)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(version, forKey: .version)
        try c.encode(time, forKey: .time)
        try c.encode(refresh, forKey: .refresh)
        try c.encode(panels, forKey: .panels)
        try c.encode(templating, forKey: .templating)
        try c.encode(datasources, forKey: .datasources)
        try c.encodeIfPresent(activeDatasource, forKey: .activeDatasource)
        try c.encodeIfPresent(layouts, forKey: .layouts)
        try c.encode(annotations, forKey: .annotations)
        try c.encode(editable, forKey: .editable)
        try encoder.encodeUnknownFields(unknownFields, besides: Self.knownKeys)
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
    /// Empty-string raw value matches what existing user configs already
    /// have on disk; changing it to `"off"` would require a Codable
    /// migrator. Keeping `""` is intentional, not an oversight.
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

    /// Filters the reader added to an ad hoc variable. Unlike every other
    /// kind, these are not substituted at a `$name` the author wrote — they
    /// are injected into each panel's own matcher block, so they have no
    /// natural home in `current`, which holds one selection from a list.
    var adHocFilters: [AdHocFilter]?

    /// Variable-level keys written by a build newer than this one, kept
    /// verbatim through load→save (계약 C1).
    var unknownFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, label, type, query, current, options, multi, includeAll
        case hide, refresh, customAllValue, capturingRegexp, sort, plugin
        case adHocFilters
    }

    static let knownKeys: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))

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

    /// Which plugin drives this variable. Pre-v4 dashboards carry no `plugin`
    /// ref, so the legacy `type` enum maps onto one.
    var effectivePluginKind: String {
        if let kind = plugin?.kind { return kind }
        switch type {
        case .interval: return BuiltinVariablePluginKind.interval
        case .custom:   return BuiltinVariablePluginKind.staticList
        }
    }

    /// A constant is the author's, not the reader's: it exists to name a
    /// repeated literal once, and a toolbar control offering one unchangeable
    /// item is noise. Grafana hides it for the same reason.
    var isReaderControllable: Bool {
        effectivePluginKind != BuiltinVariablePluginKind.constant
    }

    /// How this variable's values are written when the template names no
    /// format. It follows from what the variable MEANS: a groupBy holds
    /// dimension names and belongs in `by (a, b)`, everything else holds
    /// values and belongs in a `=~` matcher as `a|b`.
    var defaultFormat: VariableFormat {
        effectivePluginKind == BuiltinVariablePluginKind.groupBy ? .csv : .pipe
    }

    /// Options after `sort` is applied — the order the toolbar should render.
    var sortedOptions: [VariableOption] {
        effectiveSort.apply(options)
    }
}

// MARK: - DashboardVariable Codable (unknown-key preserving)

extension DashboardVariable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        type = try c.decode(VariableType.self, forKey: .type)
        query = try c.decode(String.self, forKey: .query)
        current = try c.decode(VariableSelection.self, forKey: .current)
        options = try c.decode([VariableOption].self, forKey: .options)
        multi = try c.decode(Bool.self, forKey: .multi)
        includeAll = try c.decode(Bool.self, forKey: .includeAll)
        hide = try c.decode(VariableHide.self, forKey: .hide)
        refresh = try c.decode(VariableRefresh.self, forKey: .refresh)
        customAllValue = try c.decodeIfPresent(String.self, forKey: .customAllValue)
        capturingRegexp = try c.decodeIfPresent(String.self, forKey: .capturingRegexp)
        sort = try c.decodeIfPresent(VariableSort.self, forKey: .sort)
        plugin = try c.decodeIfPresent(VariablePluginRef.self, forKey: .plugin)
        adHocFilters = try c.decodeIfPresent([AdHocFilter].self, forKey: .adHocFilters)
        unknownFields = decoder.unknownFields(besides: Self.knownKeys)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(type, forKey: .type)
        try c.encode(query, forKey: .query)
        try c.encode(current, forKey: .current)
        try c.encode(options, forKey: .options)
        try c.encode(multi, forKey: .multi)
        try c.encode(includeAll, forKey: .includeAll)
        try c.encode(hide, forKey: .hide)
        try c.encode(refresh, forKey: .refresh)
        try c.encodeIfPresent(customAllValue, forKey: .customAllValue)
        try c.encodeIfPresent(capturingRegexp, forKey: .capturingRegexp)
        try c.encodeIfPresent(sort, forKey: .sort)
        try c.encodeIfPresent(plugin, forKey: .plugin)
        try c.encodeIfPresent(adHocFilters, forKey: .adHocFilters)
        try encoder.encodeUnknownFields(unknownFields, besides: Self.knownKeys)
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

    /// Per-field display configuration: defaults plus matcher-based overrides.
    /// Optional so existing dashboards decode unchanged and keep rendering
    /// from `options`; a panel that has never been edited has no rules and
    /// resolves to exactly what it showed before.
    var fieldConfig: FieldConfigSource?

    /// Steps run over this panel's frames before it draws them, in order.
    ///
    /// The pipeline and its six transformations have existed with tests since
    /// the frame contract landed; what did not exist was anywhere to put the
    /// user's own steps, so only the hardcoded preset path ever ran. Empty on
    /// every panel that has not been given one, and omitted from the encoded
    /// form when empty so dashboards written before this field re-encode
    /// unchanged.
    var transformations: [TransformationStep] = []

    /// Which field a visualization reads, and how it collapses it. Nil means
    /// "use the preset for `metric`", which is what every existing panel does.
    var fieldSelection: FieldSelection?

    // MARK: - Repeat (contract US4)

    /// Name of the variable this panel repeats over. One panel is drawn per
    /// selected value of it; nil — which is nearly every panel — is one panel.
    ///
    /// Backticked because `repeat` is a keyword. The JSON key is `repeat`
    /// too, matching what a Grafana dashboard writes, so a dashboard authored
    /// there keeps its repeats when it arrives here.
    var `repeat`: String?

    /// Which way the copies are laid out. Nil means `.horizontal`, which is
    /// what a reader expects of "one per project": a row of them.
    var repeatDirection: RepeatDirection?

    // MARK: - Panel time (FR-037)

    /// This panel's own window instead of the dashboard's — "1h", "7d".
    ///
    /// Nil on every panel that follows the toolbar, which is nearly all of
    /// them. A panel that sets it MUST show that it has: see
    /// `PanelTimeOverride.label(for:)` and the badge in `PanelContainerView`.
    var relativeTime: String?

    /// Move this panel's window back by this much — "1d", "1w".
    ///
    /// Applied after `relativeTime`, so the two compose as "the last hour, a
    /// day ago".
    var timeShift: String?

    /// Panel-level keys written by a build newer than this one, kept verbatim
    /// through load→save (계약 C1).
    var unknownFields: [String: JSONValue] = [:]

    // MARK: - Derived at render time, never stored

    /// The value this instance was expanded for, on a panel produced by a
    /// `repeat`. Nil on every stored panel.
    ///
    /// Not in `CodingKeys`, so it is never written: it is derived from what
    /// the variable happens to be set to right now, and persisting it would
    /// freeze today's selection into the document.
    var repeatedValue: String?

    /// The stored panel a copy came from — set on the second and later copies
    /// only. The first keeps the stored panel's own id so that moving,
    /// resizing, editing and deleting still reach the definition; the copies
    /// have derived ids, and this is how a copy finds its way home.
    var repeatSourceID: UUID?

    /// The `panelType` string exactly as it was written, when this build has no
    /// case for it. Re-encoded in place of `panelType` so that opening a
    /// dashboard from a newer build and saving it does not rewrite a panel it
    /// merely could not draw (계약 R5).
    var unknownPanelTypeRaw: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, title, description, panelType, metric, gridPosition, targets
        case options, dataLinks, collapsed, plugin, queries, fieldConfig
        case fieldSelection, transformations
        case `repeat`, repeatDirection
        case relativeTime, timeShift
    }

    static let knownKeys: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))

    /// The type name to show the reader — the real one when this build knows
    /// it, the raw string off disk when it does not.
    var panelTypeLabel: String {
        panelType == .unknown ? (unknownPanelTypeRaw ?? PanelType.unknown.rawValue)
                              : panelType.rawValue
    }

    /// Decoded `TokiPromQLQuerySpec` from this panel's first query envelope,
    /// or nil. Returned fresh on every access — Swift structs can't cache
    /// computed values without a separate class wrapper, and panel fetch
    /// frequency (≈ once per refresh interval) doesn't warrant that.
    /// Callers in a tight loop should bind the result locally instead
    /// of reading it repeatedly.
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

// MARK: - PanelConfig Codable (unknown-key preserving)

extension PanelConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)

        // An unrecognised panel type must NOT fail the panel. Failing here
        // fails the dashboard, and the dashboard is the thing that cannot be
        // rebuilt. Keep the string, render a placeholder, write it back.
        let rawType = try c.decode(String.self, forKey: .panelType)
        if let known = PanelType(rawValue: rawType), known != .unknown {
            panelType = known
            unknownPanelTypeRaw = nil
        } else {
            panelType = .unknown
            unknownPanelTypeRaw = rawType
        }

        metric = try c.decode(PanelMetric.self, forKey: .metric)
        gridPosition = try c.decode(GridPosition.self, forKey: .gridPosition)
        targets = try c.decode([PanelTarget].self, forKey: .targets)
        options = try c.decode(PanelDisplayOptions.self, forKey: .options)
        dataLinks = try c.decode([DataLink].self, forKey: .dataLinks)
        collapsed = try c.decode(Bool.self, forKey: .collapsed)
        plugin = try c.decodeIfPresent(PanelPluginRef.self, forKey: .plugin)
        queries = try c.decodeIfPresent([Query].self, forKey: .queries)
        fieldConfig = try c.decodeIfPresent(FieldConfigSource.self, forKey: .fieldConfig)
        fieldSelection = try c.decodeIfPresent(FieldSelection.self, forKey: .fieldSelection)
        transformations = try c.decodeIfPresent([TransformationStep].self,
                                                forKey: .transformations) ?? []
        `repeat` = try c.decodeIfPresent(String.self, forKey: .repeat)
        repeatDirection = try c.decodeIfPresent(RepeatDirection.self, forKey: .repeatDirection)
        relativeTime = try c.decodeIfPresent(String.self, forKey: .relativeTime)
        timeShift = try c.decodeIfPresent(String.self, forKey: .timeShift)
        unknownFields = decoder.unknownFields(besides: Self.knownKeys)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(panelTypeLabel, forKey: .panelType)
        try c.encode(metric, forKey: .metric)
        try c.encode(gridPosition, forKey: .gridPosition)
        try c.encode(targets, forKey: .targets)
        try c.encode(options, forKey: .options)
        try c.encode(dataLinks, forKey: .dataLinks)
        try c.encode(collapsed, forKey: .collapsed)
        try c.encodeIfPresent(plugin, forKey: .plugin)
        try c.encodeIfPresent(queries, forKey: .queries)
        try c.encodeIfPresent(fieldConfig, forKey: .fieldConfig)
        try c.encodeIfPresent(fieldSelection, forKey: .fieldSelection)
        // Omitted when empty: a panel that has never been given a pipeline
        // should re-encode exactly as it arrived.
        if !transformations.isEmpty {
            try c.encode(transformations, forKey: .transformations)
        }
        try c.encodeIfPresent(`repeat`, forKey: .repeat)
        try c.encodeIfPresent(repeatDirection, forKey: .repeatDirection)
        try c.encodeIfPresent(relativeTime, forKey: .relativeTime)
        try c.encodeIfPresent(timeShift, forKey: .timeShift)
        try encoder.encodeUnknownFields(unknownFields, besides: Self.knownKeys)
    }
}

/// Which way a repeated panel's copies run.
///
/// Raw values match Grafana's (`h` / `v`) so an imported dashboard keeps its
/// direction rather than silently reverting to the default.
enum RepeatDirection: String, Codable, Equatable, CaseIterable, Sendable {
    case horizontal = "h"
    case vertical = "v"
}

struct PanelTarget: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var refId: String = "A"
    var metric: PanelMetric
    var query: String?  // optional custom PromQL override
    /// Run it, but leave it out of what the panel draws (Grafana's per-query
    /// eye). It is not "disable": the query still executes, so hiding a series
    /// costs nothing to un-hide and a transformation can still be fed by it.
    /// Optional in the on-disk shape so dashboards written before this decode
    /// unchanged.
    var hide: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, refId, metric, query, hide
    }

    init(id: UUID = UUID(), refId: String = "A", metric: PanelMetric,
         query: String? = nil, hide: Bool = false) {
        self.id = id
        self.refId = refId
        self.metric = metric
        self.query = query
        self.hide = hide
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        refId = try c.decodeIfPresent(String.self, forKey: .refId) ?? "A"
        metric = try c.decode(PanelMetric.self, forKey: .metric)
        query = try c.decodeIfPresent(String.self, forKey: .query)
        hide = try c.decodeIfPresent(Bool.self, forKey: .hide) ?? false
    }
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
    /// The ends of the gauge's scale. A gauge without them is a number in a
    /// circle: "80" means nothing until the reader knows whether the dial runs
    /// to 100 or to 100,000. Absent, the panel derives a scale from the
    /// thresholds and the value, and says which it used.
    var gaugeMin: Double?
    var gaugeMax: Double?

    // Field config
    var unit: String?
    var decimals: Int?
    var thresholds: [ThresholdStep] = []

    /// The band below every step (FR-026). Without it the region under the
    /// lowest threshold had no colour of its own, so a gauge sitting there drew
    /// the accent colour and said nothing about the value.
    var thresholdBase: ThresholdColor = .neutral

    /// Whether the step values are absolute numbers or percentages of the
    /// panel's scale (FR-026). Only offered where a scale exists to take a
    /// percentage of — see `PanelType.supportsPercentageThresholds`.
    var thresholdMode: ThresholdMode = .absolute

    /// Rules that replace a value's rendering, ahead of the unit (FR-025).
    ///
    /// Panel-level rather than per-field: the values a mapping is for — zero,
    /// absent, a sentinel — mean the same thing in every column of one panel,
    /// and a rule the reader has to restate per column is a rule they will
    /// restate wrong.
    var valueMappings: [ValueMapping] = []

    init() {}

    /// Every property optional on the way in, with the default the editor
    /// starts from.
    ///
    /// The synthesized decoder required each key, so every property added to
    /// this bag over the years made the panels of an older dashboard
    /// undecodable — and an undecodable panel fails its dashboard. Base colour
    /// and threshold mode are two more such properties, and they are the last
    /// ones to be able to do that.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colorMode = try c.decodeIfPresent(ColorMode.self, forKey: .colorMode) ?? .value
        graphMode = try c.decodeIfPresent(GraphMode.self, forKey: .graphMode) ?? .none
        legendPosition = try c.decodeIfPresent(LegendPosition.self,
                                               forKey: .legendPosition) ?? .bottom
        showLegend = try c.decodeIfPresent(Bool.self, forKey: .showLegend) ?? true
        tooltipMode = try c.decodeIfPresent(TooltipMode.self, forKey: .tooltipMode) ?? .single
        fillOpacity = try c.decodeIfPresent(Double.self, forKey: .fillOpacity) ?? 0.1
        lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 2
        showHeader = try c.decodeIfPresent(Bool.self, forKey: .showHeader) ?? true
        showThresholdMarkers = try c.decodeIfPresent(Bool.self,
                                                     forKey: .showThresholdMarkers) ?? true
        gaugeMin = try c.decodeIfPresent(Double.self, forKey: .gaugeMin)
        gaugeMax = try c.decodeIfPresent(Double.self, forKey: .gaugeMax)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        decimals = try c.decodeIfPresent(Int.self, forKey: .decimals)
        thresholds = try c.decodeIfPresent([ThresholdStep].self, forKey: .thresholds) ?? []
        thresholdBase = try c.decodeIfPresent(ThresholdColor.self,
                                              forKey: .thresholdBase) ?? .neutral
        thresholdMode = try c.decodeIfPresent(ThresholdMode.self,
                                              forKey: .thresholdMode) ?? .absolute
        valueMappings = try c.decodeIfPresent([ValueMapping].self,
                                              forKey: .valueMappings) ?? []
    }

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

struct ThresholdStep: Codable, Equatable, Identifiable {
    /// Stable identity so SwiftUI's `ForEach` keeps row identity across
    /// reorder/insert/delete. Previously the editor iterated with
    /// `id: \.offset`, which renumbered rows on every mutation and
    /// animated identity churn through the whole list.
    var id: UUID = UUID()
    var value: Double

    /// Was a free string. A free string cannot satisfy the contrast
    /// requirement and cannot be checked against it, so the set is closed
    /// (계약 R6, FR-027).
    ///
    /// Setting it clears `unknownColorRaw`: once the reader has picked a
    /// colour here, the string this step arrived with is no longer what it
    /// says.
    var color: ThresholdColor {
        didSet { unknownColorRaw = nil }
    }

    /// The colour string exactly as it was written, when it is not one this
    /// build can validate — a hex, or a palette name from elsewhere.
    /// Re-encoded in place of `color` so that opening a dashboard from another
    /// tool and saving it does not overwrite a colour this build merely
    /// declined to draw (계약 C1). Never rendered: `color` is.
    var unknownColorRaw: String?

    init(value: Double, color: ThresholdColor, unknownColorRaw: String? = nil) {
        self.value = value
        self.color = color
        self.unknownColorRaw = unknownColorRaw
    }

    enum CodingKeys: String, CodingKey {
        case value, color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decode(Double.self, forKey: .value)
        let raw = try c.decode(String.self, forKey: .color)
        if let known = ThresholdColor.named(raw) {
            color = known
            unknownColorRaw = raw == known.rawValue ? nil : raw
        } else {
            // Neutral rather than a guess. A colour this build cannot place is
            // not evidence about the value, and drawing it as red would be.
            color = .neutral
            unknownColorRaw = raw
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(unknownColorRaw ?? color.rawValue, forKey: .color)
    }
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
    /// Spans on a row per series: what state something was in, and for how
    /// long. The other types all answer "how much, over time" and can only
    /// show a state change as a step to be read off an axis.
    case stateTimeline
    case rowPanel

    /// A type this build has no renderer for — a panel written by a newer
    /// build. It is never created here and never offered in a picker; it
    /// exists so that decoding such a panel keeps the panel instead of
    /// failing the whole dashboard (계약 R5). The string actually on disk is
    /// kept in `PanelConfig.unknownPanelTypeRaw`.
    case unknown = "__unknown__"

    /// Which field-override properties this build's render for the type reads.
    ///
    /// The editor offers exactly these and no more (계약 R1). A gauge has no
    /// legend to rename and no series to colour — its colour comes from its
    /// thresholds — so offering `displayName` or `color` there would be six
    /// controls of which two work.
    var honouredFieldProperties: Set<FieldDisplayProperty> {
        switch self {
        case .stat:
            // One number, formatted. Its name is the panel title.
            return [.unit, .decimals]
        case .gauge:
            // Formatting, plus the ends of the dial when the gauge itself does
            // not state them.
            return [.unit, .decimals, .min, .max]
        case .timeSeries:
            return [.displayName, .unit, .decimals, .color, .min, .max]
        case .barChart:
            // No y-domain control on this render, so no min/max.
            return [.displayName, .unit, .decimals, .color]
        case .pieChart:
            // Slices are labelled; the numbers are printed as shares of the
            // whole, which no unit applies to. Colour is deliberately absent —
            // a slice takes the colour its model has on every other panel, and
            // a per-field override would break that correspondence for one
            // panel only.
            return [.displayName]
        case .table:
            // The one type with COLUMNS, and so the one type where a per-field
            // filter has anywhere to live. Grafana puts it in exactly the same
            // place, for the same reason: a legend hides a series, a table has
            // no series to hide, and its header is where a reader is already
            // looking when they want less of it.
            return [.displayName, .unit, .decimals, .filterable]
        case .stateTimeline:
            // Rows are named; their colour comes from the thresholds and their
            // values are band names rather than numbers.
            return [.displayName]
        case .rowPanel, .unknown:
            return []
        }
    }

    /// Whether this build's render for the type reads the panel's thresholds.
    ///
    /// The editor offers the threshold list only where the answer is yes.
    /// Offering it elsewhere is the R1 failure exactly: the reader sets a
    /// threshold, nothing changes, and they go looking for their own mistake.
    var honoursThresholds: Bool {
        switch self {
        case .stat, .gauge, .timeSeries, .stateTimeline: return true
        case .barChart, .pieChart, .table, .rowPanel, .unknown: return false
        }
    }

    /// Whether this build's render for the type applies value mappings.
    ///
    /// The three that draw a value as TEXT. A line chart draws a value as a
    /// position on an axis, and there is nowhere on it to put the word "no
    /// value" — offering mappings there would be a control that changes
    /// nothing, which is the R1 failure the threshold list above avoids.
    var honoursValueMappings: Bool {
        switch self {
        case .stat, .gauge, .table: return true
        case .timeSeries, .barChart, .pieChart, .stateTimeline, .rowPanel, .unknown:
            return false
        }
    }

    /// Whether the type has a scale a percentage threshold can be a percentage
    /// OF — the gauge's stated ends, the line chart's drawn range. A stat card
    /// is one number and a state timeline is a row of spans; neither has one,
    /// so the mode is not offered there.
    var supportsPercentageThresholds: Bool {
        self == .gauge || self == .timeSeries
    }

    /// Panel types available for user creation (excludes rowPanel from general picker)
    static var creatableTypes: [PanelType] {
        [.stat, .timeSeries, .barChart, .pieChart, .table, .gauge, .stateTimeline]
    }

    /// Minimum grid width (columns). Stat cards default to width=6 in the
    /// stock dashboard, and the design constraint is "user can shrink to
    /// half the default" — hence stat minWidth=3.
    var minWidth: Int {
        switch self {
        case .stat: 3
        case .timeSeries: 6
        case .barChart: 6
        case .pieChart: 6
        case .table: 8
        case .gauge: 4
        // Spans are read by their extent, so a narrow one is unreadable.
        case .stateTimeline: 8
        case .rowPanel: 24
        case .unknown: 4
        }
    }

    /// Minimum grid height (rows). Stat panels are vertically locked
    /// (their resize handle never drives the height axis — see
    /// `PanelEdgeResize`), so minHeight=1 is just the floor used when
    /// constructing a panel programmatically. For non-stat panels the
    /// minimum is half the default chart height so users can compress
    /// them when stacking many panels.
    var minHeight: Int {
        switch self {
        case .stat: 1
        case .timeSeries: 1
        case .barChart: 1
        case .pieChart: 1
        case .table: 1
        case .gauge: 1
        case .stateTimeline: 1
        case .rowPanel: 1
        case .unknown: 1
        }
    }

    /// Whether this panel type is allowed to resize vertically. Stat
    /// cards are deliberately fixed-height (they show a single value;
    /// growing the tile doesn't change the readout), so their edge
    /// resize handle exposes only the horizontal axis.
    var allowsVerticalResize: Bool {
        switch self {
        case .stat: false
        default:    true
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
    /// Rate-limit windows. Not a series — each row is an interval with an
    /// outcome, which is why it belongs to the state timeline and to nothing
    /// that plots a value against time.
    case rateLimitWindows

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
        case .rateLimitWindows:
            return [.stateTimeline, .table]
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
        case .rateLimitWindows:
            "windows"
        }
    }
}

// MARK: - JSON Import/Export

extension DashboardConfig {
    /// Export dashboard as shareable JSON.
    ///
    /// Configuration only, plus the minimum versions needed to open it. The
    /// serialisation itself lives in `DashboardExchange` so there is one
    /// answer to "what leaves this machine" (계약 C3).
    func exportJSON() throws -> Data {
        try DashboardExchange.exportData(self)
    }

    /// Export as JSON string
    func exportJSONString() throws -> String {
        try DashboardExchange.exportString(self)
    }

    /// Import dashboard from JSON data, refusing a schema this build cannot
    /// open with a reason that says what is missing (계약 C4).
    static func importJSON(_ data: Data) throws -> DashboardConfig {
        var config = try DashboardExchange.decode(data)
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
