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

// MARK: - Thresholds
//
// Three things were missing and one was wrong.
//
// Missing: a BASE step (the band below the first threshold had no colour of its
// own, so a gauge under its lowest threshold drew the accent colour and said
// nothing); a PERCENTAGE mode (every threshold had to be restated when a scale
// changed); and any use of the steps outside the gauge and the state timeline.
//
// Wrong: the colour was a free string. That makes the contrast requirement
// unenforceable — `#ffff00` is 1.07:1 on a light panel — and it failed
// silently, because the resolver returned a neutral grey for anything it did
// not recognise, so a typo drew a band that looked deliberate (계약 R6, FR-027).

/// A threshold colour. The set is closed: every member is a token whose
/// contrast has been measured against both appearances, and the editor offers
/// no way to write anything else. The hex behind each token lives with the
/// other design colours in `DS.threshold(_:)`, which is where the measurements
/// are recorded.
enum ThresholdColor: String, Codable, CaseIterable, Sendable {
    case green
    case yellow
    case orange
    case red
    case blue
    case purple
    /// The default base: "nothing to say about this value yet".
    case neutral

    var displayName: String {
        switch self {
        case .green:   return L.tr("초록", "Green")
        case .yellow:  return L.tr("노랑", "Yellow")
        case .orange:  return L.tr("주황", "Orange")
        case .red:     return L.tr("빨강", "Red")
        case .blue:    return L.tr("파랑", "Blue")
        case .purple:  return L.tr("보라", "Purple")
        case .neutral: return L.tr("회색", "Neutral")
        }
    }

    /// Read a colour written by something other than this editor.
    ///
    /// Grafana's own palette names are accepted, because a dashboard imported
    /// from there should keep the colours its author chose rather than falling
    /// to the base colour. Anything else — a hex, a name from a palette this
    /// build does not have — is not guessed at: it returns nil, and
    /// `ThresholdStep` keeps the original string so that saving does not
    /// destroy it (계약 C1).
    static func named(_ raw: String) -> ThresholdColor? {
        if let exact = ThresholdColor(rawValue: raw) { return exact }
        let base = raw
            .replacingOccurrences(of: "dark-", with: "")
            .replacingOccurrences(of: "light-", with: "")
            .replacingOccurrences(of: "semi-", with: "")
            .replacingOccurrences(of: "super-", with: "")
            .lowercased()
        switch base {
        case "green":                    return .green
        case "yellow", "gold":           return .yellow
        case "orange":                   return .orange
        case "red":                      return .red
        case "blue":                     return .blue
        case "purple", "violet":         return .purple
        case "gray", "grey", "text":     return .neutral
        default:                         return nil
        }
    }
}

/// What a threshold's `value` is measured in.
enum ThresholdMode: String, Codable, CaseIterable, Sendable {
    /// The value is a number on the same scale as the data.
    case absolute
    /// The value is a percentage of the panel's scale, 0…100. Only offered
    /// where a scale exists to take a percentage OF (계약 R1).
    case percentage

    var displayName: String {
        switch self {
        case .absolute:   return L.tr("절대값", "Absolute")
        case .percentage: return L.tr("백분율", "Percentage")
        }
    }
}

/// Reading a value against a panel's thresholds.
///
/// One implementation for every panel type. The gauge and the state timeline
/// each had their own "which step has this value reached" loop; a stat card
/// showing a different band from the gauge beside it, over the same number and
/// the same steps, is exactly the kind of divergence two loops produce.
enum Thresholds {

    /// Where a step sits on the data's own scale.
    ///
    /// In percentage mode this needs the scale: a step at 80 means 80% of the
    /// span between its ends. Without one it returns nil rather than falling
    /// back to reading 80 as an absolute — a threshold silently moving from
    /// "80% of the plan" to "80 tokens" is a wrong answer that looks right.
    static func absoluteValue(of step: ThresholdStep, mode: ThresholdMode,
                              scale: ClosedRange<Double>?) -> Double? {
        switch mode {
        case .absolute:
            return step.value
        case .percentage:
            guard let scale else { return nil }
            return scale.lowerBound
                + (scale.upperBound - scale.lowerBound) * (step.value / 100)
        }
    }

    /// Steps in ascending order on the data's scale, paired with where they
    /// land. Steps that cannot be placed are dropped rather than stacked at
    /// zero.
    static func placed(_ steps: [ThresholdStep], mode: ThresholdMode,
                       scale: ClosedRange<Double>?) -> [(step: ThresholdStep, at: Double)] {
        steps
            .compactMap { step in
                absoluteValue(of: step, mode: mode, scale: scale).map { (step: step, at: $0) }
            }
            .sorted { $0.at < $1.at }
    }

    /// The highest step this value has reached, or nil for the base band.
    static func reached(_ value: Double?, steps: [ThresholdStep],
                        mode: ThresholdMode = .absolute,
                        scale: ClosedRange<Double>? = nil) -> ThresholdStep? {
        guard let value else { return nil }
        return placed(steps, mode: mode, scale: scale)
            .last { value >= $0.at }?
            .step
    }

    /// The colour for a value: the step it has reached, or the base.
    static func color(for value: Double?, base: ThresholdColor,
                      steps: [ThresholdStep], mode: ThresholdMode = .absolute,
                      scale: ClosedRange<Double>? = nil) -> ThresholdColor {
        reached(value, steps: steps, mode: mode, scale: scale)?.color ?? base
    }

    /// What to call the band a value is in — "≥ 80%", "< 50", "기준".
    ///
    /// Colour must never be the only carrier of meaning (계약 R6), and this is
    /// the other carrier: every panel that colours something by threshold
    /// prints or speaks this beside it.
    static func label(for value: Double?, steps: [ThresholdStep],
                      mode: ThresholdMode = .absolute,
                      scale: ClosedRange<Double>? = nil) -> String? {
        guard value != nil else { return nil }
        // Nil, not "< 80%", when percentage steps have no scale to sit on.
        // There is nothing true to say about the band in that case, and naming
        // one anyway would be the silent wrong answer `absoluteValue` refuses
        // to give.
        let placed = placed(steps, mode: mode, scale: scale)
        guard let lowest = placed.first else { return nil }
        let suffix = mode == .percentage ? "%" : ""
        guard let step = reached(value, steps: steps, mode: mode, scale: scale) else {
            return "< \(number(lowest.step.value))\(suffix)"
        }
        return "≥ \(number(step.value))\(suffix)"
    }

    private static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}

// MARK: - What a panel resolves for a field

/// One property of `FieldDisplayConfig`, so a panel type can say which ones its
/// render actually reads.
///
/// The editor offers a property on a panel only when that panel's render
/// honours it (계약 R1). Without this the override editor would be one list of
/// six controls, most of which do nothing on most panel types — and a control
/// that silently does nothing sends the reader hunting for their own mistake.
enum FieldDisplayProperty: String, CaseIterable, Sendable {
    case displayName
    case unit
    case decimals
    case color
    case min
    case max

    var label: String {
        switch self {
        case .displayName: return L.tr("표시 이름", "Display name")
        case .unit:        return L.tr("단위", "Unit")
        case .decimals:    return L.tr("소수점 자릿수", "Decimals")
        case .color:       return L.tr("색", "Colour")
        case .min:         return L.tr("최소", "Min")
        case .max:         return L.tr("최대", "Max")
        }
    }
}

extension FieldDisplayConfig {
    /// Drop everything the panel drawing this field cannot honour.
    ///
    /// Applied on the way OUT of the resolver rather than on the way in: a
    /// dashboard authored elsewhere, or on a panel that was a line chart
    /// yesterday, may carry properties this type does not read. They stay in
    /// the document — deleting a rule because the panel type changed would lose
    /// work the reader did — and simply do not reach the render.
    func honouring(_ properties: Set<FieldDisplayProperty>) -> FieldDisplayConfig {
        FieldDisplayConfig(
            displayName: properties.contains(.displayName) ? displayName : nil,
            unit: properties.contains(.unit) ? unit : nil,
            decimals: properties.contains(.decimals) ? decimals : nil,
            min: properties.contains(.min) ? min : nil,
            max: properties.contains(.max) ? max : nil,
            color: properties.contains(.color) ? color : nil
        )
    }
}

extension PanelConfig {
    /// The display config for one of this panel's fields.
    ///
    /// Three layers, innermost first: the panel's own unit and decimals (the
    /// Options tab, which is where a reader sets "this whole panel is money"),
    /// then `fieldConfig`'s defaults, then every override whose matcher hits —
    /// later rules winning, so the list reads top to bottom the way the editor
    /// shows it.
    ///
    /// This is the single resolution point. Before it there was one, inline, in
    /// the stat card; every other panel type ignored `fieldConfig` entirely, so
    /// a rule the reader could see in the JSON changed one panel out of seven.
    func displayConfig(for field: Field?) -> FieldDisplayConfig {
        var resolved = FieldDisplayConfig(unit: options.unit, decimals: options.decimals)
        if let fieldConfig {
            resolved = resolved.merging(fieldConfig.defaults)
            if let field {
                for rule in fieldConfig.overrides where rule.matcher.matches(field) {
                    resolved = resolved.merging(rule.config)
                }
            }
        }
        return resolved.honouring(panelType.honouredFieldProperties)
    }

    /// The name to draw for a series, after any `displayName` override.
    func seriesName(_ fallback: String, field: Field?) -> String {
        guard let template = displayConfig(for: field).displayName, !template.isEmpty
        else { return fallback }
        var out = template
        for (key, value) in field?.labels ?? [:] {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return out
    }

    /// Whether anything about this panel's fields has been configured. Renders
    /// take a cheaper path when nothing has.
    var hasFieldConfig: Bool {
        guard let fieldConfig else { return false }
        return !fieldConfig.defaults.isEmpty || !fieldConfig.overrides.isEmpty
    }
}
