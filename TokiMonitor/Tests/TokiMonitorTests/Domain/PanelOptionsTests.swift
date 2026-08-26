import Testing
import Foundation
import SwiftUI
@testable import TokiMonitor

/// Contract R1, stated as tests: an option the editor shows changes what is
/// drawn. Every assertion here is over a pure function that the render calls,
/// so a change that stops honouring an option fails here rather than being
/// noticed by a user who thinks they mis-clicked.
@Suite("Panel display options")
@MainActor
struct PanelOptionsTests {

    // MARK: - Gaps are gaps (T019)

    private func series(_ values: [Double?]) -> [(model: String, points: [(date: Date, value: Double?)])] {
        [(model: "opus", points: values.enumerated().map {
            (date: Date(timeIntervalSince1970: Double($0.offset) * 3600), value: $0.element)
        })]
    }

    /// The failure this prevents: a nil bucket rendered as 0 draws a dive to
    /// the axis and a climb back out, and the reader cannot tell that invented
    /// V from a measured one.
    @Test("an absent sample breaks the line instead of being drawn as zero")
    func absentSampleBreaksTheLine() {
        let segments = TimeSeriesChartView.segments(from: series([10, 20, nil, 40, 50]))
        #expect(segments.count == 2, "the gap must split the line into two runs")
        #expect(segments[0].points.map(\.value) == [10, 20])
        #expect(segments[1].points.map(\.value) == [40, 50])
        #expect(!segments.flatMap { $0.points }.contains { $0.value == 0 },
                "no zero may be invented for the absent bucket")
        // Both runs still belong to the same series, so they keep one colour
        // and one legend entry.
        #expect(Set(segments.map(\.model)) == ["opus"])
        #expect(Set(segments.map(\.id)).count == 2, "runs need distinct ids or Charts joins them")
    }

    @Test("a run of absent samples is one gap, not several")
    func consecutiveGapsCollapse() {
        let segments = TimeSeriesChartView.segments(from: series([1, nil, nil, nil, 5]))
        #expect(segments.count == 2)
    }

    @Test("leading and trailing gaps produce no empty runs")
    func edgeGapsProduceNoEmptyRuns() {
        let segments = TimeSeriesChartView.segments(from: series([nil, 1, 2, nil]))
        #expect(segments.count == 1)
        #expect(segments[0].points.count == 2)
    }

    @Test("a fully absent series draws nothing rather than a flat zero line")
    func fullyAbsentSeriesDrawsNothing() {
        #expect(TimeSeriesChartView.segments(from: series([nil, nil])).isEmpty)
    }

    // MARK: - Gauge scale (T020)

    @Test("the panel's own min and max are the ends of the dial")
    func explicitScaleWins() {
        var options = PanelDisplayOptions()
        options.gaugeMin = 10
        options.gaugeMax = 20
        let scale = GaugePanelView.scale(for: 15, options: options)
        #expect(scale.min == 10)
        #expect(scale.max == 20)
        #expect(scale.fraction == 0.5)
    }

    @Test("with no max stated, the thresholds describe the range")
    func thresholdsSupplyTheScale() {
        var options = PanelDisplayOptions()
        options.thresholds = [ThresholdStep(value: 50, color: .orange),
                              ThresholdStep(value: 90, color: .red)]
        let scale = GaugePanelView.scale(for: 45, options: options)
        #expect(scale.max == 90)
        #expect(scale.fraction == 0.5)
    }

    /// A dial whose maximum is the value itself is pinned at full for every
    /// value, which says nothing at all.
    @Test("with nothing stated, the scale is a round number above the value")
    func derivedScaleIsRoundAndAboveTheValue() {
        let scale = GaugePanelView.scale(for: 1_234, options: PanelDisplayOptions())
        #expect(scale.max == 2_000)
        #expect((scale.fraction ?? 0) < 1)
        #expect(GaugePanelView.niceCeiling(0.4) == 0.5)
        #expect(GaugePanelView.niceCeiling(6_000) == 10_000)
    }

    @Test("a value past either end pins to that end rather than overflowing")
    func valueOutsideScaleIsClamped() {
        var options = PanelDisplayOptions()
        options.gaugeMin = 0
        options.gaugeMax = 100
        #expect(GaugePanelView.scale(for: 150, options: options).fraction == 1)
        #expect(GaugePanelView.scale(for: -50, options: options).fraction == 0)
    }

    @Test("no number means no arc, not an arc at zero")
    func absentValueDrawsNoArc() {
        #expect(GaugePanelView.scale(for: nil, options: PanelDisplayOptions()).fraction == nil)
    }

    // MARK: - Gauge threshold bands

    private func gauge(_ steps: [ThresholdStep],
                       mode: ThresholdMode = .absolute) -> PanelDisplayOptions {
        var options = PanelDisplayOptions()
        options.thresholds = steps
        options.thresholdMode = mode
        return options
    }

    @Test("each threshold becomes a band running to the next one, under a base")
    func bandsSpanToTheNextThreshold() {
        let scale = GaugePanelView.Scale(min: 0, max: 100, fraction: 0.5)
        let bands = GaugePanelView.bands(scale: scale, options: gauge([
            ThresholdStep(value: 80, color: .red),
            ThresholdStep(value: 50, color: .orange),
        ]))
        #expect(bands.count == 3)
        #expect(bands[0].start == 0.0)
        #expect(bands[0].end == 0.5, "the base runs from the bottom to the first step")
        #expect(bands[1].start == 0.5)
        #expect(bands[1].end == 0.8)
        #expect(bands[2].start == 0.8)
        #expect(bands[2].end == 1.0, "the last band runs to the end of the scale")
    }

    /// The base is the band that did not exist before: a value under every
    /// threshold sat on an uncoloured dial and the panel said nothing about it.
    @Test("with no thresholds there is no base band either")
    func noThresholdsNoBands() {
        let scale = GaugePanelView.Scale(min: 0, max: 100, fraction: 0.5)
        #expect(GaugePanelView.bands(scale: scale, options: PanelDisplayOptions()).isEmpty)
    }

    @Test("a threshold outside the scale leaves the dial in the base band")
    func outOfRangeThresholdIsClamped() {
        let scale = GaugePanelView.Scale(min: 0, max: 100, fraction: 0.5)
        let bands = GaugePanelView.bands(scale: scale, options: gauge([
            ThresholdStep(value: 200, color: .red),
        ]))
        #expect(bands.count == 1, "the step itself has no width on the dial")
        #expect(bands[0].start == 0.0)
        #expect(bands[0].end == 1.0, "and nothing on the dial has reached it")
    }

    /// A percentage step is measured against the scale, so the same 80 lands
    /// somewhere different on a dial that runs to 1000.
    @Test("a percentage threshold is placed on the scale, not read as a value")
    func percentageThresholdsFollowTheScale() {
        let scale = GaugePanelView.Scale(min: 0, max: 1000, fraction: 0.5)
        let bands = GaugePanelView.bands(
            scale: scale, options: gauge([ThresholdStep(value: 80, color: .red)],
                                         mode: .percentage)
        )
        #expect(bands.count == 2)
        #expect(bands[1].start == 0.8, "80% of the dial, not 80 on it")
    }

    @Test("percentage steps do not set the scale they are measured against")
    func percentageStepsDoNotSetTheScale() {
        let options = gauge([ThresholdStep(value: 80, color: .red)], mode: .percentage)
        let scale = GaugePanelView.scale(for: 400, options: options)
        #expect(scale.max == 500, "the value picks the ceiling, as with no thresholds")
    }

    @Test("switching threshold markers off leaves the value its own colour")
    func thresholdMarkersOffMeansNoThresholdColour() {
        var options = gauge([ThresholdStep(value: 10, color: .red)])
        options.showThresholdMarkers = false
        #expect(GaugePanelView.valueColor(90, options: options) == .accentColor)
        options.showThresholdMarkers = true
        #expect(GaugePanelView.valueColor(90, options: options) != .accentColor)
    }

    @Test("a value below every threshold takes the base colour, not the accent")
    func belowEveryThresholdIsTheBase() {
        var options = gauge([ThresholdStep(value: 10, color: .red)])
        options.thresholdBase = .green
        #expect(GaugePanelView.valueColor(1, options: options) == DS.threshold(.green))
        #expect(GaugePanelView.valueColor(90, options: options) == DS.threshold(.red))
    }

    /// The other carrier of the same fact, for a reader who cannot separate the
    /// hues and for VoiceOver (계약 R6).
    @Test("the band a gauge is in is available in words")
    func bandIsNamed() {
        let scale = GaugePanelView.Scale(min: 0, max: 100, fraction: 0.9)
        let options = gauge([ThresholdStep(value: 50, color: .orange),
                             ThresholdStep(value: 80, color: .red)])
        #expect(GaugePanelView.bandLabel(90, options: options, scale: scale) == "≥ 80")
        #expect(GaugePanelView.bandLabel(10, options: options, scale: scale) == "< 50")
        #expect(GaugePanelView.bandLabel(nil, options: options, scale: scale) == nil)
    }

    // MARK: - Unit and decimals (options tab)

    @Test("the unit and decimals set on a panel reach the number it prints")
    func unitAndDecimalsReachTheValue() throws {
        var panel = PanelConfig(title: "p", panelType: .stat, metric: .totalTokens,
                                gridPosition: GridPosition(column: 0, row: 0, width: 6, height: 2))
        panel.options.unit = "percentUnit"
        panel.options.decimals = 2
        let config = try #require(StatPanelView.panelDisplayConfig(panel))
        #expect(FieldFormatter.format(0.5, config: config) == "50.00%")
    }

    @Test("a panel that states no unit keeps the metric's own formatting")
    func noUnitMeansNoOverride() {
        let panel = PanelConfig(title: "p", panelType: .stat, metric: .totalTokens,
                                gridPosition: GridPosition(column: 0, row: 0, width: 6, height: 2))
        #expect(StatPanelView.panelDisplayConfig(panel) == nil)
    }

    // MARK: - Tooltip mode (T018)

    /// `.single` names one bar; `.all` lists the bucket. Both were in the
    /// editor and the tooltip always listed everything.
    @Test("single-series tooltip picks the stacked band under the cursor")
    func singleTooltipPicksOneBand() {
        let values: [(String, Double)] = [("opus", 10), ("sonnet", 20), ("haiku", 5)]
        #expect(BarChartTooltipOverlay.bandUnderCursor(values, at: 5).map(\.0) == ["opus"])
        #expect(BarChartTooltipOverlay.bandUnderCursor(values, at: 25).map(\.0) == ["sonnet"])
        #expect(BarChartTooltipOverlay.bandUnderCursor(values, at: 33).map(\.0) == ["haiku"])
        // Above the stack the reader is still pointing at the topmost bar.
        #expect(BarChartTooltipOverlay.bandUnderCursor(values, at: 900).map(\.0) == ["haiku"])
    }
}
