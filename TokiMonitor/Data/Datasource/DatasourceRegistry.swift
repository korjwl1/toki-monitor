import Foundation

/// Runtime registry that resolves a `DatasourceSelector` (kind + optional name)
/// to a concrete `DatasourcePlugin` instance. Mirrors Perses' plugin loader.
///
/// For now plugins are registered statically at boot. When `name` is nil,
/// the registry returns the default instance for that `kind`.
@MainActor
final class DatasourceRegistry {
    static let shared = DatasourceRegistry()

    /// Factory closure: receives the spec data (may be empty for built-ins
    /// that need no configuration) and produces a plugin instance.
    typealias Factory = (Data) throws -> any DatasourcePlugin

    private var factories: [String: Factory] = [:]
    private var defaults: [String: any DatasourcePlugin] = [:]
    private var named: [DatasourceSelector: any DatasourcePlugin] = [:]

    private init() {
        registerBuiltins()
    }

    // MARK: - Registration

    func register(kind: String, factory: @escaping Factory) {
        factories[kind] = factory
    }

    /// Set the default plugin instance for a kind (used when selector.name is nil).
    func setDefault(_ plugin: any DatasourcePlugin) {
        defaults[plugin.kind] = plugin
    }

    /// Register a named instance (looked up by selector with matching kind + name).
    func registerNamed(name: String, plugin: any DatasourcePlugin) {
        named[DatasourceSelector(kind: plugin.kind, name: name)] = plugin
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

    /// All plugin instances for which a default exists.
    var allDefaults: [any DatasourcePlugin] {
        defaults.values.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Built-ins

    private func registerBuiltins() {
        // Local toki CLI — always available.
        let local = LocalCLIDatasource()
        setDefault(local)
        register(kind: BuiltinDatasourceKind.localCLI) { _ in LocalCLIDatasource() }

        // toki-sync PromQL proxy — registered unconditionally; gated by
        // `SyncManager.shared.isConfigured` at call sites.
        let proxy = PromQLProxyDatasource()
        setDefault(proxy)
        register(kind: BuiltinDatasourceKind.promQLProxy) { _ in PromQLProxyDatasource() }
    }
}
