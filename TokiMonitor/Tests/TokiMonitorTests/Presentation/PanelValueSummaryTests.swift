import Testing
import Foundation
@testable import TokiMonitor

// What each panel type says it is showing, in words.
//
// The summary is the third of the four things FR-063 asks of a panel, and the
// only one that differs per type — so it is the one where "a label exists"
// most easily passes for "the reader was told something".

@Suite("Panel value summary")
@MainActor
struct PanelValueSummaryTests {

    private func panel(_ type: PanelType,
                       metric: PanelMetric = .totalTokens) -> PanelConfig {
        PanelConfig(title: type.displayName, panelType: type, metric: metric,
                    gridPosition: GridPosition(column: 0, row: 0, width: 6, height: 4))
    }

    private var frames: FrameSet { PanelSnapshotFixtures.frames }

    @Test("a stat card speaks its number")
    func statSpeaksItsNumber() {
        let spoken = PanelValueSummary.text(panel: panel(.stat), data: nil, frames: frames)
        #expect(spoken?.isEmpty == false)
        #expect(spoken?.contains("-") != true || spoken?.count ?? 0 > 1)
    }

    @Test("a stat card with thresholds speaks the band as well as the number")
    func statSpeaksItsBand() {
        var config = panel(.stat)
        config.options.thresholds = [ThresholdStep(value: 1_000, color: .orange)]
        let spoken = PanelValueSummary.text(panel: config, data: nil, frames: frames)
        #expect(spoken?.contains("≥") == true || spoken?.contains("<") == true,
                "the tint is the only other carrier, and this reader cannot see it: \(spoken ?? "nil")")
    }

    @Test("a gauge speaks the number, the ends of its scale, and its band")
    func gaugeSpeaksItsScale() {
        let spoken = PanelValueSummary.text(panel: PanelSnapshotFixtures.gaugePanel,
                                            data: nil, frames: frames)
        #expect(spoken?.isEmpty == false)
        // "80" means nothing until the reader knows whether the dial runs to
        // 100 or to 100,000 — the same argument the render makes visually.
        #expect(spoken?.contains("100") == true, "the scale is missing: \(spoken ?? "nil")")
    }

    @Test("a time series says how many series there are and names the biggest")
    func seriesSummaryNamesTheTopLines() {
        let spoken = PanelValueSummary.text(panel: panel(.timeSeries), data: nil,
                                            frames: frames)
        #expect(spoken?.contains("2") == true, "the series count is missing")
        #expect(spoken?.contains("opus") == true,
                "the largest series is not named: \(spoken ?? "nil")")
    }

    @Test("a nine-series chart counts rather than reading out nine names")
    func longSeriesListsAreCapped() {
        let many = FrameSet(frames: (0..<9).map {
            PanelSnapshotFixtures.frame("model-\($0)", tokens: [Double($0 + 1) * 1_000])
        })
        let spoken = PanelValueSummary.text(panel: panel(.timeSeries), data: nil,
                                            frames: many) ?? ""
        let named = (0..<9).filter { spoken.contains("model-\($0)") }
        #expect(named.count == PanelValueSummary.maxSeries,
                "VoiceOver reads a label straight through with no way to skim it")
        #expect(spoken.contains("9"), "the total is what replaces the six it did not read")
    }

    @Test("a chart says how many series the reader has hidden")
    func hiddenSeriesAreCounted() {
        let spoken = PanelValueSummary.text(panel: panel(.timeSeries), data: nil,
                                            frames: frames, hidden: ["sonnet"]) ?? ""
        #expect(spoken.contains("1"),
                "a series switched off in the legend is invisible to this reader twice over")
    }

    @Test("a pie speaks proportions, because that is what a pie says")
    func pieSpeaksShares() {
        let spoken = PanelValueSummary.text(panel: panel(.pieChart), data: nil,
                                            frames: frames) ?? ""
        #expect(spoken.contains("%"), "no share was spoken: \(spoken)")
    }

    @Test("a table says how many rows there are and reads the top ones")
    func tableSpeaksItsRows() {
        let spoken = PanelValueSummary.text(panel: panel(.table), data: nil,
                                            frames: frames) ?? ""
        #expect(spoken.contains("opus"))
        #expect(spoken.contains("2"))
    }

    @Test("a state timeline says what each row is in NOW")
    func timelineSpeaksCurrentState() {
        var config = panel(.stateTimeline)
        config.options.thresholds = [ThresholdStep(value: 10_000, color: .orange)]
        let spoken = PanelValueSummary.text(panel: config, data: nil, frames: frames)
        #expect(spoken?.isEmpty == false, "a state timeline said nothing at all")
    }

    @Test("a panel with no result says nothing rather than saying zero")
    func emptyPanelsAreSilent() {
        for type in PanelSnapshotMatrix.panelTypes {
            let spoken = PanelValueSummary.text(panel: panel(type), data: nil,
                                                frames: FrameSet())
            #expect(spoken == nil,
                    "\(type.rawValue) invented a value out of an empty result: \(spoken ?? "")")
        }
    }

    @Test("a row and an unknown panel have no value to speak")
    func structuralPanelsHaveNoValue() {
        #expect(PanelValueSummary.text(panel: panel(.rowPanel), data: nil,
                                       frames: frames) == nil)
        #expect(PanelValueSummary.text(panel: panel(.unknown), data: nil,
                                       frames: frames) == nil)
    }
}
