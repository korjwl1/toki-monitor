import Testing
import Foundation
@testable import TokiMonitor

/// Overrides are the thing the old model could not express at all: matching a
/// series required an identity to match ON, and there was only one opaque
/// string. With labels, a rule can say "fields where project=toki".
@Suite("Field config and overrides")
struct FieldConfigTests {

    private func field(_ name: String, labels: [String: String] = [:],
                       type: FieldType = .number) -> Field {
        let values: FieldValues = type == .number ? .number([1]) : .string(["x"])
        return Field(name: name, labels: labels, values: values)
    }

    // MARK: - Layering

    @Test("an override layers over the defaults rather than replacing them")
    func overrideLayers() {
        let source = FieldConfigSource(
            defaults: FieldDisplayConfig(unit: "tokens", decimals: 0),
            overrides: [FieldOverride(matcher: .byName("cost_usd"),
                                      config: FieldDisplayConfig(unit: "currencyUSD"))]
        )
        let cost = source.resolve(for: field("cost_usd"))
        #expect(cost.unit == "currencyUSD", "the override wins on the property it sets")
        #expect(cost.decimals == 0, "and inherits the ones it does not")

        let tokens = source.resolve(for: field("total_tokens"))
        #expect(tokens.unit == "tokens", "an unmatched field keeps the defaults")
    }

    @Test("later overrides win over earlier ones")
    func laterOverridesWin() {
        let source = FieldConfigSource(
            overrides: [
                FieldOverride(matcher: .allNumeric, config: FieldDisplayConfig(color: "#111")),
                FieldOverride(matcher: .byName("v"), config: FieldDisplayConfig(color: "#222")),
            ]
        )
        #expect(source.resolve(for: field("v")).color == "#222")
    }

    // MARK: - Matchers

    /// The rule that was impossible before the frame contract.
    @Test("a label matcher selects one series without touching the others")
    func labelMatcherSelects() {
        let source = FieldConfigSource(
            overrides: [FieldOverride(matcher: .byLabel(key: "project", value: "toki"),
                                      config: FieldDisplayConfig(color: "#f00"))]
        )
        #expect(source.resolve(for: field("v", labels: ["project": "toki"])).color == "#f00")
        #expect(source.resolve(for: field("v", labels: ["project": "other"])).color == nil)
        #expect(source.resolve(for: field("v")).color == nil)
    }

    @Test("regex matches by field name")
    func regexMatcher() {
        let m = FieldMatcher.byRegex("^cache_")
        #expect(m.matches(field("cache_read_input_tokens")))
        #expect(!m.matches(field("total_tokens")))
    }

    /// A typo should drop the rule, not restyle the whole panel.
    @Test("an invalid regex matches nothing")
    func invalidRegexMatchesNothing() {
        #expect(!FieldMatcher.byRegex("[unclosed").matches(field("anything")))
    }

    @Test("allNumeric skips non-numeric columns")
    func allNumericSkipsStrings() {
        #expect(FieldMatcher.allNumeric.matches(field("v")))
        #expect(!FieldMatcher.allNumeric.matches(field("name", type: .string)))
    }

    // MARK: - Display names

    @Test("display name fills placeholders from the field's own labels")
    func displayNameTemplating() {
        let source = FieldConfigSource(
            defaults: FieldDisplayConfig(displayName: "{{project}} · {{model}}")
        )
        let f = field("v", labels: ["project": "toki", "model": "opus"])
        #expect(source.displayName(for: f, fallback: "x") == "toki · opus")
    }

    /// Blanking it would produce an empty legend entry the user cannot explain.
    @Test("an unresolved placeholder stays visible")
    func unresolvedPlaceholderIsVisible() {
        let source = FieldConfigSource(defaults: FieldDisplayConfig(displayName: "{{nope}}"))
        #expect(source.displayName(for: field("v"), fallback: "x") == "{{nope}}")
    }

    @Test("no template falls back to the given name")
    func fallbackWhenNoTemplate() {
        #expect(FieldConfigSource().displayName(for: field("v"), fallback: "series") == "series")
    }

    // MARK: - Formatting

    @Test("units format the way each measure is actually read")
    func unitsFormat() {
        #expect(FieldFormatter.format(1234.5, config: FieldDisplayConfig(unit: "currencyUSD"))
                    .contains("$"))
        #expect(FieldFormatter.format(0.756, config: FieldDisplayConfig(unit: "percentUnit",
                                                                       decimals: 1)) == "75.6%")
        #expect(FieldFormatter.format(75.6, config: FieldDisplayConfig(unit: "percent",
                                                                      decimals: 1)) == "75.6%")
        #expect(FieldFormatter.format(42, config: FieldDisplayConfig(unit: "short")) == "42")
    }

    /// The same rule as everywhere else in this rework.
    @Test("absent formats as a dash, never as zero")
    func absentIsNotZero() {
        #expect(FieldFormatter.format(nil, config: FieldDisplayConfig()) == "-")
        #expect(FieldFormatter.format(nil, config: FieldDisplayConfig(unit: "tokens")) == "-")
    }

    @Test("an unknown unit still prints the number")
    func unknownUnitStillPrints() {
        let out = FieldFormatter.format(12.5, config: FieldDisplayConfig(unit: "furlongs"))
        #expect(out.contains("12"))
    }
}

/// A panel that has never been edited must render exactly as before: the new
/// fields are optional, so an old dashboard decodes with nil and falls back to
/// its preset. Silent visual change on upgrade is the failure mode here.
@Suite("Panel keeps rendering when the new config is absent")
@MainActor
struct PanelConfigBackCompatTests {

    private func statPanel() -> PanelConfig {
        PanelConfig(title: "p", panelType: .stat, metric: .totalTokens,
                    gridPosition: GridPosition(column: 0, row: 0, width: 6, height: 1))
    }

    private func frames(_ total: Double) -> FrameSet {
        FrameSet(frames: [Frame(refId: "A", fields: [
            Field(name: "time", values: .time([Date(timeIntervalSince1970: 0)])),
            Field(name: "total_tokens", values: .number([total])),
        ])])
    }

    @Test("a panel with no fieldConfig or selection uses its preset")
    func fallsBackToPreset() {
        let panel = statPanel()
        #expect(panel.fieldConfig == nil)
        #expect(panel.fieldSelection == nil)
        let stat = CustomDashboardView.statValue(panel: panel, data: nil, frames: frames(1500))
        // Token formatting, exactly as the preset for totalTokens does it.
        #expect(stat.value.contains("1.5") || stat.value.contains("1500"))
    }

    @Test("a fieldConfig unit overrides the preset's formatting")
    func fieldConfigChangesFormatting() {
        var panel = statPanel()
        panel.fieldConfig = FieldConfigSource(
            defaults: FieldDisplayConfig(unit: "currencyUSD")
        )
        let stat = CustomDashboardView.statValue(panel: panel, data: nil, frames: frames(12))
        #expect(stat.value.contains("$"), "the panel's own config wins over the preset")
    }

    @Test("an explicit selection overrides the preset's field")
    func selectionOverridesPreset() {
        var panel = statPanel()
        panel.fieldSelection = FieldSelection(field: "other", reducer: .sum)
        let set = FrameSet(frames: [Frame(refId: "A", fields: [
            Field(name: "time", values: .time([Date(timeIntervalSince1970: 0)])),
            Field(name: "total_tokens", values: .number([999])),
            Field(name: "other", values: .number([7])),
        ])])
        let stat = CustomDashboardView.statValue(panel: panel, data: nil, frames: set)
        #expect(!stat.value.contains("999"), "must not read the preset's field")
        #expect(stat.value.contains("7"))
    }

    /// A cost figure is valued at prices that can change under it, so the
    /// card has to say which prices it used. Token counts do not move.
    @Test("a cost card says which prices it used, and a token card does not")
    func costCardIsLabelled() {
        #expect(CustomDashboardView.costSubtitle(for: .totalCost) != nil)
        #expect(CustomDashboardView.costSubtitle(for: .costByModel) != nil)
        #expect(CustomDashboardView.costSubtitle(for: .totalTokens) == nil)
        #expect(CustomDashboardView.costSubtitle(for: .apiCalls) == nil)
    }

    /// Encoding must stay stable for dashboards that predate these fields, or
    /// every export would churn.
    @Test("absent config round-trips as absent")
    func absentRoundTrips() throws {
        let panel = statPanel()
        let data = try JSONEncoder().encode(panel)
        let decoded = try JSONDecoder().decode(PanelConfig.self, from: data)
        #expect(decoded.fieldConfig == nil)
        #expect(decoded.fieldSelection == nil)
    }
}
