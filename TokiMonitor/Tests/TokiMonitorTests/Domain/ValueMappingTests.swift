import Testing
import Foundation
@testable import TokiMonitor

@Suite("Value mappings")
@MainActor
struct ValueMappingTests {

    private func config(_ unit: String? = "tokens") -> FieldDisplayConfig {
        FieldDisplayConfig(unit: unit)
    }

    @Test("an exact value is replaced by its mapping, ahead of the unit")
    func exactValueWins() {
        let mappings = [ValueMapping(match: .value(0), text: L.tr("아직 없음", "nothing yet"))]
        #expect(ValueMappings.format(0, config: config(), mappings: mappings)
                == L.tr("아직 없음", "nothing yet"))
        // Everything else still goes through the unit.
        #expect(ValueMappings.format(1_000, config: config(), mappings: mappings)
                == FieldFormatter.format(1_000, config: config()))
    }

    @Test("an absent sample can be given words of its own")
    func absentIsMappable() {
        // The acceptance scenario: a point with no value must be able to read
        // as something other than the formatter's dash — and must never read
        // as 0.
        let mappings = [ValueMapping(match: .special(.absent), text: "not measured")]
        #expect(ValueMappings.format(nil, config: config(), mappings: mappings) == "not measured")
        #expect(ValueMappings.format(0, config: config(), mappings: mappings) != "not measured",
                "an absent sample and a zero are different facts")
    }

    @Test("a range catches everything between its ends, inclusive")
    func rangeMatches() {
        let mapping = ValueMapping(match: .range(from: 0, to: 10), text: "low")
        #expect(mapping.matches(0))
        #expect(mapping.matches(10))
        #expect(mapping.matches(5))
        #expect(!mapping.matches(10.1))
        #expect(!mapping.matches(-0.1))
        #expect(!mapping.matches(nil), "an absent sample is not inside any range")
    }

    @Test("a half-open range is open on the side that was left out")
    func openEndedRange() {
        let above = ValueMapping(match: .range(from: 100, to: nil), text: "high")
        #expect(above.matches(1_000_000))
        #expect(!above.matches(99))
        let below = ValueMapping(match: .range(from: nil, to: 0), text: "negative or zero")
        #expect(below.matches(-5))
        #expect(!below.matches(1))
    }

    @Test("the first matching rule wins, in the order the editor shows")
    func firstMatchWins() {
        let mappings = [
            ValueMapping(match: .value(0), text: "none"),
            ValueMapping(match: .range(from: 0, to: 10), text: "low"),
        ]
        #expect(ValueMappings.result(for: 0, mappings: mappings)?.text == "none",
                "reading bottom-up would make the order the reader arranged a lie")
        #expect(ValueMappings.result(for: 5, mappings: mappings)?.text == "low")
    }

    @Test("a numeric rule never catches a string, and the reverse")
    func kindsDoNotCross() {
        let numeric = ValueMapping(match: .value(0), text: "none")
        #expect(!numeric.matches(text: "0"))
        let textual = ValueMapping(match: .text("opus"), text: "Opus")
        #expect(!textual.matches(0))
        #expect(textual.matches(text: "opus"))
        #expect(!textual.matches(text: "sonnet"))
    }

    @Test("no mapping means the unit formats the value exactly as before")
    func noMappingsChangesNothing() {
        for value: Double? in [nil, 0, 1, 1_234_567] {
            #expect(ValueMappings.format(value, config: config(), mappings: [])
                    == FieldFormatter.format(value, config: config()))
        }
    }

    @Test("a mapping survives a save and a load")
    func roundTrips() throws {
        var options = PanelDisplayOptions()
        options.valueMappings = [
            ValueMapping(match: .value(0), text: "none", color: .neutral),
            ValueMapping(match: .range(from: 1, to: 10), text: "low"),
            ValueMapping(match: .special(.absent), text: "not measured", color: .orange),
            ValueMapping(match: .text("opus"), text: "Opus 4.1"),
        ]
        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(PanelDisplayOptions.self, from: data)
        #expect(decoded.valueMappings == options.valueMappings)
    }

    @Test("a panel saved before mappings existed still decodes")
    func decodesWithoutTheKey() throws {
        let json = Data(#"{"lineWidth": 3}"#.utf8)
        let decoded = try JSONDecoder().decode(PanelDisplayOptions.self, from: json)
        #expect(decoded.valueMappings.isEmpty)
        #expect(decoded.lineWidth == 3)
    }

    @Test("a stat card shows the mapped words instead of its number")
    func statCardHonoursMappings() {
        var panel = PanelSnapshotFixtures.panel(.stat)
        let frames = PanelSnapshotFixtures.frames
        let before = StatPanelView.statValue(panel: panel, data: nil, frames: frames)
        let number = StatPanelView.numericValue(panel: panel, data: nil, frames: frames)
        panel.options.valueMappings = [
            ValueMapping(match: .range(from: 0, to: nil), text: "over budget", color: .red)
        ]
        let after = StatPanelView.statValue(panel: panel, data: nil, frames: frames)
        #expect(number != nil)
        #expect(after.value == "over budget")
        #expect(before.value != after.value)
        #expect(StatPanelView.mappedColor(panel: panel, value: number) == .red)
    }

    @Test("a stat card with nothing to show can say why")
    func statCardMapsAbsence() {
        var panel = PanelSnapshotFixtures.panel(.stat)
        #expect(StatPanelView.statValue(panel: panel, data: nil,
                                        frames: FrameSet()).value == "-")
        panel.options.valueMappings = [
            ValueMapping(match: .special(.absent), text: "not measured")
        ]
        #expect(StatPanelView.statValue(panel: panel, data: nil,
                                        frames: FrameSet()).value == "not measured")
    }

    @Test("a mapping does not catch a top-model card, whose value is a name")
    func topModelIsNotANumber() {
        var panel = PanelSnapshotFixtures.panel(.stat, metric: .topModel)
        panel.options.valueMappings = [
            ValueMapping(match: .special(.absent), text: "not measured")
        ]
        let value = StatPanelView.statValue(panel: panel, data: nil,
                                            frames: PanelSnapshotFixtures.frames).value
        #expect(value != "not measured",
                "topModel has no number; a no-value rule would replace a series name with a message about missing data")
    }

    @Test("only the panel types that draw a value as text offer mappings")
    func onlyTextRendersOfferThem() {
        // 계약 R1: a control the render ignores is worse than a missing one.
        #expect(PanelType.stat.honoursValueMappings)
        #expect(PanelType.gauge.honoursValueMappings)
        #expect(PanelType.table.honoursValueMappings)
        #expect(!PanelType.timeSeries.honoursValueMappings,
                "a line chart draws a value as a position; there is nowhere to put a word")
        #expect(!PanelType.barChart.honoursValueMappings)
        #expect(!PanelType.pieChart.honoursValueMappings)
    }
}
