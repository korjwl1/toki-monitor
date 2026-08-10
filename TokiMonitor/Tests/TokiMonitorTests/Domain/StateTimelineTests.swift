import Testing
import Foundation
@testable import TokiMonitor

/// Every panel so far answers "how much, over time". None can answer "what
/// state was this in, and for how long" — which is the shape of half of what
/// toki records. A window, a session, a stretch above 80%: intervals, drawn as
/// a line only by turning them into a step function to be read off an axis.
@Suite("State timeline")
struct StateTimelineTests {

    private func hour(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 3600) }

    private func sampled(_ values: [Double?], labels: [String: String] = [:]) -> Frame {
        Frame(refId: "A", fields: [
            Field(name: "time", labels: labels,
                  values: .time(values.indices.map { hour($0) })),
            Field(name: "v", labels: labels, values: .number(values)),
        ])
    }

    private let bands = [
        ThresholdStep(value: 0, color: "green"),
        ThresholdStep(value: 80, color: "red"),
    ]

    private func spans(_ frame: Frame, field: String = "v",
                       thresholds: [ThresholdStep] = []) -> [TimelineSpan] {
        StateTimelineBuilder.spans(FrameSet(frames: [frame]),
                                   selection: FieldSelection(field: field),
                                   thresholds: thresholds)
    }

    // MARK: - Runs

    /// The core of the panel: a measure that differs every sample becomes a
    /// handful of states, so the reader sees when it crossed rather than a
    /// stripe per sample.
    @Test("consecutive samples in one band become one span")
    func runsMerge() throws {
        let out = spans(sampled([10, 20, 30, 90, 95]), thresholds: bands)
        #expect(out.count == 2)
        #expect(out[0].label == "≥ 0")
        #expect(out[0].start == hour(0))
        #expect(out[0].end == hour(3), "the low run ends where the high one starts")
        #expect(out[1].label == "≥ 80")
    }

    @Test("with no thresholds each distinct value is its own state")
    func withoutThresholds() {
        let out = spans(sampled([1, 1, 2]))
        #expect(out.map(\.label) == ["1", "2"])
    }

    /// A gap is time nobody measured. Extending the previous state across it
    /// would assert something the data does not say.
    @Test("a gap closes the run instead of extending it")
    func gapClosesRun() {
        let out = spans(sampled([10, nil, 10]), thresholds: bands)
        #expect(out.count == 2, "the same state either side of a gap is two spans")
        #expect(out[0].end == hour(1))
        #expect(out[1].start == hour(2))
    }

    /// The last sample has no successor to end it. Using the last gap would
    /// let one late sample stretch the final span across the chart.
    @Test("the final span is one median step long")
    func finalSpanUsesMedianStep() throws {
        let frame = Frame(refId: "A", fields: [
            Field(name: "time", values: .time([hour(0), hour(1), hour(2), hour(20)])),
            Field(name: "v", values: .number([5, 5, 5, 5])),
        ])
        let out = spans(frame)
        let last = try #require(out.last)
        #expect(last.end == hour(21), "one hour past the last sample, not eighteen")
    }

    @Test("a single sample still draws")
    func singleSample() {
        let out = spans(sampled([42]))
        #expect(out.count == 1)
        #expect(out[0].duration == 3600)
    }

    @Test("an all-absent series draws nothing")
    func allAbsent() {
        #expect(spans(sampled([nil, nil])).isEmpty)
    }

    // MARK: - Rows that are already intervals

    @Test("start and end columns are taken as spans directly")
    func explicitIntervals() {
        let frame = Frame(refId: "A", fields: [
            Field(name: "start", values: .time([hour(0), hour(5)])),
            Field(name: "end", values: .time([hour(3), hour(9)])),
            Field(name: "peak_pct", values: .number([12, 91])),
        ])
        let out = StateTimelineBuilder.spans(
            FrameSet(frames: [frame]),
            selection: FieldSelection(field: "peak_pct"), thresholds: bands
        )
        #expect(out.count == 2)
        #expect(out[0].start == hour(0) && out[0].end == hour(3))
        #expect(out[1].label == "≥ 80")
        #expect(out.map(\.duration) == [3 * 3600, 4 * 3600], "spans are not merged into runs")
    }

    /// A span that ends before it starts is not an interval; drawing it would
    /// put a bar where no time was spent.
    @Test("a backwards row is dropped")
    func backwardsRowDropped() {
        let frame = Frame(refId: "A", fields: [
            Field(name: "start", values: .time([hour(5)])),
            Field(name: "end", values: .time([hour(1)])),
            Field(name: "v", values: .number([1])),
        ])
        #expect(StateTimelineBuilder.spans(FrameSet(frames: [frame]),
                                           selection: FieldSelection(field: "v")).isEmpty)
    }

    /// One `end` column without a `start` is a time series with an unlucky
    /// column name, not an interval frame.
    @Test("only one of the two columns is not an interval frame")
    func halfIntervalIsNotAnInterval() {
        let frame = Frame(refId: "A", fields: [
            Field(name: "time", values: .time([hour(0), hour(1)])),
            Field(name: "end", values: .number([1, 1])),
            Field(name: "v", values: .number([5, 5])),
        ])
        let out = spans(frame)
        #expect(out.count == 1)
        #expect(out[0].start == hour(0), "read as samples, so it merged into a run")
    }

    // MARK: - Series and colour

    @Test("each series gets its own row")
    func seriesAreSeparate() {
        let set = FrameSet(frames: [
            sampled([1], labels: ["limit_id": "five_hour"]),
            sampled([1], labels: ["limit_id": "seven_day"]),
        ])
        let out = StateTimelineBuilder.spans(set, selection: FieldSelection(field: "v"))
        #expect(Set(out.map(\.series)) == ["five_hour", "seven_day"])
    }

    @Test("a value's band names its colour")
    func colourFollowsBand() {
        #expect(StateTimelineBuilder.color(for: 10, thresholds: bands) == "green")
        #expect(StateTimelineBuilder.color(for: 95, thresholds: bands) == "red")
        #expect(StateTimelineBuilder.color(for: 10, thresholds: []) == nil,
                "with no thresholds the palette assigns by name")
    }

    @Test("a value below every step is its own state")
    func belowLowestStep() {
        let steps = [ThresholdStep(value: 50, color: "red")]
        #expect(StateTimelineBuilder.stateName(for: 10, thresholds: steps) == "< 50")
        #expect(StateTimelineBuilder.stateName(for: 60, thresholds: steps) == "≥ 50")
    }
}

/// Window rows had exactly one consumer because the pipeline's contract was
/// TimeSeriesData and a window is not a series. As spans they are ordinary
/// panel data.
@Suite("Windows as intervals")
struct WindowFrameAdapterTests {

    private func row(limitId: String = "five_hour", endMs: Int64, minutes: Int = 300,
                     peak: Double = 50, finalized: Bool = true,
                     timeTo100: Int64 = -1, account: String = "acct") -> WindowRow {
        WindowRow(
            kind: "session", limitId: limitId, account: account,
            windowEndMs: endMs, rawResetsAtMs: endMs, windowMinutes: minutes,
            peakPct: peak, lastPct: peak, observedTsMs: endMs - 1000,
            firstSeenMs: endMs - Int64(minutes) * 60_000, finalized: finalized,
            maxedOut: peak >= 100, limitReachedKind: 0, timeTo100Ms: timeTo100,
            activeMs: 60_000, lastSampleGapMs: 0, sampledActiveFraction: nil,
            nSamples: 7, plan: "max"
        )
    }

    private let base: Int64 = 1_800_000_000_000

    @Test("a window becomes one span of its own length")
    func windowIsASpan() throws {
        let set = WindowFrameAdapter.frames(
            rowsByProvider: ["claude_code": [row(endMs: base)]], nowMs: base
        )
        let frame = try #require(set.frames.first)
        let spans = StateTimelineBuilder.spans(
            FrameSet(frames: [frame]), selection: FieldSelection(field: "peak_pct")
        )
        #expect(spans.count == 1)
        #expect(spans[0].duration == 300 * 60, "five hours, as the row says")
        #expect(frame.commonLabels["limit_id"] == "five_hour")
        #expect(frame.commonLabels["provider"] == "claude_code")
    }

    /// An open window has not reached its reset. Drawing it to the reset would
    /// claim coverage of time that has not happened.
    @Test("an open window is drawn up to now, not to its reset")
    func openWindowStopsAtNow() throws {
        let now = base - 3_600_000
        let set = WindowFrameAdapter.frames(
            rowsByProvider: ["claude_code": [row(endMs: base, finalized: false)]], nowMs: now
        )
        guard case let .time(ends)? = set.frames.first?.field(named: "end")?.values else {
            Issue.record("no end column"); return
        }
        #expect(ends[0] == Date(timeIntervalSince1970: Double(now) / 1000))
    }

    /// `-1` means it never hit the limit. Zero would read as "hit it instantly".
    @Test("never reaching 100% is absent, not zero")
    func neverReachedIsAbsent() async throws {
        let set = WindowFrameAdapter.frames(
            rowsByProvider: ["c": [row(endMs: base, timeTo100: -1),
                                   row(endMs: base + 1000, timeTo100: 120_000)]],
            nowMs: base
        )
        let values = try #require(set.frames.first?.field(named: "minutes_to_100")?.values.numbers)
        #expect(values[0] == nil)
        #expect(values[1] == 2)
    }

    @Test("different limits are different rows on the chart")
    func limitsAreSeparateSeries() {
        let set = WindowFrameAdapter.frames(
            rowsByProvider: ["claude_code": [
                row(limitId: "five_hour", endMs: base),
                row(limitId: "seven_day", endMs: base, minutes: 10080),
            ]],
            nowMs: base
        )
        #expect(set.frames.count == 2)
        #expect(Set(set.frames.compactMap { $0.commonLabels["limit_id"] })
                == ["five_hour", "seven_day"])
    }

    @Test("spans are ordered by when the window ended")
    func spansAreOrdered() throws {
        let set = WindowFrameAdapter.frames(
            rowsByProvider: ["c": [row(endMs: base + 7_200_000), row(endMs: base)]],
            nowMs: base + 7_200_000
        )
        guard case let .time(starts)? = set.frames.first?.field(named: "start")?.values else {
            Issue.record("no start column"); return
        }
        #expect(starts == starts.sorted())
    }

    @Test("frames are rectangular so every reader can index across them")
    func rectangular() {
        let set = WindowFrameAdapter.frames(
            rowsByProvider: ["c": [row(endMs: base), row(endMs: base + 1000)]], nowMs: base
        )
        #expect(set.frames.allSatisfy { $0.isRectangular })
    }
}
