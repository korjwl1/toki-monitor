import Testing
import Foundation
@testable import TokiMonitor

@Suite("Per-panel time")
@MainActor
struct PanelTimeOverrideTests {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let dashboard = TimeConfig(from: "now-24h", to: "now")

    private func panel(relative: String? = nil, shift: String? = nil) -> PanelConfig {
        var config = PanelSnapshotFixtures.panel(.timeSeries)
        config.relativeTime = relative
        config.timeShift = shift
        return config
    }

    @Test("a panel with no override runs the dashboard's own window")
    func noOverride() {
        let time = PanelTimeOverride.effectiveTime(for: panel(), dashboard: dashboard, now: now)
        #expect(time == dashboard)
        #expect(!PanelTimeOverride.isOverridden(panel()))
        #expect(PanelTimeOverride.label(for: panel()) == nil)
    }

    @Test("a relative override replaces the dashboard's window and stays relative")
    func relativeReplaces() {
        let time = PanelTimeOverride.effectiveTime(for: panel(relative: "1h"),
                                                   dashboard: dashboard, now: now)
        #expect(time.from == "now-1h")
        #expect(time.to == "now")
        // Relative on purpose: a panel that says "the last hour" should still
        // mean it an hour from now.
        #expect(time.isRelative)
        #expect(abs(time.duration - 3_600) < 1)
    }

    @Test("a shift moves the window back and pins it")
    func shiftMovesBack() {
        let time = PanelTimeOverride.effectiveTime(for: panel(shift: "1d"),
                                                   dashboard: dashboard, now: now)
        #expect(!time.isRelative, "a shifted window ends in the past and is not relative")
        #expect(abs(time.toDate.timeIntervalSince(now.addingTimeInterval(-86_400))) < 1)
        #expect(abs(time.duration - 86_400) < 1, "a shift moves the window, it does not resize it")
    }

    @Test("the two compose as 'the last hour, a day ago'")
    func relativeThenShift() {
        let time = PanelTimeOverride.effectiveTime(for: panel(relative: "1h", shift: "1d"),
                                                   dashboard: dashboard, now: now)
        #expect(abs(time.duration - 3_600) < 1, "the relative window sets the width")
        #expect(abs(time.toDate.timeIntervalSince(now.addingTimeInterval(-86_400))) < 1,
                "the shift sets where that width sits")
    }

    @Test("a shift applies to an absolute dashboard range too")
    func shiftOnAbsoluteRange() {
        let absolute = TimeConfig.absolute(from: now.addingTimeInterval(-7_200), to: now)
        let time = PanelTimeOverride.effectiveTime(for: panel(shift: "1h"),
                                                   dashboard: absolute, now: now)
        #expect(abs(time.toDate.timeIntervalSince(now.addingTimeInterval(-3_600))) < 1)
        #expect(abs(time.duration - 7_200) < 1)
    }

    @Test("a token this build cannot read is ignored, not guessed at")
    func unparseableTokenIsIgnored() {
        let broken = panel(relative: "7days", shift: "yesterday")
        let time = PanelTimeOverride.effectiveTime(for: broken, dashboard: dashboard, now: now)
        #expect(time == dashboard, "a guessed window is a wrong number that looks right")
        #expect(PanelTimeOverride.invalidTokens(of: broken) == ["7days", "yesterday"],
                "and the reader is told which token was dropped")
    }

    @Test("a bare number is not a duration")
    func bareNumberRejected() {
        #expect(PanelTimeOverride.duration("7") == nil,
                "7 what? A wrong guess moves a whole panel's window")
        #expect(PanelTimeOverride.duration("") == nil)
        #expect(PanelTimeOverride.duration("h") == nil)
        #expect(PanelTimeOverride.duration("-1h") == nil)
    }

    @Test("the units this build reads")
    func durationUnits() {
        #expect(PanelTimeOverride.duration("90s") == 90)
        #expect(PanelTimeOverride.duration("30m") == 1_800)
        #expect(PanelTimeOverride.duration("1h") == 3_600)
        #expect(PanelTimeOverride.duration("7d") == 604_800)
        #expect(PanelTimeOverride.duration("2w") == 1_209_600)
    }

    @Test("every token the editor offers is one the resolver can read")
    func suggestedTokensAllParse() {
        // 계약 R1 in miniature: an option the picker offers and the resolver
        // drops is a control that visibly does nothing.
        for token in PanelTimeOverride.suggestedTokens {
            #expect(PanelTimeOverride.duration(token) != nil, "\(token) does not parse")
        }
    }

    @Test("a panel on its own window says so, on screen and out loud")
    func overriddenPanelSaysSo() {
        // FR-037's second half. A panel drawing a different window without
        // saying so is right about a question nobody asked.
        #expect(PanelTimeOverride.label(for: panel(relative: "1h")) != nil)
        #expect(PanelTimeOverride.label(for: panel(shift: "7d")) != nil)
        let both = PanelTimeOverride.label(for: panel(relative: "1h", shift: "7d"))
        #expect(both?.contains("1h") == true)
        #expect(both?.contains("7d") == true)
        #expect(PanelTimeOverride.spokenLabel(for: panel(relative: "1h")) != nil)
        #expect(PanelTimeOverride.spokenLabel(for: panel()) == nil)
    }

    @Test("the announcement carries the override before the state and the value")
    func announcementCarriesTheOverride() {
        let spoken = PanelAccessibility.announcement(
            title: "Tokens", typeName: "Time Series",
            state: .empty(.noDataInRange), value: nil,
            timeOverride: PanelTimeOverride.label(for: panel(relative: "1h"))
        )
        let overrideAt = spoken.range(of: "1h").map { spoken.distance(from: spoken.startIndex, to: $0.lowerBound) }
        let stateAt = spoken.range(of: PanelState.empty(.noDataInRange).title)
            .map { spoken.distance(from: spoken.startIndex, to: $0.lowerBound) }
        #expect(overrideAt != nil)
        #expect(stateAt != nil)
        #expect((overrideAt ?? 0) < (stateAt ?? 0),
                "'no data in this range' means something different when the range is not the dashboard's")
    }

    @Test("the override survives a save and a load")
    func roundTrips() throws {
        let original = panel(relative: "1h", shift: "7d")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PanelConfig.self, from: data)
        #expect(decoded.relativeTime == "1h")
        #expect(decoded.timeShift == "7d")
    }

    @Test("a panel written before per-panel time existed still decodes")
    func decodesWithoutTheKeys() throws {
        // Encoded from a panel with neither key set, which is exactly the shape
        // every dashboard already on disk has.
        let data = try JSONEncoder().encode(panel())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("relativeTime"),
                "a panel with no override must re-encode exactly as it arrived")
        #expect(!text.contains("timeShift"))
        let decoded = try JSONDecoder().decode(PanelConfig.self, from: data)
        #expect(decoded.relativeTime == nil)
        #expect(decoded.timeShift == nil)
    }
}
