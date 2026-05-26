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
    /// Pre-resolved query client for the dashboard's active datasource.
    /// `QueryDataSource: Sendable`, so this stays naturally Sendable —
    /// no `@unchecked` needed.
    var queryClient: (any QueryDataSource)?
}

@MainActor
final class VariablePluginRegistry {
    static let shared = VariablePluginRegistry()

    private var loaders: [String: any VariablePluginLoader] = [:]

    private init() {
        register(StaticListVariableLoader())
        register(IntervalVariableLoader())
        register(TokiLabelValuesVariableLoader())
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

/// `TokiLabelValuesVariable` — dynamic options sourced from the labels of a
/// PromQL query result. Parallels Perses' `PrometheusLabelValuesVariable`,
/// but scoped to the labels toki actually emits (`model`, `project`).
///
/// Spec:
///   - `datasource`: optional override; nil → use context's active client.
///   - `query`: PromQL whose result series carry the label of interest.
///   - `labelName`: which label to extract (currently `model` or `project`).
struct TokiLabelValuesVariableSpec: Codable, Equatable, Sendable {
    var datasource: DatasourceSelector?
    var query: String
    var labelName: String
}

struct TokiLabelValuesVariableLoader: VariablePluginLoader {
    var kind: String { BuiltinVariablePluginKind.tokiLabelValues }

    func loadOptions(specData: Data, context: VariableLoadContext) async throws -> [VariableOption] {
        guard let spec = try? JSONDecoder().decode(TokiLabelValuesVariableSpec.self, from: specData)
        else { return [] }

        // Resolve the client: per-spec datasource wins, else context default.
        let client: (any QueryDataSource)? = await MainActor.run {
            if let ds = spec.datasource,
               let plugin = DatasourceRegistry.shared.resolve(ds) {
                return plugin as any QueryDataSource
            }
            return context.queryClient
        }
        guard let client else { return [] }

        // Cascading interpolation — both `${name}` and bare `$name` forms.
        var query = spec.query
        for (name, value) in context.resolvedVariables {
            query = query.replacingOccurrences(of: "${\(name)}", with: value)
            let pattern = "\\$\(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z0-9_])"
            query = query.replacingOccurrences(of: pattern, with: value,
                                               options: .regularExpression)
        }

        let data = try await client.queryPromQLAsTimeSeries(query: query, time: context.time)
        // toki's TimeSeriesData carries label values as `allModelNames` for
        // both model and project queries (the project loader stashes project
        // names in the model slot — see DashboardViewModel.fetchProjectPanels).
        return data.allModelNames.map { VariableOption(text: $0, value: $0) }
    }
}
