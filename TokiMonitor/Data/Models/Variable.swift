import Foundation

// MARK: - Variable plugin model (used by DashboardVariable)
//
// An earlier draft of this file also introduced a `Variable` tagged-union
// (`TextVariable` / `ListVariable`) intended to fully replace the legacy
// `DashboardVariable`. That replacement never landed — every call site
// still uses `DashboardVariable` and the union was dead code with zero
// references. Removed; only the shared plugin/sort vocabulary stays.

/// Sort order applied to a variable's options before they reach the UI.
/// Mirrors Perses' `sort` enum so an exported dashboard can carry the
/// same vocabulary.
enum VariableSort: String, Codable, CaseIterable, Sendable, Equatable {
    case none = "none"
    case alphabeticalAsc = "alphabetical-asc"
    case alphabeticalDesc = "alphabetical-desc"
    case numericalAsc = "numerical-asc"
    case numericalDesc = "numerical-desc"
    case alphabeticalCiAsc = "alphabetical-ci-asc"
    case alphabeticalCiDesc = "alphabetical-ci-desc"

    /// Apply this sort to a list of `VariableOption`.
    func apply(_ options: [VariableOption]) -> [VariableOption] {
        switch self {
        case .none:
            return options
        case .alphabeticalAsc:
            return options.sorted { $0.text < $1.text }
        case .alphabeticalDesc:
            return options.sorted { $0.text > $1.text }
        case .alphabeticalCiAsc:
            return options.sorted { $0.text.lowercased() < $1.text.lowercased() }
        case .alphabeticalCiDesc:
            return options.sorted { $0.text.lowercased() > $1.text.lowercased() }
        case .numericalAsc:
            return options.sorted { (Double($0.value) ?? .greatestFiniteMagnitude)
                                  < (Double($1.value) ?? .greatestFiniteMagnitude) }
        case .numericalDesc:
            return options.sorted { (Double($0.value) ?? -.greatestFiniteMagnitude)
                                  > (Double($1.value) ?? -.greatestFiniteMagnitude) }
        }
    }
}

/// Reference to a variable plugin (e.g. `StaticListVariable`).
/// `spec` is a typed JSON-encoded blob decoded by the plugin loader.
struct VariablePluginRef: Codable, Equatable, Sendable {
    var kind: String
    var spec: Data = Data()
}

/// Built-in variable plugin kinds shipped with toki-monitor.
enum BuiltinVariablePluginKind {
    /// User-supplied list of `(text,value)` options.
    static let staticList = "StaticListVariable"
    /// Predefined interval steps (e.g. 1m, 5m, 15m, 1h).
    static let interval = "IntervalVariable"
    /// Dynamic options pulled from a PromQL result's labels (model, project).
    /// toki-monitor equivalent of Perses' PrometheusLabelValuesVariable.
    static let tokiLabelValues = "TokiLabelValuesVariable"
    /// One fixed value the dashboard author sets and the reader cannot change.
    static let constant = "ConstantVariable"
    /// Free text the reader types. Grafana calls it a textbox.
    static let text = "TextVariable"
    /// Which dimensions to group by. Its options are label NAMES, not values.
    static let groupBy = "GroupByVariable"
    /// Reader-added label matchers, injected into every panel's query.
    static let adHoc = "AdHocFiltersVariable"
}

/// How a variable's selected values are written into a query.
///
/// Without this there is one join for every purpose, and it is wrong for half
/// of them: `model|project` is right inside a regex matcher and meaningless
/// inside `by (...)`. Mirrors Grafana's `${var:format}` syntax, limited to the
/// formats this query language can actually use.
enum VariableFormat: String, Sendable, Equatable {
    /// `a,b` — a list of names, which is what `by (...)` takes.
    case csv
    /// `a|b` — regex alternation, which is what a `=~` matcher takes.
    case pipe
    /// `a|b` with each value regex-escaped, for values containing `.` or `+`.
    case regex
    case singlequote
    case doublequote
    /// The values joined by nothing but a comma-space, unquoted and unescaped.
    case raw

    func apply(_ values: [String]) -> String {
        switch self {
        case .csv:  return values.joined(separator: ",")
        case .pipe: return values.joined(separator: "|")
        case .regex:
            return values.map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
        case .singlequote:
            return values.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }
                .joined(separator: ",")
        case .doublequote:
            return values.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ",")
        case .raw:  return values.joined(separator: ", ")
        }
    }
}

// MARK: - Plugin spec types

/// Spec for `StaticListVariable` — user supplies the options directly.
struct StaticListVariableSpec: Codable, Equatable, Sendable {
    var values: [VariableOption] = []
}

/// Spec for `IntervalVariable` — a fixed list of duration strings.
struct IntervalVariableSpec: Codable, Equatable, Sendable {
    var values: [String] = ["1m", "5m", "15m", "30m", "1h", "6h", "24h"]
}

/// Spec for `ConstantVariable` — one value fixed by the dashboard author.
///
/// Its purpose is to name a repeated literal once: a metric prefix, an
/// account id, a threshold that appears in six panels. The reader is not
/// offered a choice, so it renders hidden by default; a "menu" with exactly
/// one item that cannot be changed is noise in the toolbar.
struct ConstantVariableSpec: Codable, Equatable, Sendable {
    var value: String = ""
}

/// Spec for `TextVariable` — free text the reader types.
///
/// The stored `value` is the author's default. What the reader types lives in
/// the variable's `current`, so editing the default later does not silently
/// overwrite what someone is looking at.
struct TextVariableSpec: Codable, Equatable, Sendable {
    var value: String = ""
}

/// Spec for `GroupByVariable` — its options are the label NAMES a query
/// returns, so the reader picks which dimensions to break the data down by
/// rather than which values to keep.
struct GroupByVariableSpec: Codable, Equatable, Sendable {
    var datasource: DatasourceSelector?
    /// A query whose result carries the candidate dimensions. Left empty, the
    /// variable offers nothing rather than guessing at a label set.
    var query: String = ""
}

/// Spec for `AdHocFiltersVariable` — the query used to discover which labels
/// and values the reader can filter on. The filters themselves live on the
/// variable (`adHocFilters`), because they are not a selection from a list.
struct AdHocVariableSpec: Codable, Equatable, Sendable {
    var datasource: DatasourceSelector?
    var query: String = ""
}
