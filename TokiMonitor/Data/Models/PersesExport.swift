import Foundation

/// Strict Perses-shape envelope for exporting a `DashboardConfig` to a form
/// that another Perses instance could ingest. The in-memory store keeps
/// `panels` as an array (Grafana-style) so views don't break; this struct
/// rebuilds the canonical Perses tree from those fields at export time.
///
/// Round-trip note: importing a Perses dashboard is not yet supported. This
/// is one-way (toki-monitor → Perses-shape JSON).

struct PersesDashboardEnvelope: Codable, Sendable {
    var kind: String = "Dashboard"
    var metadata: PersesMetadata
    var spec: PersesDashboardSpec
}

struct PersesMetadata: Codable, Sendable {
    var name: String
    var project: String?
    var version: Int?
}

struct PersesDashboardSpec: Codable, Sendable {
    var display: PersesDisplay?
    var duration: String
    var refreshInterval: String?
    var variables: [PersesVariableEnvelope]
    var datasources: [String: DatasourceInstance]?
    var panels: [String: PersesPanelEnvelope]
    var layouts: [DashboardLayout]
}

struct PersesDisplay: Codable, Sendable {
    var name: String?
    var description: String?
}

struct PersesPanelEnvelope: Codable, Sendable {
    var kind: String = "Panel"
    var spec: PersesPanelSpec
}

struct PersesPanelSpec: Codable, Sendable {
    var display: PersesDisplay?
    var plugin: PanelPluginRef
    var queries: [Query]
}

struct PersesVariableEnvelope: Codable, Sendable {
    var kind: String   // "TextVariable" | "ListVariable"
    var spec: PersesVariableSpec
}

struct PersesVariableSpec: Codable, Sendable {
    // Common
    var name: String
    var display: PersesDisplay?
    // ListVariable only — TextVariable encodes a `value` string instead.
    var value: String?
    var defaultValue: VariableSelection?
    var allowAllValue: Bool?
    var allowMultiple: Bool?
    var customAllValue: String?
    var capturingRegexp: String?
    var sort: VariableSort?
    var plugin: VariablePluginRef?
}

extension DashboardConfig {
    /// Render this dashboard as a Perses-shape envelope. Lossy: the legacy
    /// `panel.panelType` / `panel.metric` / `panel.options` / `panel.targets`
    /// fields are not exported (their normalized projection lives inside
    /// `panel.plugin.spec` and `panel.queries`).
    func toPersesEnvelope(projectName: String? = nil) -> PersesDashboardEnvelope {
        let panelsMap: [String: PersesPanelEnvelope] = Dictionary(
            uniqueKeysWithValues: panels.map { panel in
                let pluginRef = panel.plugin
                    ?? PanelPluginRef(kind: BuiltinPanelPluginKind.kind(for: panel.panelType))
                let qs = panel.queries ?? []
                return (
                    panel.id.uuidString,
                    PersesPanelEnvelope(spec: PersesPanelSpec(
                        display: PersesDisplay(name: panel.title, description: panel.description),
                        plugin: pluginRef,
                        queries: qs
                    ))
                )
            }
        )

        let layouts: [DashboardLayout] = self.layouts ?? [
            DashboardLayout(
                kind: "Grid",
                spec: GridLayoutSpec(display: nil, items: panels.map { panel in
                    LayoutGridItem(
                        x: panel.gridPosition.column, y: panel.gridPosition.row,
                        width: panel.gridPosition.width, height: panel.gridPosition.height,
                        content: JSONRef(panelKey: panel.id.uuidString)
                    )
                })
            )
        ]

        let variables: [PersesVariableEnvelope] = templating.list.map { v in
            PersesVariableEnvelope(
                kind: VariableKind.listVariable.rawValue,
                spec: PersesVariableSpec(
                    name: v.name,
                    display: PersesDisplay(name: v.label, description: nil),
                    value: nil,
                    defaultValue: v.current,
                    allowAllValue: v.includeAll,
                    allowMultiple: v.multi,
                    customAllValue: v.customAllValue,
                    capturingRegexp: v.capturingRegexp,
                    sort: v.sort,
                    plugin: v.plugin
                )
            )
        }

        return PersesDashboardEnvelope(
            kind: "Dashboard",
            metadata: PersesMetadata(
                name: title, project: projectName, version: version
            ),
            spec: PersesDashboardSpec(
                display: PersesDisplay(name: title, description: description),
                duration: time.from.hasPrefix("now-")
                    ? String(time.from.dropFirst(4))
                    : "1h",
                refreshInterval: refresh == .off ? nil : refresh.rawValue,
                variables: variables,
                datasources: datasources.isEmpty ? nil : datasources,
                panels: panelsMap,
                layouts: layouts
            )
        )
    }

    /// Encoded Perses-shape JSON string for sharing or pasting into a
    /// Perses CLI / UI.
    func exportPersesJSONString(projectName: String? = nil) throws -> String {
        let envelope = toPersesEnvelope(projectName: projectName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
