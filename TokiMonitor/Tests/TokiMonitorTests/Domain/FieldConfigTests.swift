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
