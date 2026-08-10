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
        register(ConstantVariableLoader())
        register(TextVariableLoader())
        register(GroupByVariableLoader())
        register(AdHocVariableLoader())
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

/// `ConstantVariable` — one value the author fixes.
///
/// It still produces an option so that everything downstream (selection,
/// interpolation, export) treats it like any other variable; what makes it
/// constant is that the option list has exactly one entry and the toolbar
/// offers no control.
struct ConstantVariableLoader: VariablePluginLoader {
    var kind: String { BuiltinVariablePluginKind.constant }

    func loadOptions(specData: Data, context: VariableLoadContext) async throws -> [VariableOption] {
        let spec = (try? JSONDecoder().decode(ConstantVariableSpec.self, from: specData))
            ?? ConstantVariableSpec()
        guard !spec.value.isEmpty else { return [] }
        return [VariableOption(text: spec.value, value: spec.value)]
    }
}

/// `TextVariable` — free text, with the author's default as the only option.
///
/// The option exists so a dashboard that has never been touched still
/// interpolates to something; once the reader types, `current` carries their
/// text and this list is not consulted.
struct TextVariableLoader: VariablePluginLoader {
    var kind: String { BuiltinVariablePluginKind.text }

    func loadOptions(specData: Data, context: VariableLoadContext) async throws -> [VariableOption] {
        let spec = (try? JSONDecoder().decode(TextVariableSpec.self, from: specData))
            ?? TextVariableSpec()
        guard !spec.value.isEmpty else { return [] }
        return [VariableOption(text: spec.value, value: spec.value)]
    }
}

/// `GroupByVariable` — its options are label NAMES, so the reader chooses
/// which dimensions to break the data down by rather than which values to
/// keep. Used as `by ($groupby)`, which is why its values join with commas
/// (see `DashboardVariable.defaultFormat`).
///
/// The candidates are whatever the query's own result carries. Offering a
/// fixed list would mean offering dimensions this data does not have.
struct GroupByVariableLoader: VariablePluginLoader {
    var kind: String { BuiltinVariablePluginKind.groupBy }

    func loadOptions(specData: Data, context: VariableLoadContext) async throws -> [VariableOption] {
        guard let spec = try? JSONDecoder().decode(GroupByVariableSpec.self, from: specData),
              !spec.query.isEmpty
        else { return [] }
        let client: (any QueryDataSource)? = await MainActor.run {
            if let ds = spec.datasource, let plugin = DatasourceRegistry.shared.resolve(ds) {
                return plugin as any QueryDataSource
            }
            return context.queryClient
        }
        guard let client else { return [] }
        let query = TokiLabelValuesVariableLoader.interpolate(
            spec.query, with: context.resolvedVariables
        )
        let result = try await client.queryPromQL(query: query, time: context.time)
        return FrameReader.labelKeys(result.frames).map { VariableOption(text: $0, value: $0) }
    }
}

/// `AdHocFiltersVariable` — the reader's own label matchers.
///
/// It has no option list: the reader picks a key and then a value, so what the
/// editor needs is the label MAP the query returned, not a flat list. The
/// filters themselves live on the variable rather than in `current`, because
/// they are not a selection from a list.
struct AdHocVariableLoader: VariablePluginLoader {
    var kind: String { BuiltinVariablePluginKind.adHoc }

    func loadOptions(specData: Data, context: VariableLoadContext) async throws -> [VariableOption] {
        []
    }

    /// Every label the query returns, mapped to the values it takes. Both
    /// halves come from the same frames, so a key is only offered when it has
    /// values and a value is only offered under the key it belongs to.
    func loadKeyValues(specData: Data,
                       context: VariableLoadContext) async throws -> [String: [String]] {
        guard let spec = try? JSONDecoder().decode(AdHocVariableSpec.self, from: specData),
              !spec.query.isEmpty
        else { return [:] }
        let client: (any QueryDataSource)? = await MainActor.run {
            if let ds = spec.datasource, let plugin = DatasourceRegistry.shared.resolve(ds) {
                return plugin as any QueryDataSource
            }
            return context.queryClient
        }
        guard let client else { return [:] }
        let query = TokiLabelValuesVariableLoader.interpolate(
            spec.query, with: context.resolvedVariables
        )
        let frames = try await client.queryPromQL(query: query, time: context.time).frames
        var out: [String: [String]] = [:]
        for key in FrameReader.labelKeys(frames) {
            out[key] = FrameReader.labelValues(frames, key: key)
        }
        return out
    }
}

/// `TokiLabelValuesVariable` — dynamic options sourced from the labels of a
/// PromQL query result. Parallels Perses' `PrometheusLabelValuesVariable`.
///
/// Reads the label off the frames the query produced, so `labelName` means
/// what it says. It could not before: the legacy result had one series-name
/// slot, so the loader had to take whatever the query happened to put there
/// and trust the user to have targeted the right dimension — and any label
/// beyond an allowlist of two returned nothing at all.
///
/// Spec:
///   - `datasource`: optional override; nil → use context's active client.
///   - `query`: PromQL whose result series carry the label of interest.
///   - `labelName`: which label to extract.
struct TokiLabelValuesVariableSpec: Codable, Equatable, Sendable {
    var datasource: DatasourceSelector?
    var query: String
    var labelName: String
}

struct TokiLabelValuesVariableLoader: VariablePluginLoader {
    var kind: String { BuiltinVariablePluginKind.tokiLabelValues }

    func loadOptions(specData: Data, context: VariableLoadContext) async throws -> [VariableOption] {
        guard let spec = try? JSONDecoder().decode(TokiLabelValuesVariableSpec.self, from: specData),
              !spec.labelName.isEmpty
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

        let query = Self.interpolate(spec.query, with: context.resolvedVariables)
        let result = try await client.queryPromQL(query: query, time: context.time)
        if !result.frames.frames.isEmpty {
            return FrameReader.labelValues(result.frames, key: spec.labelName)
                .map { VariableOption(text: $0, value: $0) }
        }
        // A datasource that serves no frames yet. `allModelNames` holds
        // whatever dimension the query grouped by — the loader cannot tell
        // which — so this reproduces the old behaviour and no more.
        return result.timeSeries.allModelNames.map { VariableOption(text: $0, value: $0) }
    }

    /// Labels the query's own result carries, for an editor that would
    /// otherwise offer a hard-coded list the query may never return.
    func loadLabelKeys(specData: Data, context: VariableLoadContext) async throws -> [String] {
        guard let spec = try? JSONDecoder().decode(TokiLabelValuesVariableSpec.self, from: specData)
        else { return [] }
        let client: (any QueryDataSource)? = await MainActor.run {
            if let ds = spec.datasource, let plugin = DatasourceRegistry.shared.resolve(ds) {
                return plugin as any QueryDataSource
            }
            return context.queryClient
        }
        guard let client else { return [] }
        let result = try await client.queryPromQL(
            query: Self.interpolate(spec.query, with: context.resolvedVariables),
            time: context.time
        )
        return FrameReader.labelKeys(result.frames)
    }

    /// Cascading interpolation — both `${name}` and bare `$name` forms.
    /// The value is escaped as a regex *template* before substitution so that
    /// values like `claude|gpt` (multi-select alternation) or `.*`
    /// (customAllValue) aren't reinterpreted as regex template metacharacters
    /// — they were producing garbage interpolations before this.
    static func interpolate(_ template: String, with values: [String: String]) -> String {
        var query = template
        for (name, value) in values {
            query = query.replacingOccurrences(of: "${\(name)}", with: value)
            let pattern = "\\$\(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z0-9_])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let replacement = NSRegularExpression.escapedTemplate(for: value)
            let range = NSRange(query.startIndex..., in: query)
            query = regex.stringByReplacingMatches(in: query, range: range, withTemplate: replacement)
        }
        return query
    }
}
