import Foundation

/// Resolves a variable plugin spec into a list of `VariableOption`. Each
/// plugin kind (StaticList, Interval, PrometheusLabelValues, ...) ships
/// one loader, registered with `VariablePluginRegistry`.
protocol VariablePluginLoader: Sendable {
    var kind: String { get }

    /// Compute the option list for this plugin spec. Called on dashboard
    /// load, time-range change, or refresh — depending on the variable's
    /// `refresh` policy (handled by the caller).
    func loadOptions(specData: Data, context: VariableLoadContext) async throws -> [VariableOption]
}

/// Context handed to a loader so it can scope its query (interpolating other
/// variable values, hitting the active datasource, etc.).
struct VariableLoadContext: Sendable {
    var time: TimeConfig
    /// Already-resolved variable values (`$name` → joined string) so loaders
    /// can interpolate dependencies in `matchers` / `expr` fields.
    var resolvedVariables: [String: String]
}

@MainActor
final class VariablePluginRegistry {
    static let shared = VariablePluginRegistry()

    private var loaders: [String: any VariablePluginLoader] = [:]

    private init() {
        register(StaticListVariableLoader())
        register(IntervalVariableLoader())
    }

    func register(_ loader: any VariablePluginLoader) {
        loaders[loader.kind] = loader
    }

    func loader(for kind: String) -> (any VariablePluginLoader)? {
        loaders[kind]
    }
}

// MARK: - Built-in loaders

/// `StaticListVariable` — user supplies `values: [VariableOption]` directly.
struct StaticListVariableLoader: VariablePluginLoader {
    var kind: String { BuiltinVariablePluginKind.staticList }

    func loadOptions(specData: Data, context: VariableLoadContext) async throws -> [VariableOption] {
        let spec = (try? JSONDecoder().decode(StaticListVariableSpec.self, from: specData))
            ?? StaticListVariableSpec()
        return spec.values
    }
}

/// `IntervalVariable` — a fixed list of duration strings rendered as
/// `(text, value)` options where text == value.
struct IntervalVariableLoader: VariablePluginLoader {
    var kind: String { BuiltinVariablePluginKind.interval }

    func loadOptions(specData: Data, context: VariableLoadContext) async throws -> [VariableOption] {
        let spec = (try? JSONDecoder().decode(IntervalVariableSpec.self, from: specData))
            ?? IntervalVariableSpec()
        return spec.values.map { VariableOption(text: $0, value: $0) }
    }
}
