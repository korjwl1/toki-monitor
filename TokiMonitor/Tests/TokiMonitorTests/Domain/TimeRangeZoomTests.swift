import Testing
import Foundation
@testable import TokiMonitor

@Suite("Time range zoom and pan")
@MainActor
struct TimeRangeZoomTests {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func span(_ time: TimeConfig) -> TimeInterval {
        time.toDate.timeIntervalSince(time.fromDate)
    }

    @Test("zooming in halves the range and keeps its centre")
    func zoomInKeepsCentre() {
        let start = TimeConfig.absolute(from: now.addingTimeInterval(-86_400), to: now)
        let zoomed = TimeRangeZoom.zoom(start, factor: 0.5, now: now)
        #expect(abs(span(zoomed) - 43_200) < 1)
        let centreBefore = start.fromDate.addingTimeInterval(span(start) / 2)
        let centreAfter = zoomed.fromDate.addingTimeInterval(span(zoomed) / 2)
        #expect(abs(centreAfter.timeIntervalSince(centreBefore)) < 1,
                "a zoom that moves the centre throws away what the reader was looking at")
    }

    @Test("zooming out doubles it")
    func zoomOut() {
        let start = TimeConfig.absolute(from: now.addingTimeInterval(-3_600), to: now)
        #expect(abs(span(TimeRangeZoom.zoom(start, factor: 2, now: now)) - 7_200) < 1)
    }

    @Test("a relative range becomes absolute when zoomed")
    func zoomingARelativeRangeFixesIt() {
        let zoomed = TimeRangeZoom.zoom(TimeConfig(from: "now-24h", to: "now"),
                                        factor: 0.5, now: now)
        #expect(!zoomed.isRelative,
                "half of 'the last 24 hours' ends in the past; as a relative range it would slide forward on the next refresh")
        #expect(abs(span(zoomed) - 43_200) < 1)
    }

    @Test("zooming in cannot go below a minute")
    func zoomInHasAFloor() {
        var time = TimeConfig.absolute(from: now.addingTimeInterval(-120), to: now)
        for _ in 0..<20 { time = TimeRangeZoom.zoom(time, factor: 0.5, now: now) }
        #expect(span(time) >= TimeRangeZoom.minimumSpan - 0.001)
    }

    @Test("zooming out cannot exceed ten years")
    func zoomOutHasACeiling() {
        var time = TimeConfig.absolute(from: now.addingTimeInterval(-86_400), to: now)
        for _ in 0..<40 { time = TimeRangeZoom.zoom(time, factor: 2, now: now) }
        #expect(span(time) <= TimeRangeZoom.maximumSpan + 0.001)
    }

    @Test("panning back moves the whole window and keeps its width")
    func panBack() {
        let start = TimeConfig.absolute(from: now.addingTimeInterval(-7_200),
                                        to: now.addingTimeInterval(-3_600))
        let panned = TimeRangeZoom.pan(start, by: -0.5, now: now)
        #expect(abs(span(panned) - span(start)) < 1)
        #expect(abs(panned.toDate.timeIntervalSince(start.toDate) + 1_800) < 1)
    }

    @Test("panning forward stops at now instead of showing the future")
    func panForwardClampsAtNow() {
        let start = TimeConfig.absolute(from: now.addingTimeInterval(-3_600), to: now)
        let panned = TimeRangeZoom.pan(start, by: 0.5, now: now)
        #expect(panned == start,
                "there is no data after now; sliding into it is half a blank chart")
    }

    @Test("panning forward from the past catches up exactly to now")
    func panForwardCatchesUp() {
        let start = TimeConfig.absolute(from: now.addingTimeInterval(-7_200),
                                        to: now.addingTimeInterval(-600))
        let panned = TimeRangeZoom.pan(start, by: 0.5, now: now)
        #expect(abs(panned.toDate.timeIntervalSince(now)) < 1)
        #expect(abs(span(panned) - span(start)) < 1)
    }

    @Test("a drag shorter than a minute is not a selection")
    func tinyDragIsIgnored() {
        #expect(TimeRangeZoom.selection(from: now, to: now.addingTimeInterval(3)) == nil,
                "a click that moved a few pixels must not zoom to a three-second window")
    }

    @Test("a backwards drag selects the same range as a forwards one")
    func backwardsDragWorks() {
        let forwards = TimeRangeZoom.selection(from: now.addingTimeInterval(-3_600), to: now)
        let backwards = TimeRangeZoom.selection(from: now, to: now.addingTimeInterval(-3_600))
        #expect(forwards == backwards)
        #expect(forwards != nil)
    }

    @Test("a selection is absolute and covers exactly what was dragged over")
    func selectionIsExact() {
        let from = now.addingTimeInterval(-7_200)
        let to = now.addingTimeInterval(-3_600)
        let selected = TimeRangeZoom.selection(from: from, to: to)
        #expect(selected?.isRelative == false)
        #expect(abs((selected?.fromDate ?? now).timeIntervalSince(from)) < 1)
        #expect(abs((selected?.toDate ?? now).timeIntervalSince(to)) < 1)
    }
}
