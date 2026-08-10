import Foundation

// MARK: - Field configuration and overrides
//
// Today display settings are one flat bag per panel (`PanelDisplayOptions`),
// so "unit" means one unit for everything the panel draws. That breaks as soon
// as a panel shows two kinds of number — tokens and cost on one chart — and it
// is why per-series colour, per-series axis, and `{{project}}` naming have no
// home.
//
// Grafana's answer is defaults + matcher-based overrides, and the reason it
// works there is the reason it can work here now: a series has a NAMED LABEL
// MAP, so a rule can say "fields where project=toki" without parsing a
// composite string. That was impossible before the frame contract.
//
// Deliberately smaller than Grafana's FieldConfig: only properties this app can
// actually apply today. Adding one later is additive; shipping settings that
// nothing honours is how a settings pane starts lying.

/// Display properties for a field. Every property is optional: nil means
/// "inherit", which is what makes defaults-then-overrides compose.
struct FieldDisplayConfig: Codable, Equatable, Sendable {
    /// Supports `{{label}}` templating, e.g. `{{project}} tokens`.
    var displayName: String?
    var unit: String?
    var decimals: Int?
    var min: Double?
    var max: Double?
    /// Hex string; nil leaves the palette to assign one.
    var color: String?

    var isEmpty: Bool {
        displayName == nil && unit == nil && decimals == nil
            && min == nil && max == nil && color == nil
    }

    /// Layer another config on top. Non-nil properties of `other` win, which is
    /// exactly how an override applies over a default.
    func merging(_ other: FieldDisplayConfig) -> FieldDisplayConfig {
        FieldDisplayConfig(
            displayName: other.displayName ?? displayName,
            unit: other.unit ?? unit,
            decimals: other.decimals ?? decimals,
            min: other.min ?? min,
            max: other.max ?? max,
            color: other.color ?? color
        )
    }
}

/// Which fields an override applies to.
enum FieldMatcher: Codable, Equatable, Sendable {
    /// Exact field name — "cost_usd".
    case byName(String)
    /// Regex over the field name.
    case byRegex(String)
    /// A label equals a value — the rule the old model could not express,
    /// because a series had no labels to match on.
    case byLabel(key: String, value: String)
    /// Every numeric field.
    case allNumeric

    func matches(_ field: Field) -> Bool {
        switch self {
        case let .byName(name):
            return field.name == name
        case let .byRegex(pattern):
            // An invalid pattern matches nothing rather than everything: a
            // typo should drop the rule, not restyle the whole panel.
            guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(field.name.startIndex..., in: field.name)
            return re.firstMatch(in: field.name, range: range) != nil
        case let .byLabel(key, value):
            return field.labels[key] == value
        case .allNumeric:
            return field.type == .number
        }
    }
}

/// One override rule.
struct FieldOverride: Codable, Equatable, Sendable {
    var matcher: FieldMatcher
    var config: FieldDisplayConfig
}

/// Panel-level display configuration: defaults for every field, plus rules.
struct FieldConfigSource: Codable, Equatable, Sendable {
    var defaults: FieldDisplayConfig = FieldDisplayConfig()
    var overrides: [FieldOverride] = []

    /// Resolve the effective config for one field. Later overrides win over
    /// earlier ones, so the list reads top-to-bottom like the editor shows it.
    func resolve(for field: Field) -> FieldDisplayConfig {
        overrides.reduce(defaults) { acc, rule in
            rule.matcher.matches(field) ? acc.merging(rule.config) : acc
        }
    }

    /// The display name for a field, with `{{label}}` placeholders filled from
    /// that field's own labels. An unresolved placeholder is left as written
    /// rather than blanked, so a typo is visible instead of silently producing
    /// an empty legend entry.
    func displayName(for field: Field, fallback: String) -> String {
        guard let template = resolve(for: field).displayName, !template.isEmpty else {
            return fallback
        }
        var out = template
        for (key, value) in field.labels {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return out
    }
}

// MARK: - Formatting

/// Renders a number using a field's resolved config. Units are the small set
/// this app's data actually uses; an unknown unit falls through to a plain
/// number rather than being dropped.
enum FieldFormatter {
    static func format(_ value: Double?, config: FieldDisplayConfig) -> String {
        // Absent stays visibly absent — never 0.
        guard let value else { return "-" }
        switch config.unit {
        case "currencyUSD":
            return TokenFormatter.formatCost(value)
        case "tokens":
            return TokenFormatter.formatTokens(UInt64(Swift.max(0, value)))
        case "percent":
            return String(format: "%.\(config.decimals ?? 1)f%%", value)
        case "percentUnit":
            return String(format: "%.\(config.decimals ?? 1)f%%", value * 100)
        case "short", .none:
            if let d = config.decimals { return String(format: "%.\(d)f", value) }
            return value == value.rounded()
                ? String(Int(value))
                : String(format: "%.2f", value)
        default:
            if let d = config.decimals { return String(format: "%.\(d)f", value) }
            return String(format: "%g", value)
        }
    }

    /// Units offered in the editor. Values are the persisted identifiers.
    static let knownUnits: [(id: String, label: String)] = [
        ("short", L.tr("숫자", "Number")),
        ("tokens", L.tr("토큰", "Tokens")),
        ("currencyUSD", L.tr("비용 (USD)", "Cost (USD)")),
        ("percent", L.tr("퍼센트 (0-100)", "Percent (0-100)")),
        ("percentUnit", L.tr("비율 (0-1)", "Ratio (0-1)")),
    ]
}
