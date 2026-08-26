import Testing
import Foundation
@testable import TokiMonitor

/// The distinction this suite exists for: a reader looking at a panel with
/// nothing in it must be able to tell whether there was nothing to show or
/// whether the app failed. Before, both drew a `Spacer()`.
@Suite("Panel state")
@MainActor
struct PanelStateTests {

    private func frames(_ values: [Double?]) -> FrameSet {
        let labels = ["model": "opus"]
        return FrameSet(frames: [Frame(refId: "A", fields: [
            Field(name: "time", labels: labels,
                  values: .time(values.indices.map { Date(timeIntervalSince1970: Double($0) * 3600) })),
            Field(name: "total_tokens", labels: labels, values: .number(values)),
        ])])
    }

    private var someData: TimeSeriesData {
        TimeSeriesData(points: [], granularity: .hourly)
    }

    // MARK: - empty is not failed

    @Test("empty and failed say different things")
    func emptyIsNotFailed() {
        let empty = PanelState.empty(.noDataInRange)
        let failed = PanelState.failed(reason: "connection refused")

        #expect(empty.title != failed.title)
        #expect(empty.symbol != failed.symbol)
        #expect(empty.detail != failed.detail)
        // The one that a user can act on is the one that offers the action.
        #expect(failed.offersRetry)
        #expect(!empty.offersRetry)
    }

    @Test("failed carries the reason it was given, verbatim")
    func failedCarriesReason() {
        let reason = "Post \"http://127.0.0.1:9494/api/v1/query_range\": connection refused"
        #expect(PanelState.failed(reason: reason).detail == reason)
    }

    @Test("all five states are mutually distinguishable")
    func fiveStatesAreDistinct() {
        let states: [PanelState] = [
            .idle, .loading(hasPrevious: false), .loaded,
            .empty(.noDataInRange), .failed(reason: "x"),
        ]
        // Identity a reader can perceive without reading carefully: symbol
        // shape, headline, and whether an action is offered.
        let fingerprints = states.map { "\($0.symbol)|\($0.title)|\($0.offersRetry)" }
        #expect(Set(fingerprints).count == states.count)
    }

    /// A panel whose every series is hidden draws this status instead of its
    /// chart — and the legend, which is the only thing that hid them, is part
    /// of the chart. Without an action here, hiding the last series is a
    /// one-way door.
    @Test("the all-hidden state offers the way back, and no other state does")
    func allHiddenOffersShowAll() {
        #expect(PanelState.empty(.allSeriesHidden).offersShowAllSeries)
        let others: [PanelState] = [
            .idle, .loading(hasPrevious: true), .loaded,
            .empty(.noDataInRange), .failed(reason: "x"),
        ]
        #expect(others.allSatisfy { !$0.offersShowAllSeries })
    }

    @Test("each reason for emptiness names a different next action")
    func emptyReasonsDiffer() {
        let details = PanelEmptyReason.allCases.map { PanelState.empty($0).detail }
        #expect(details.allSatisfy { $0?.isEmpty == false })
        #expect(Set(details.map { $0 ?? "" }).count == PanelEmptyReason.allCases.count)
    }

    // MARK: - Derivation

    @Test("a fetch that has not run is idle, not empty")
    func idleIsNotEmpty() {
        #expect(PanelState.resolve(.idle, hasContent: false) == .idle)
    }

    @Test("a successful query with no rows is empty, not loaded")
    func successWithNoRowsIsEmpty() {
        let state = PanelState.resolve(
            .loaded(someData, frames: FrameSet(frames: [])), hasContent: false
        )
        #expect(state == .empty(.noDataInRange))
    }

    @Test("hiding every series is its own kind of empty")
    func everySeriesHiddenIsItsOwnEmpty() {
        let state = PanelState.resolve(
            .loaded(someData, frames: frames([1, 2])), hasContent: true, hasVisibleSeries: false
        )
        #expect(state == .empty(.allSeriesHidden))
        #expect(state != .empty(.noDataInRange))
    }

    @Test("a failed fetch becomes failed, never empty")
    func failureIsNeverEmpty() {
        let state = PanelState.resolve(.error("boom"), hasContent: false)
        #expect(state == .failed(reason: "boom"))
        if case .empty = state { Issue.record("a failure must not read as an empty result") }
    }

    // MARK: - Loading keeps the previous result

    @Test("loading with a previous result keeps showing it")
    func loadingKeepsPrevious() {
        let state = PanelState.resolve(.loading(previous: someData, previousFrames: nil),
                                       hasContent: true)
        #expect(state == .loading(hasPrevious: true))
        #expect(state.showsContent, "the previous result stays on screen")
        #expect(state.isStale, "and is marked as stale while it does")
    }

    @Test("loading from nothing shows progress, not an empty rectangle")
    func coldLoadingShowsProgress() {
        let state = PanelState.resolve(.loading(previous: nil, previousFrames: nil),
                                       hasContent: false)
        #expect(state == .loading(hasPrevious: false))
        #expect(!state.showsContent)
    }

    /// The regression that made the whole dashboard blink: a panel whose
    /// datasource serves frames and no legacy points had nothing to hold over,
    /// because `.loading` only carried the legacy shape.
    @Test("a frames-only panel still has something to hold over while refreshing")
    func framesOnlyPanelHoldsPreviousOver() {
        let previous = PanelDataState.loaded(someData, frames: frames([1, 2, 3]))
        let refreshing = PanelDataState.loading(previous: previous.timeSeriesData,
                                                previousFrames: previous.frames)
        #expect(refreshing.frames?.frames.isEmpty == false)
        #expect(PanelState.resolve(refreshing, hasContent: true) == .loading(hasPrevious: true))
    }
}
