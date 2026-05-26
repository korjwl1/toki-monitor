import Foundation

/// Runtime registry that resolves a `DatasourceSelector` (kind + optional
/// name) to a concrete `DatasourcePlugin` instance.
///
/// Symmetric with `VariablePluginRegistry`: both are just "kind →
/// instance" maps. An earlier draft also held a `Factory` closure dict
/// so a registered kind could mint *new* instances from a JSON spec, but
/// nothing in the app calls that path — every consumer asks for the
/// default or a named instance the registry already holds. The factory
/// dict was dead code and made the registry look more complex than its
/// sibling.
@MainActor
final class DatasourceRegistry {
    static let shared = DatasourceRegistry()

    private var defaults: [String: any DatasourcePlugin] = [:]
    private var named: [DatasourceSelector: any DatasourcePlugin] = [:]

    private init() {
        registerBuiltins()
    }

    // MARK: - Registration

    /// Set the default plugin instance for a kind (used when
    /// `selector.name` is nil).
    func setDefault(_ plugin: any DatasourcePlugin) {
        defaults[plugin.kind] = plugin
    }

    /// Register a named instance (looked up by selector with matching
    /// kind + name).
    func registerNamed(name: String, plugin: any DatasourcePlugin) {
        named[DatasourceSelector(kind: plugin.kind, name: name)] = plugin
    }

    /// Remove all registered named instances. Called by dashboard-scope
    /// callers (e.g. `DashboardViewModel.registerInlineDatasources` on
    /// switch) so a previous dashboard's inline datasource names don't
    /// leak into the next. Built-in defaults are *not* affected.
    func clearNamed() {
        named.removeAll(keepingCapacity: true)
    }

    // MARK: - Resolution

    /// Resolve a selector to a plugin. Named instance wins over default.
    func resolve(_ selector: DatasourceSelector) -> (any DatasourcePlugin)? {
        if selector.name != nil, let plugin = named[selector] {
            return plugin
        }
        return defaults[selector.kind]
    }

    func resolve(kind: String) -> (any DatasourcePlugin)? {
        defaults[kind]
    }

    /// All registered kinds (e.g. for UI pickers).
    var kinds: [String] { Array(defaults.keys).sorted() }

    /// All plugin instances for which a default exists, sorted by `kind`.
    /// Used by data source pickers; sorting by `kind` (not `displayName`)
    /// keeps order stable across locale changes — display names come
    /// from `DatasourceKindDisplay.name(for:)` which returns localized
    /// strings, so sorting on them would re-shuffle the picker when the
    /// user switches language.
    var allDefaults: [any DatasourcePlugin] {
        defaults.values.sorted { $0.kind < $1.kind }
    }

    // MARK: - Built-ins

    private func registerBuiltins() {
        setDefault(LocalCLIDatasource())
        // toki-sync PromQL proxy — registered unconditionally; gated by
        // `SyncManager.shared.isConfigured` at call sites.
        setDefault(PromQLProxyDatasource())
    }
}
