import Testing
import Foundation
@testable import TokiMonitor

/// The milestone this whole rework aims at:
///
///   "A new query field, calculation or panel recipe can be rendered without
///    adding a PanelMetric case or modifying a renderer switch."
///
/// These tests assert exactly that, and check the field-driven reader
/// reproduces what the enum-switching extractor did for the built-in metrics —
/// so the enum can be demoted to a preset catalogue rather than deleted
/// wholesale.
@Suite("Field-driven rendering")
struct FieldSelectionTests {

    private func frame(_ name: String, labels: [String: String] = [:],
                       _ columns: [String: [Double?]]) -> Frame {
        let n = columns.values.first?.count ?? 0
        var fields: [Field] = [
            Field(name: "time", labels: labels,
                  values: .time((0..<n).map { Date(timeIntervalSince1970: Double($0) * 3600) }))
        ]
        for key in columns.keys.sorted() {
            fields.append(Field(name: key, labels: labels, values: .number(columns[key]!)))
        }
        return Frame(refId: "A", name: name, fields: fields)
    }

    // MARK: - The milestone

    /// A column no `PanelMetric` case has ever heard of renders through the
    /// same reader as every built-in one.
    @Test("an unknown field renders with no enum case and no renderer branch")
    func unknownFieldRenders() {
        let set = FrameSet(frames: [
            frame("s", ["some_future_measure": [10, 20, 30]])
        ])
        let value = FrameReader.singleValue(
            set, selection: FieldSelection(field: "some_future_measure", reducer: .sum)
        )
        #expect(value == 60)
    }

    /// And a value that exists only because a transformation computed it.
    @Test("a computed field renders the same way")
    func computedFieldRenders() {
        let set = FrameSet(frames: [
            frame("s", ["cache_read_input_tokens": [75], "input_tokens": [25]])
        ])
        let transformed = TransformationPipeline.apply(
            PanelPreset.transformations(for: .cacheHitRate), to: set
        )
        let value = FrameReader.singleValue(
            transformed, selection: PanelPreset.selection(for: .cacheHitRate)
        )
        #expect(value == 0.75)
    }

    // MARK: - Parity with the enum-driven extractor

    @Test("built-in presets read the fields the old switch read")
    func presetsMatchLegacyBehaviour() {
        #expect(PanelPreset.selection(for: .totalTokens).field == "total_tokens")
        #expect(PanelPreset.selection(for: .totalCost).field == "cost_usd")
        #expect(PanelPreset.selection(for: .apiCalls).field == "events")
        #expect(PanelPreset.selection(for: .reasoningTokens).field == "reasoning_output_tokens")
        // Only the ratio needs computing first — which is exactly the metric
        // that could not be expressed without an enum case before.
        #expect(PanelPreset.transformations(for: .totalTokens).isEmpty)
        #expect(PanelPreset.transformations(for: .cacheHitRate).count == 2)
    }

    @Test("totals sum across series, matching the old aggregate")
    func totalsSumAcrossSeries() {
        let set = FrameSet(frames: [
            frame("a", labels: ["model": "a"], ["total_tokens": [10, 5]]),
            frame("b", labels: ["model": "b"], ["total_tokens": [20, 1]]),
        ])
        #expect(FrameReader.singleValue(
            set, selection: FieldSelection(field: "total_tokens", reducer: .sum)) == 36)
    }

    /// "Top model" was an enum case with its own extractor branch.
    @Test("top series needs no dedicated metric")
    func topSeriesWithoutEnum() {
        let set = FrameSet(frames: [
            frame("small", labels: ["model": "small"], ["total_tokens": [1]]),
            frame("big", labels: ["model": "big"], ["total_tokens": [99]]),
        ])
        #expect(FrameReader.topSeries(
            set, selection: FieldSelection(field: "total_tokens", reducer: .sum)) == "big")
    }

    // MARK: - Honesty of absent data

    /// A stat card reading 0 for "no data" is indistinguishable from a real
    /// measurement of zero.
    @Test("no data stays absent instead of becoming zero")
    func absentStaysAbsent() {
        let set = FrameSet(frames: [frame("s", ["total_tokens": [nil, nil]])])
        #expect(FrameReader.singleValue(
            set, selection: FieldSelection(field: "total_tokens", reducer: .sum)) == nil)
        #expect(FrameReader.singleValue(FrameSet(), selection: FieldSelection()) == nil)
    }

    @Test("a missing field yields nil rather than another field's number")
    func missingFieldIsNotSubstituted() {
        let set = FrameSet(frames: [frame("s", ["total_tokens": [5]])])
        #expect(FrameReader.singleValue(
            set, selection: FieldSelection(field: "cost_usd", reducer: .sum)) == nil)
    }

    /// Panels outlive the queries that fed them; a nil selection keeps working
    /// when a query's columns change underneath it.
    @Test("no field named falls back to the first numeric column")
    func fallsBackToFirstNumeric() {
        let set = FrameSet(frames: [frame("s", ["alpha": [7]])])
        #expect(FrameReader.singleValue(set, selection: FieldSelection(reducer: .sum)) == 7)
    }

    // MARK: - Series and labels

    @Test("chart series keep their label-derived names")
    func seriesNamesComeFromLabels() {
        let set = FrameSet(frames: [
            Frame(refId: "A", fields: [
                Field(name: "time", labels: ["model": "opus", "project": "toki"],
                      values: .time([Date(timeIntervalSince1970: 0)])),
                Field(name: "total_tokens", labels: ["model": "opus", "project": "toki"],
                      values: .number([3])),
            ])
        ])
        let series = FrameReader.series(set, selection: FieldSelection(field: "total_tokens"))
        #expect(series.count == 1)
        #expect(series[0].name == "opus · toki")
        #expect(series[0].points.first?.value == 3)
    }

    /// What a groupBy or adhoc variable will read once those land.
    @Test("label values are discoverable from the data")
    func labelValuesAreDiscoverable() {
        let set = FrameSet(frames: [
            frame("a", labels: ["project": "toki"], ["v": [1]]),
            frame("b", labels: ["project": "wireguard"], ["v": [1]]),
            frame("c", labels: ["project": "toki"], ["v": [1]]),
        ])
        #expect(FrameReader.labelValues(set, key: "project") == ["toki", "wireguard"])
    }

    // MARK: - Reading a result with no panel to interpret it
    //
    // Explore runs an arbitrary query, so nothing tells it which column to
    // read. It used to hold a `TimeSeriesData` instead, which has fixed measure
    // columns — a query returning anything else arrived empty.

    @Test("every measure of every frame becomes a series")
    func allSeriesCoversEveryColumn() {
        let set = FrameSet(frames: [
            frame("opus", ["total_tokens": [1, 2], "cost_usd": [0.5, 0.5]]),
            frame("sonnet", ["total_tokens": [3, 4], "cost_usd": [0.1, 0.1]]),
        ])
        let names = FrameReader.allSeries(set).map(\.name).sorted()
        #expect(names == ["opus · cost_usd", "opus · total_tokens",
                          "sonnet · cost_usd", "sonnet · total_tokens"])
    }

    @Test("a column no PanelMetric names is still shown")
    func unknownColumnIsStillRead() {
        let set = FrameSet(frames: [frame("opus", ["something_new": [7, 8]])])
        let series = FrameReader.allSeries(set)
        #expect(series.map(\.name) == ["opus"], "one measure needs no suffix")
        #expect(series.first?.points.map(\.value) == [7, 8])
    }

    @Test("an absent bucket stays absent")
    func absenceSurvives() {
        let set = FrameSet(frames: [frame("opus", ["total_tokens": [1, nil, 3]])])
        #expect(FrameReader.allSeries(set).first?.points.map(\.value) == [1, nil, 3])
    }

    @Test("a frame with no time column contributes nothing rather than a fake axis")
    func framesWithoutTime() {
        let set = FrameSet(frames: [
            Frame(refId: "A", name: "totals", fields: [
                Field(name: "total_tokens", values: .number([5]))
            ])
        ])
        #expect(FrameReader.allSeries(set).isEmpty)
    }
}

/// A card headed "top model" must answer with a model. The full display name
/// also carries provider and any other grouping dimension, which reads as
/// noise when the question already named one of them.
@Suite("Top series reports the dimension that was asked for")
struct TopSeriesLabelTests {

    private func series(model: String, provider: String, value: Double) -> Frame {
        let labels = ["model": model, "provider": provider]
        return Frame(refId: "A", fields: [
            Field(name: "time", labels: labels, values: .time([Date(timeIntervalSince1970: 0)])),
            Field(name: "total_tokens", labels: labels, values: .number([value])),
        ])
    }

    @Test("asking for the model label returns just the model")
    func labelKeyNarrowsTheAnswer() {
        let set = FrameSet(frames: [
            series(model: "opus", provider: "claude_code", value: 99),
            series(model: "gpt", provider: "codex", value: 1),
        ])
        let sel = FieldSelection(field: "total_tokens", reducer: .sum)
        #expect(FrameReader.topSeries(set, selection: sel, labelKey: "model") == "opus")
        // Without a key the full identity is still available.
        #expect(FrameReader.topSeries(set, selection: sel) == "opus · claude_code")
    }

    @Test("a series missing that label falls back to its full name")
    func missingLabelFallsBack() {
        let set = FrameSet(frames: [
            Frame(refId: "A", name: "unnamed", fields: [
                Field(name: "total_tokens", values: .number([5]))
            ])
        ])
        #expect(FrameReader.topSeries(
            set, selection: FieldSelection(field: "total_tokens", reducer: .sum),
            labelKey: "model") == "unnamed")
    }
}
