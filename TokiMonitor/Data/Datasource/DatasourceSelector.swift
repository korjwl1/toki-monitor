import Foundation

/// Perses-style reference to a datasource.
/// `kind` is required (used to look up default when `name` is nil).
/// `name` selects a specific named instance — nil means "default of this kind".
struct DatasourceSelector: Codable, Equatable, Hashable, Sendable {
    var kind: String
    var name: String?

    init(kind: String, name: String? = nil) {
        self.kind = kind
        self.name = name
    }
}

/// A concrete, persisted datasource instance — the inline form stored
/// inside a dashboard's `datasources` map, or in `DatasourceStore`.
struct DatasourceInstance: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var kind: String
    var displayName: String?
    /// JSON-encoded plugin spec. Decoded into a typed spec by the plugin factory.
    var spec: Data = Data()
    /// `true` means this is the default for its `kind` when a selector omits `name`.
    var isDefault: Bool = false

    var selector: DatasourceSelector { DatasourceSelector(kind: kind, name: name) }
}

/// Built-in kind identifiers used by toki-monitor.
enum BuiltinDatasourceKind {
    static let localCLI = "toki-local"
    static let promQLProxy = "toki-server"
}
