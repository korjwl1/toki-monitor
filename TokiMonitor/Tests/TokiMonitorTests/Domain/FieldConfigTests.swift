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
        let stat = StatPanelView.statValue(panel: panel, data: nil, frames: frames(1500))
        // Token formatting, exactly as the preset for totalTokens does it.
        #expect(stat.value.contains("1.5") || stat.value.contains("1500"))
    }

    @Test("a fieldConfig unit overrides the preset's formatting")
    func fieldConfigChangesFormatting() {
        var panel = statPanel()
        panel.fieldConfig = FieldConfigSource(
            defaults: FieldDisplayConfig(unit: "currencyUSD")
        )
        let stat = StatPanelView.statValue(panel: panel, data: nil, frames: frames(12))
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
        let stat = StatPanelView.statValue(panel: panel, data: nil, frames: set)
        #expect(!stat.value.contains("999"), "must not read the preset's field")
        #expect(stat.value.contains("7"))
    }

    /// A cost figure is valued at prices that can change under it, so the
    /// card has to say which prices it used. Token counts do not move.
    @Test("a cost card says which prices it used, and a token card does not")
    func costCardIsLabelled() {
        #expect(StatPanelView.costSubtitle(for: .totalCost) != nil)
        #expect(StatPanelView.costSubtitle(for: .costByModel) != nil)
        #expect(StatPanelView.costSubtitle(for: .totalTokens) == nil)
        #expect(StatPanelView.costSubtitle(for: .apiCalls) == nil)
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

// MARK: - Transformations survive save → load

/// The pipeline and its six transformations have had tests since the frame
/// contract landed. What had no test — because it had no code — is whether a
/// pipeline a user builds is still there after closing the dashboard. It was
/// not: `PanelConfig` had nowhere to put one.
@Suite("Stored transformation pipeline")
struct TransformationStorageTests {

    private func panel() -> PanelConfig {
        PanelConfig(title: "p", panelType: .timeSeries, metric: .totalTokens,
                    gridPosition: GridPosition(column: 0, row: 0, width: 12, height: 4))
    }

    private func roundTrip(_ p: PanelConfig) throws -> PanelConfig {
        try JSONDecoder().decode(PanelConfig.self, from: JSONEncoder().encode(p))
    }

    private func encoded(_ p: PanelConfig) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any] ?? [:]
    }

    /// A panel as a build with more features than this one would have written
    /// it: the real encoded shape, plus keys added by hand. Written this way
    /// rather than as a JSON literal so the test cannot drift out of step with
    /// the fields the encoder actually requires.
    private func decode(_ p: PanelConfig,
                        addingRawKeys extra: [String: Any]) throws -> PanelConfig {
        var object = try encoded(p)
        for (key, value) in extra { object[key] = value }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(PanelConfig.self, from: data)
    }

    @Test("a pipeline is still there after a save and a load")
    func pipelineRoundTrips() throws {
        var p = panel()
        p.transformations = [
            TransformationStep(kind: .sortBy(SortByTransformation(field: "total_tokens",
                                                                  reducer: .sum,
                                                                  descending: true))),
            TransformationStep(kind: .limit(LimitTransformation(count: 10))),
        ]
        let out = try roundTrip(p)
        #expect(out.transformations.count == 2)
        #expect(out.transformations.map(\.kind.typeID) == ["sortBy", "limit"],
                "order is part of the pipeline, not an accident of the encoder")
        guard case let .limit(limit) = out.transformations[1].kind else {
            Issue.record("second step lost its type"); return
        }
        #expect(limit.count == 10, "and its options came back too")
    }

    @Test("every transformation type survives the trip with its options")
    func everyTypeRoundTrips() throws {
        var p = panel()
        p.transformations = [
            TransformationStep(kind: .reduce(ReduceTransformation(reducer: .mean))),
            TransformationStep(kind: .calculateField(
                CalculateFieldTransformation(left: "a", right: "b", operation: .divide,
                                             alias: "ratio", replaceFields: true))),
            TransformationStep(kind: .organize(
                OrganizeTransformation(excluded: ["noise"], renamed: ["a": "A"], order: ["A"]))),
            TransformationStep(kind: .filterByValue(
                FilterByValueTransformation(field: "a", comparison: .greaterOrEqual, value: 5))),
            TransformationStep(kind: .sortBy(SortByTransformation(field: "a"))),
            TransformationStep(kind: .limit(LimitTransformation(count: 3))),
        ]
        let out = try roundTrip(p)
        #expect(out.transformations.map(\.kind) == p.transformations.map(\.kind))
    }

    /// Off is not deleted. A reader comparing "with and without this step"
    /// should not have to rebuild it.
    @Test("a disabled step is kept, and stays disabled")
    func disabledStepIsKept() throws {
        var p = panel()
        p.transformations = [
            TransformationStep(kind: .limit(LimitTransformation(count: 5)), disabled: true),
        ]
        let out = try roundTrip(p)
        #expect(out.transformations.count == 1)
        #expect(out.transformations[0].disabled)
    }

    @Test("a disabled step does not run")
    func disabledStepDoesNotRun() {
        let set = FrameSet(frames: (0..<5).map {
            Frame(refId: "A", name: "s\($0)",
                  fields: [Field(name: "v", values: .number([1]))])
        })
        let step = TransformationStep(kind: .limit(LimitTransformation(count: 2)))
        #expect(TransformationPipeline.apply(steps: [step], to: set).frames.count == 2)
        var off = step
        off.disabled = true
        #expect(TransformationPipeline.apply(steps: [off], to: set).frames.count == 5,
                "switching a step off leaves the data untouched")
    }

    /// The panel-level guarantee this feature already makes for unknown KEYS
    /// has to hold for an unknown step too: a pipeline written by a newer build
    /// must not be deleted by this one on the way through.
    @Test("a step this build cannot run is preserved, not dropped")
    func unknownStepIsPreserved() throws {
        let decoded = try decode(panel(), addingRawKeys: [
            "transformations": [
                ["id": "joinByField", "options": ["byField": "time", "mode": "outer"]],
                ["id": "limit", "options": ["count": 4]],
            ],
        ])
        #expect(decoded.transformations.count == 2)
        #expect(decoded.transformations[0].isUnknown)
        #expect(decoded.transformations[0].kind.typeID == "joinByField")
        #expect(!decoded.transformations[1].isUnknown, "the runnable step beside it still runs")

        let steps = try encoded(decoded)["transformations"] as? [[String: Any]]
        #expect(steps?.count == 2)
        #expect(steps?[0]["id"] as? String == "joinByField")
        let options = steps?[0]["options"] as? [String: Any]
        #expect(options?["byField"] as? String == "time",
                "the options of a step this build cannot run come back verbatim")
        #expect(options?["mode"] as? String == "outer")
    }

    /// An unrunnable step must also be inert. Applying it as some default would
    /// change the numbers on screen in a way no editor row explains.
    @Test("an unknown step changes nothing")
    func unknownStepIsInert() {
        let set = FrameSet(frames: [Frame(refId: "A",
                                          fields: [Field(name: "v", values: .number([1, 2]))])])
        let step = TransformationStep(kind: .unknown(id: "joinByField",
                                                     options: ["byField": .string("time")]))
        #expect(TransformationPipeline.apply(steps: [step], to: set) == set)
    }

    /// Round-tripping must not disturb the unknown-key preservation that
    /// already exists at the panel level — the two mechanisms sit in the same
    /// encoder, and the new field must not shadow or displace them.
    @Test("a pipeline and preserved unknown keys survive the same trip")
    func pipelineAndUnknownKeysCoexist() throws {
        var decoded = try decode(panel(), addingRawKeys: [
            "transformations": [["id": "limit", "options": ["count": 7]]],
            "libraryPanel": "shared-1",
            "interactive": ["mode": "drill", "depth": 2],
        ])
        #expect(decoded.transformations.count == 1)
        #expect(decoded.unknownFields["libraryPanel"] == .string("shared-1"))

        // Edit the pipeline the way the editor does, then save.
        decoded.transformations.append(TransformationStep(kind: .reduce(ReduceTransformation())))
        let out = try encoded(decoded)
        #expect((out["transformations"] as? [[String: Any]])?.count == 2)
        #expect(out["libraryPanel"] as? String == "shared-1",
                "editing the pipeline must not cost the panel its unknown keys")
        let interactive = out["interactive"] as? [String: Any]
        #expect(interactive?["mode"] as? String == "drill")
        #expect(interactive?["depth"] as? Int == 2)
    }

    /// A panel that has never been given a pipeline must encode exactly as it
    /// did before this field existed, or every dashboard churns on first save.
    @Test("an empty pipeline is not written")
    func emptyPipelineIsOmitted() throws {
        let out = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(panel())
        ) as? [String: Any]
        #expect(out?["transformations"] == nil)
    }
}

// MARK: - An override reaches the column it names, and no other

/// The claim US3 makes: two columns of different character in one panel, and a
/// rule about one of them that leaves the other alone. The resolver could
/// already do this; nothing outside the stat card asked it to.
@Suite("Overrides reach the render")
@MainActor
struct FieldOverrideApplicationTests {

    private func panel(_ type: PanelType) -> PanelConfig {
        PanelConfig(title: "p", panelType: type, metric: .totalTokens,
                    gridPosition: GridPosition(column: 0, row: 0, width: 12, height: 4))
    }

    private func field(_ name: String, labels: [String: String] = [:]) -> Field {
        Field(name: name, labels: labels, values: .number([1]))
    }

    @Test("a rule on one column does not touch its neighbour")
    func ruleAppliesToTheNamedColumnOnly() {
        var p = panel(.table)
        p.options.unit = "tokens"
        p.fieldConfig = FieldConfigSource(overrides: [
            FieldOverride(matcher: .byName("cost_usd"),
                          config: FieldDisplayConfig(unit: "currencyUSD", decimals: 2)),
        ])
        let cost = p.displayConfig(for: field("cost_usd"))
        #expect(cost.unit == "currencyUSD")
        #expect(cost.decimals == 2)

        let tokens = p.displayConfig(for: field("total_tokens"))
        #expect(tokens.unit == "tokens", "the panel's own unit still stands here")
        #expect(tokens.decimals == nil)

        #expect(FieldFormatter.format(12.5, config: cost).contains("$"))
        #expect(!FieldFormatter.format(12.5, config: tokens).contains("$"))
    }

    /// The layering, end to end: the Options tab underneath, then the panel's
    /// defaults, then the rule.
    @Test("panel options are the floor a rule builds on")
    func panelOptionsAreTheFloor() {
        var p = panel(.table)
        p.options.unit = "tokens"
        p.options.decimals = 0
        p.fieldConfig = FieldConfigSource(
            defaults: FieldDisplayConfig(decimals: 1),
            overrides: [FieldOverride(matcher: .byName("cost_usd"),
                                      config: FieldDisplayConfig(unit: "currencyUSD"))]
        )
        let cost = p.displayConfig(for: field("cost_usd"))
        #expect(cost.unit == "currencyUSD", "the rule wins on what it sets")
        #expect(cost.decimals == 1, "the defaults win over the Options tab")
    }

    /// A label matcher is the rule the old model could not express at all.
    @Test("a label rule picks out one series and leaves the rest")
    func labelRuleSelectsOneSeries() {
        var p = panel(.timeSeries)
        p.fieldConfig = FieldConfigSource(overrides: [
            FieldOverride(matcher: .byLabel(key: "provider", value: "codex"),
                          config: FieldDisplayConfig(color: "purple")),
        ])
        #expect(p.displayConfig(for: field("v", labels: ["provider": "codex"])).color == "purple")
        #expect(p.displayConfig(for: field("v", labels: ["provider": "claude"])).color == nil)
    }

    /// R1 in the other direction. A gauge has no legend to rename, so a rule
    /// carrying a display name must not reach its render — and must not be
    /// deleted from the document either, because the panel type can change back.
    @Test("a property the panel type cannot honour does not reach it, and is kept")
    func unhonouredPropertyIsDroppedNotDeleted() throws {
        var p = panel(.gauge)
        p.fieldConfig = FieldConfigSource(overrides: [
            FieldOverride(matcher: .allNumeric,
                          config: FieldDisplayConfig(displayName: "renamed",
                                                     unit: "currencyUSD")),
        ])
        let resolved = p.displayConfig(for: field("v"))
        #expect(resolved.displayName == nil, "a gauge has no series name to change")
        #expect(resolved.unit == "currencyUSD", "and does honour formatting")

        let decoded = try JSONDecoder().decode(
            PanelConfig.self, from: JSONEncoder().encode(p)
        )
        #expect(decoded.fieldConfig?.overrides.first?.config.displayName == "renamed",
                "the rule survives the round trip whatever the panel type reads")
    }

    /// Every panel type offers exactly what its render reads. A type that
    /// offered more would be shipping controls that do nothing (계약 R1).
    @Test("what a panel type offers is what it honours")
    func offeredMatchesHonoured() {
        // A gauge's colour comes from its thresholds; a pie slice's from the
        // model palette it shares with every other panel.
        #expect(!PanelType.gauge.honouredFieldProperties.contains(.color))
        #expect(!PanelType.pieChart.honouredFieldProperties.contains(.color))
        #expect(!PanelType.stat.honouredFieldProperties.contains(.displayName))
        #expect(PanelType.timeSeries.honouredFieldProperties.count
                    == FieldDisplayProperty.allCases.count,
                "a line chart is the one type that reads all six")
        #expect(PanelType.rowPanel.honouredFieldProperties.isEmpty)
        #expect(PanelType.unknown.honouredFieldProperties.isEmpty)
    }

    // MARK: - Renaming reaches the chart

    /// Two series distinguished only by a label — the shape the frame contract
    /// exists for, and the one a matcher can address. The label sits on every
    /// field of a frame, which is what makes it the frame's own identity and
    /// therefore its display name.
    private func twoSeries() -> FrameSet {
        func frame(_ provider: String, _ value: Double) -> Frame {
            let labels = ["provider": provider]
            return Frame(refId: "A", fields: [
                Field(name: "time", labels: labels,
                      values: .time([Date(timeIntervalSince1970: 0)])),
                Field(name: "total_tokens", labels: labels, values: .number([value])),
            ])
        }
        return FrameSet(frames: [frame("codex", 10), frame("claude", 20)])
    }

    @Test("a display name rule renames the series it matches and no other")
    func displayNameReachesTheSeries() {
        var p = panel(.timeSeries)
        p.fieldConfig = FieldConfigSource(overrides: [
            FieldOverride(matcher: .byLabel(key: "provider", value: "codex"),
                          config: FieldDisplayConfig(displayName: "{{provider}} tokens")),
        ])
        let names = PanelSeries.seriesNames(metric: .totalTokens, panel: p,
                                            frames: twoSeries(), data: nil)
        #expect(names.contains("codex tokens"))
        #expect(names.contains("claude"), "the unmatched series keeps its own name")
    }

    @Test("the resolved config for each series is keyed by the name drawn")
    func stylesAreKeyedByDrawnName() {
        var p = panel(.timeSeries)
        p.fieldConfig = FieldConfigSource(overrides: [
            FieldOverride(matcher: .byLabel(key: "provider", value: "codex"),
                          config: FieldDisplayConfig(displayName: "codex tokens",
                                                     unit: "currencyUSD")),
        ])
        let styles = PanelSeries.styles(metric: .totalTokens, panel: p, frames: twoSeries())
        #expect(styles["codex tokens"]?.unit == "currencyUSD")
        #expect(styles["claude"]?.unit == nil)
    }

    /// A panel with no rules must cost nothing and change nothing.
    @Test("no rules means no styles and no renaming")
    func noRulesIsInert() {
        let p = panel(.timeSeries)
        #expect(PanelSeries.styles(metric: .totalTokens, panel: p, frames: twoSeries()).isEmpty)
        let names = PanelSeries.seriesNames(metric: .totalTokens, panel: p,
                                            frames: twoSeries(), data: nil)
        #expect(names.sorted() == ["claude", "codex"])
    }
}

// MARK: - Thresholds

@Suite("Thresholds: base, percentage, and a closed colour set")
struct ThresholdTests {

    private let steps = [
        ThresholdStep(value: 50, color: .orange),
        ThresholdStep(value: 80, color: .red),
    ]

    @Test("the highest step reached wins, and below all of them is the base")
    func reachedAndBase() {
        #expect(Thresholds.reached(90, steps: steps)?.value == 80)
        #expect(Thresholds.reached(50, steps: steps)?.value == 50, "a step is reached at its own value")
        #expect(Thresholds.reached(10, steps: steps) == nil)
        #expect(Thresholds.color(for: 10, base: .green, steps: steps) == .green)
        #expect(Thresholds.color(for: 90, base: .green, steps: steps) == .red)
    }

    @Test("an absent value is in no band at all")
    func absentIsNoBand() {
        #expect(Thresholds.reached(nil, steps: steps) == nil)
        #expect(Thresholds.label(for: nil, steps: steps) == nil)
    }

    @Test("a percentage step is placed on the scale it is a percentage of")
    func percentageFollowsTheScale() {
        let percent = [ThresholdStep(value: 80, color: .red)]
        #expect(Thresholds.reached(900, steps: percent, mode: .percentage,
                                   scale: 0...1000)?.value == 80)
        #expect(Thresholds.reached(700, steps: percent, mode: .percentage,
                                   scale: 0...1000) == nil,
                "70% of the scale has not reached the 80% step")
        #expect(Thresholds.reached(90, steps: percent, mode: .percentage,
                                   scale: 0...100)?.value == 80,
                "the same step lands somewhere else on a different scale")
    }

    /// Reading 80% as 80 would be a wrong answer that looks right.
    @Test("a percentage step with no scale is not read as an absolute one")
    func percentageWithoutScaleIsNotAbsolute() {
        let percent = [ThresholdStep(value: 80, color: .red)]
        #expect(Thresholds.reached(90, steps: percent, mode: .percentage) == nil)
        #expect(Thresholds.color(for: 90, base: .green, steps: percent, mode: .percentage)
                    == .green)
        #expect(Thresholds.label(for: 90, steps: percent, mode: .percentage) == nil,
                "there is nothing true to say about the band")
    }

    /// Colour is never the only carrier of meaning (계약 R6).
    @Test("every band has a name, not just a colour")
    func everyBandIsNamed() {
        #expect(Thresholds.label(for: 90, steps: steps) == "≥ 80")
        #expect(Thresholds.label(for: 60, steps: steps) == "≥ 50")
        #expect(Thresholds.label(for: 10, steps: steps) == "< 50")
        #expect(Thresholds.label(for: 90, steps: [ThresholdStep(value: 80, color: .red)],
                                 mode: .percentage, scale: 0...100) == "≥ 80%")
    }

    // MARK: The closed set

    @Test("a colour from this build's own set round-trips as itself")
    func knownColourRoundTrips() throws {
        let step = ThresholdStep(value: 80, color: .red)
        let decoded = try JSONDecoder().decode(
            ThresholdStep.self, from: JSONEncoder().encode(step)
        )
        #expect(decoded.color == .red)
        #expect(decoded.unknownColorRaw == nil)
    }

    /// A dashboard from Grafana should keep the colours its author chose.
    @Test("a palette name from elsewhere maps onto the set")
    func foreignPaletteNamesMap() throws {
        for (raw, expected): (String, ThresholdColor) in [
            ("dark-red", .red), ("semi-dark-orange", .orange), ("light-green", .green),
            ("gold", .yellow), ("text", .neutral), ("grey", .neutral),
        ] {
            let json = Data("{\"value\":1,\"color\":\"\(raw)\"}".utf8)
            let step = try JSONDecoder().decode(ThresholdStep.self, from: json)
            #expect(step.color == expected, "\(raw)")
            #expect(step.unknownColorRaw == raw,
                    "and the string is kept so saving does not rewrite it")
        }
    }

    /// A colour this build cannot place is not guessed at — and not destroyed.
    @Test("an unplaceable colour is kept on disk and not drawn")
    func unplaceableColourIsKept() throws {
        let json = Data("{\"value\":1,\"color\":\"#EAB839\"}".utf8)
        var step = try JSONDecoder().decode(ThresholdStep.self, from: json)
        #expect(step.color == .neutral, "drawing it as red would be evidence nobody has")
        #expect(step.unknownColorRaw == "#EAB839")

        let out = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(step)
        ) as? [String: Any]
        #expect(out?["color"] as? String == "#EAB839")

        // Once the reader picks one, the old string is no longer what it says.
        step.color = .yellow
        #expect(step.unknownColorRaw == nil)
        let edited = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(step)
        ) as? [String: Any]
        #expect(edited?["color"] as? String == "yellow")
    }

    /// Adding base and mode must not make every dashboard written before them
    /// undecodable — which is exactly what the strict decoder would have done.
    @Test("options written before base and mode existed still decode")
    func optionsWithoutBaseStillDecode() throws {
        let json = Data("""
        {"colorMode":"value","graphMode":"none","legendPosition":"bottom","showLegend":true,
         "tooltipMode":"single","fillOpacity":0.1,"lineWidth":2,"showHeader":true,
         "showThresholdMarkers":true,"thresholds":[{"value":80,"color":"red"}]}
        """.utf8)
        let options = try JSONDecoder().decode(PanelDisplayOptions.self, from: json)
        #expect(options.thresholdBase == .neutral)
        #expect(options.thresholdMode == .absolute)
        #expect(options.thresholds.first?.color == .red)
    }

    @Test("an options bag with nothing in it decodes to the defaults")
    func emptyOptionsDecode() throws {
        let options = try JSONDecoder().decode(PanelDisplayOptions.self, from: Data("{}".utf8))
        #expect(options == PanelDisplayOptions())
    }
}
