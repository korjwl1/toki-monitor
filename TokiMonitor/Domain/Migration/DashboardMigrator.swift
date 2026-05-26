import Foundation

/// Brings any persisted `DashboardConfig` up to the current schema version.
///
/// Was previously a set of `static func migrateVxtoVy` on
/// `extension DashboardConfig`. Data models should describe shape, not
/// "how to upgrade an older shape" — that's a domain rule. Moved here so
/// the model stays declarative and the migration chain has one home.
enum DashboardMigrator {
    /// The schema version this build of the app writes.
    static let currentVersion: Int = 4

    /// Run the full migration chain on a config. Each step is idempotent
    /// when its `schemaVersion` precondition is already met, so calling
    /// `migrate(_:)` on an already-current config is a no-op.
    ///
    /// Configs with `schemaVersion > currentVersion` are left untouched
    /// (this build downgrade-loaded a future-shaped JSON). The newer
    /// shape may carry fields we don't know about, but Codable tolerates
    /// unknown keys, and overwriting the version would risk losing
    /// information when the user upgrades again.
    static func migrate(_ config: DashboardConfig) -> DashboardConfig {
        if config.schemaVersion > currentVersion {
            #if DEBUG
            print("[DashboardMigrator] config schemaVersion=\(config.schemaVersion) is newer than supported \(currentVersion); leaving untouched.")
            #endif
            return config
        }
        var c = config
        if c.schemaVersion < 2 { c = migrateV1toV2(c) }
        if c.schemaVersion < 3 { c = migrateV2toV3(c) }
        if c.schemaVersion < 4 { c = migrateV3toV4(c) }
        return c
    }

    // MARK: - Step migrations

    /// v1 (12-column grid) → v2 (24-column grid).
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
            migrated.templating = DashboardConfig.defaultTemplating
        }
        return migrated
    }

    /// v2 → v3: rewrite legacy `toki_tokens_total` queries to the
    /// `usage` virtual metric. The local toki CLI understands `usage`
    /// natively; `ServerQueryClient` translates it for the proxy.
    static func migrateV2toV3(_ config: DashboardConfig) -> DashboardConfig {
        var migrated = config
        migrated.schemaVersion = 3
        migrated.panels = config.panels.map { panel in
            var p = panel
            p.targets = panel.targets.map { target in
                var t = target
                if var q = t.query {
                    q = q.replacingOccurrences(
                        of: #"toki_tokens_total\{([^}]*),\s*type=~"input\|output"\}"#,
                        with: #"usage{$1}"#,
                        options: .regularExpression
                    )
                    q = q.replacingOccurrences(
                        of: #"toki_tokens_total\{type=~"input\|output",\s*([^}]*)\}"#,
                        with: #"usage{$1}"#,
                        options: .regularExpression
                    )
                    q = q.replacingOccurrences(
                        of: #"toki_tokens_total\{type=~"input\|output"\}"#,
                        with: "usage",
                        options: .regularExpression
                    )
                    q = q.replacingOccurrences(of: "toki_tokens_total", with: "usage")
                    t.query = q
                }
                return t
            }
            return p
        }
        return migrated
    }

    /// v3 → v4: adopt Perses-shaped envelopes.
    ///
    /// - Backfill `activeDatasource` (built-in local CLI) so v4 configs
    ///   are never `null`.
    /// - Populate `panel.plugin` from `panel.panelType` (legacy fields
    ///   kept for renderer compatibility).
    /// - Populate `panel.queries` from `panel.targets` (each
    ///   `PanelTarget` becomes a `Query` wrapping a `TokiPromQLQuerySpec`).
    /// - Populate `variable.plugin` from the legacy `type` enum (custom
    ///   → StaticListVariable, interval → IntervalVariable).
    /// - Build a single `Grid` layout referencing every panel by id.
    static func migrateV3toV4(_ config: DashboardConfig) -> DashboardConfig {
        var migrated = config
        migrated.schemaVersion = 4

        if migrated.activeDatasource == nil {
            migrated.activeDatasource = DatasourceSelector(kind: BuiltinDatasourceKind.localCLI)
        }

        migrated.panels = migrated.panels.map { panel in
            var p = panel
            if p.plugin == nil {
                let kind = BuiltinPanelPluginKind.kind(for: p.panelType)
                let specData = p.options.encodedSpec(forPanelPluginKind: kind) ?? Data()
                p.plugin = PanelPluginRef(kind: kind, spec: specData)
            }
            if p.queries == nil {
                let sourceTargets = p.targets.isEmpty
                    ? [PanelTarget(refId: "A", metric: p.metric)]
                    : p.targets
                p.queries = sourceTargets.map { target in
                    let spec = TokiPromQLQuerySpec(
                        datasource: nil,
                        metric: target.metric,
                        query: target.query
                    )
                    let specData = (try? JSONEncoder().encode(spec)) ?? Data()
                    return Query(
                        kind: BuiltinQueryKind.timeSeriesQuery,
                        spec: QuerySpec(
                            name: target.refId,
                            plugin: QueryPluginRef(
                                kind: BuiltinQueryPluginKind.tokiPromQLQuery,
                                spec: specData
                            )
                        )
                    )
                }
            }
            return p
        }

        migrated.templating.list = migrated.templating.list.map { variable in
            var v = variable
            if v.plugin == nil {
                switch v.type {
                case .custom:
                    let spec = StaticListVariableSpec(values: v.options)
                    let data = (try? JSONEncoder().encode(spec)) ?? Data()
                    v.plugin = VariablePluginRef(
                        kind: BuiltinVariablePluginKind.staticList, spec: data
                    )
                case .interval:
                    let parsed = v.query
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let values = parsed.isEmpty
                        ? IntervalVariableSpec().values
                        : parsed
                    let spec = IntervalVariableSpec(values: values)
                    let data = (try? JSONEncoder().encode(spec)) ?? Data()
                    v.plugin = VariablePluginRef(
                        kind: BuiltinVariablePluginKind.interval, spec: data
                    )
                }
            }
            return v
        }

        if migrated.layouts == nil {
            let items = migrated.panels.map { panel -> LayoutGridItem in
                LayoutGridItem(
                    x: panel.gridPosition.column,
                    y: panel.gridPosition.row,
                    width: panel.gridPosition.width,
                    height: panel.gridPosition.height,
                    content: JSONRef(panelKey: panel.id.uuidString)
                )
            }
            migrated.layouts = [
                DashboardLayout(
                    kind: "Grid",
                    spec: GridLayoutSpec(display: nil, items: items)
                )
            ]
        }

        return migrated
    }
}
