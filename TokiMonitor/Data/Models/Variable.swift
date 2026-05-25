import Foundation

// MARK: - Variable kinds (Perses-style)

/// Top-level Perses variable kind. Only two kinds exist; all dynamism lives
/// inside `ListVariable.spec.plugin`.
enum VariableKind: String, Codable, Sendable, Equatable {
    case textVariable = "TextVariable"
    case listVariable = "ListVariable"
}

/// Sort order applied to `ListVariableSpec.options` before they reach the UI.
/// Mirrors Perses' `sort` enum.
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

// MARK: - Plugin (variable side)

/// Reference to a variable plugin (e.g. `StaticListVariable`, `IntervalVariable`).
/// `spec` is a typed JSON-encoded blob decoded by the plugin factory.
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
}

// MARK: - Spec types

struct TextVariableSpec: Codable, Equatable, Sendable {
    var name: String
    var value: String = ""
    /// If true, the variable is fixed and not exposed in the toolbar.
    var constant: Bool = false
    var displayName: String?
    var hidden: Bool = false
}

struct ListVariableSpec: Codable, Equatable, Sendable {
    var name: String
    var displayName: String?
    var description: String?
    var hidden: Bool = false

    /// User's current selection (multiple values when `allowMultiple == true`).
    var current: VariableSelection = VariableSelection()

    /// Options resolved by the plugin (cached). Updated on plugin refresh.
    var options: [VariableOption] = []

    var allowAllValue: Bool = false
    var allowMultiple: Bool = false
    /// Value substituted for `$var` when the user has the "All" item selected.
    /// Defaults to `.*` to match Prometheus regex semantics.
    var customAllValue: String = ".*"
    /// Optional regex applied to each plugin-produced value before storage.
    var capturingRegexp: String?
    var sort: VariableSort = .none

    var plugin: VariablePluginRef
}

// MARK: - Variable (tagged union)

/// Perses-style dashboard variable. Either a `TextVariable` (static value) or
/// a `ListVariable` (plugin-resolved options + selection).
struct Variable: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var kind: VariableKind
    /// Set when `kind == .textVariable`.
    var text: TextVariableSpec?
    /// Set when `kind == .listVariable`.
    var list: ListVariableSpec?

    /// The variable's machine name (used in `$name` interpolation).
    var name: String {
        switch kind {
        case .textVariable: return text?.name ?? ""
        case .listVariable: return list?.name ?? ""
        }
    }
}

// MARK: - Static plugin specs

/// Spec for `StaticListVariable` — user supplies the options directly.
struct StaticListVariableSpec: Codable, Equatable, Sendable {
    var values: [VariableOption] = []
}

/// Spec for `IntervalVariable` — a fixed list of duration strings.
struct IntervalVariableSpec: Codable, Equatable, Sendable {
    var values: [String] = ["1m", "5m", "15m", "30m", "1h", "6h", "24h"]
}
