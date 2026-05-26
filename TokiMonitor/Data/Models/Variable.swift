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
