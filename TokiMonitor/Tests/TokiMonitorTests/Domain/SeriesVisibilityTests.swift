import Testing
import Foundation
@testable import TokiMonitor

/// Contract R7: hiding a series is the legend's job, it is per panel, and it
/// does not re-run the query.
///
/// The last clause is the one worth a test. There were two render-stage
/// filters here — the toolbar's model list and, in effect, nothing else — and
/// the obvious way to implement a legend toggle is to fold it into the query
/// so that the "hidden" series is never fetched. That would make a glance at
/// one line cost a round trip to every backend on the dashboard, and would
/// make hiding a series and changing the time range the same kind of event.
@Suite("Series visibility")
@MainActor
struct SeriesVisibilityTests {

    // MARK: - The state

    @Test("nothing is hidden until something is hidden")
    func emptyByDefault() {
        let visibility = SeriesVisibility()
        #expect(visibility.hidden(for: UUID()).isEmpty)
        #expect(visibility.isEmpty)
    }

    @Test("toggling hides, and toggling again brings it back")
    func toggleRoundTrip() {
        let panelID = UUID()
        var visibility = SeriesVisibility()
        visibility.toggle("opus", panelID: panelID)
        #expect(visibility.isHidden("opus", panelID: panelID))
        #expect(visibility.hasHidden(panelID: panelID))
        visibility.toggle("opus", panelID: panelID)
        #expect(!visibility.isHidden("opus", panelID: panelID))
        #expect(!visibility.hasHidden(panelID: panelID))
        #expect(visibility.isEmpty, "back to untouched, not to an empty set left behind")
    }

    /// A legend belongs to the chart it sits under. Hiding `opus` on one panel
    /// is not a statement about every other panel — the old toolbar filter's
    /// being global was most of why it surprised people.
    @Test("hiding a series on one panel does not touch another")
    func perPanel() {
        let a = UUID(), b = UUID()
        var visibility = SeriesVisibility()
        visibility.toggle("opus", panelID: a)
        #expect(visibility.isHidden("opus", panelID: a))
        #expect(!visibility.isHidden("opus", panelID: b))
    }

    @Test("show all clears one panel and leaves the rest")
    func showAll() {
        let a = UUID(), b = UUID()
        var visibility = SeriesVisibility()
        visibility.toggle("opus", panelID: a)
        visibility.toggle("sonnet", panelID: b)
        visibility.showAll(panelID: a)
        #expect(visibility.hidden(for: a).isEmpty)
        #expect(visibility.hidden(for: b) == ["sonnet"])
    }

    // MARK: - What it does to the render

    private func frame(_ labels: [String: String], _ values: [Double]) -> Frame {
        Frame(refId: "A", fields: [
            Field(name: "time", labels: labels,
                  values: .time(values.indices.map {
                      Date(timeIntervalSince1970: Double($0) * 3600)
                  })),
            Field(name: "total_tokens", labels: labels, values: .number(values.map { $0 })),
        ])
    }

    private var frames: FrameSet {
        FrameSet(frames: [frame(["model": "opus"], [1, 2, 3]),
                          frame(["model": "sonnet"], [4, 5, 6])])
    }

    @Test("the legend lists every series, hidden ones included")
    func legendKeepsHiddenEntries() {
        let names = PanelSeries.seriesNames(metric: .totalTokens, panel: nil,
                                            frames: frames, data: nil)
        #expect(Set(names) == ["opus", "sonnet"])
    }

    @Test("a hidden series is not drawn")
    func hiddenSeriesIsNotDrawn() {
        let drawn = PanelSeries.chartSeriesWithGaps(
            metric: .totalTokens, panel: nil, frames: frames, data: nil, hidden: ["opus"]
        )
        #expect(drawn.map(\.model) == ["sonnet"])
    }

    @Test("hiding nothing draws everything")
    func nothingHiddenDrawsAll() {
        let drawn = PanelSeries.chartSeriesWithGaps(
            metric: .totalTokens, panel: nil, frames: frames, data: nil, hidden: []
        )
        #expect(Set(drawn.map(\.model)) == ["opus", "sonnet"])
    }

    /// A query grouped by two dimensions names its series `opus · toki`. The
    /// legend offers that string, and hiding the bare model still has to work,
    /// or a chart that gained a grouping would quietly un-hide everything.
    @Test("hiding a model hides its two-dimension series too")
    func hidingMatchesTheLeadingDimension() {
        let set = FrameSet(frames: [
            frame(["model": "opus", "project": "toki"], [1, 2]),
            frame(["model": "sonnet", "project": "toki"], [3, 4]),
        ])
        let names = PanelSeries.seriesNames(metric: .totalTokens, panel: nil,
                                            frames: set, data: nil)
        #expect(names.allSatisfy { $0.contains(" · ") }, "fixture must be two-dimensional: \(names)")
        let drawn = PanelSeries.chartSeriesWithGaps(
            metric: .totalTokens, panel: nil, frames: set, data: nil, hidden: ["opus"]
        )
        #expect(drawn.count == 1)
        #expect(drawn[0].model.hasPrefix("sonnet"))
    }

    @Test("the legacy series path hides too")
    func legacyPathHides() {
        let data = TimeSeriesData(points: [
            TimeSeriesPoint(date: Date(timeIntervalSince1970: 0), models: [
                TokiModelSummary(model: "opus", inputTokens: 1, outputTokens: 1,
                                 totalTokens: 2, events: 1, costUsd: nil,
                                 cacheCreationInputTokens: nil, cacheReadInputTokens: nil,
                                 cachedInputTokens: nil, reasoningOutputTokens: nil),
                TokiModelSummary(model: "sonnet", inputTokens: 1, outputTokens: 1,
                                 totalTokens: 2, events: 1, costUsd: nil,
                                 cacheCreationInputTokens: nil, cacheReadInputTokens: nil,
                                 cachedInputTokens: nil, reasoningOutputTokens: nil),
            ])
        ], granularity: .hourly)
        let drawn = PanelSeries.chartPoints(metric: .tokensByModel, panel: nil,
                                            frames: nil, data: data, hidden: ["opus"])
        #expect(drawn.map(\.model) == ["sonnet"])
    }

    // MARK: - It does not re-run the query (T060)

    /// Counts what actually reached a backend.
    final class CountingDatasource: QueryDataSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }

        func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
            lock.withLock { _count += 1 }
            return TimeSeriesData(points: [], granularity: .hourly)
        }

        func queryPromQL(query: String, time: TimeConfig) async throws -> QueryResult {
            let series = try await queryPromQLAsTimeSeries(query: query, time: time)
            return QueryResult(timeSeries: series, frames: FrameSet(frames: [
                Frame(refId: "A", fields: [
                    Field(name: "time", labels: ["model": "opus"],
                          values: .time([Date(timeIntervalSince1970: 0)])),
                    Field(name: "total_tokens", labels: ["model": "opus"],
                          values: .number([1])),
                ]),
                Frame(refId: "A", fields: [
                    Field(name: "time", labels: ["model": "sonnet"],
                          values: .time([Date(timeIntervalSince1970: 0)])),
                    Field(name: "total_tokens", labels: ["model": "sonnet"],
                          values: .number([2])),
                ]),
            ]))
        }
    }

    @Test("hiding a series draws less without asking the backend anything")
    func togglingDoesNotRefetch() async {
        let client = CountingDatasource()
        let panel = PanelConfig(
            title: "Tokens", panelType: .timeSeries, metric: .totalTokens,
            gridPosition: GridPosition(column: 0, row: 0, width: 12, height: 4),
            targets: [PanelTarget(refId: "A", metric: .totalTokens, query: "usage[1h]")]
        )
        let states = await PanelFetchCoordinator().fetchRegular(
            panels: [panel], time: TimeConfig(), variables: [],
            activeDatasource: DatasourceSelector(kind: BuiltinDatasourceKind.localCLI),
            defaultClient: client
        )
        #expect(client.count == 1, "one query for one panel")
        let fetched = try? #require(states[panel.id]?.frames)

        // The reader clicks a legend entry. Everything after this point is
        // render-stage: the same result, drawn differently.
        var visibility = SeriesVisibility()
        visibility.toggle("opus", panelID: panel.id)

        let before = PanelSeries.chartSeriesWithGaps(
            metric: .totalTokens, panel: panel, frames: fetched, data: nil, hidden: []
        )
        let after = PanelSeries.chartSeriesWithGaps(
            metric: .totalTokens, panel: panel, frames: fetched, data: nil,
            hidden: visibility.hidden(for: panel.id)
        )
        #expect(before.count == 2)
        #expect(after.map(\.model) == ["sonnet"], "the hidden series is gone from the render")
        #expect(client.count == 1, "and nothing was asked of the backend to make that happen")
    }
}

// MARK: - The pie's legend

/// Contract R7 again, for the panel type that had no legend at all.
///
/// The pie collapses everything below 2% into one "Others" entry, so the
/// question a legend toggle raises here is not "does it hide" but "hide WHAT,
/// relative to that bucket". The order the two are applied in is the answer,
/// and it is what these pin.
@Suite("Pie chart legend")
@MainActor
struct PieChartLegendTests {

    private func entries(_ pairs: [(String, Double)]) -> [PieChartView.Entry] {
        pairs.map { PieChartView.Entry(label: $0.0, value: $0.1) }
    }

    private var wide: [PieChartView.Entry] {
        // Three readable slices and a tail of four that are each under 2%.
        entries([("opus", 500), ("sonnet", 300), ("haiku", 180),
                 ("a", 5), ("b", 5), ("c", 5), ("d", 5)])
    }

    @Test("the tail collapses into one entry")
    func tailIsBucketed() {
        let bucketed = PieChartView.bucketed(wide)
        #expect(bucketed.map(\.label) == ["opus", "sonnet", "haiku", PieChartView.othersLabel])
        #expect(bucketed.last?.value == 20, "the bucket is the sum of what it swallowed")
    }

    /// Applied after the bucketing, not before. Hiding the biggest slice makes
    /// the tail a much larger share of what is left — but it does not promote a
    /// tail member into a slice of its own, so the list the reader is clicking
    /// through does not rearrange under them.
    @Test("hiding a slice never rearranges the legend")
    func hidingDoesNotRebucket() {
        let bucketed = PieChartView.bucketed(wide)
        let visible = PieChartView.visible(bucketed, hidden: ["opus"])
        #expect(visible.map(\.label) == ["sonnet", "haiku", PieChartView.othersLabel])
        #expect(PieChartView.bucketed(wide).map(\.label) == bucketed.map(\.label),
                "and the legend still lists the hidden entry, which is the way back")
    }

    @Test("what is left re-proportions to fill the circle")
    func remainderReproportions() {
        let visible = PieChartView.visible(PieChartView.bucketed(wide), hidden: ["opus"])
        let total = visible.reduce(0) { $0 + $1.value }
        #expect(total == 500, "300 + 180 + 20, with opus's 500 out of the denominator")
        // sonnet was 30% of 1000 and is 60% of what remains.
        #expect(abs((visible[0].value / total) - 0.6) < 0.0001)
    }

    /// "Others" is not a series; it is the name of whatever did not fit. It is
    /// still one legend entry, and switching it off hides the tail as a unit —
    /// which is the only thing the tail is.
    @Test("the Others bucket can be switched off, and takes the whole tail")
    func othersIsTogglable() {
        let visible = PieChartView.visible(PieChartView.bucketed(wide),
                                           hidden: [PieChartView.othersLabel])
        #expect(visible.map(\.label) == ["opus", "sonnet", "haiku"])
        #expect(visible.reduce(0) { $0 + $1.value } == 980)
    }

    @Test("hiding everything leaves nothing to draw")
    func everythingHidden() {
        let bucketed = PieChartView.bucketed(wide)
        let visible = PieChartView.visible(bucketed, hidden: Set(bucketed.map(\.label)))
        #expect(visible.isEmpty, "which is what puts the panel in its allSeriesHidden state")
    }

    @Test("a slice is identified by its label, so a redraw keeps its identity")
    func labelIsIdentity() {
        #expect(PieChartView.Entry(label: "opus", value: 1).id == "opus")
        #expect(PieChartView.Entry(label: "opus", value: 1)
                == PieChartView.Entry(label: "opus", value: 1))
    }

    /// The same claim `SeriesVisibilityTests.togglingDoesNotRefetch` makes for
    /// the line chart, made where the pie can be caught: everything between the
    /// fetched frames and the drawn slices is pure.
    @Test("hiding a slice redraws from the frames already fetched")
    func hidingDoesNotRefetch() async {
        let client = SeriesVisibilityTests.CountingDatasource()
        let panel = PanelConfig(
            title: "Share", panelType: .pieChart, metric: .tokensByModel,
            gridPosition: GridPosition(column: 0, row: 0, width: 12, height: 4),
            targets: [PanelTarget(refId: "A", metric: .tokensByModel, query: "usage[1h]")]
        )
        let states = await PanelFetchCoordinator().fetchRegular(
            panels: [panel], time: TimeConfig(), variables: [],
            activeDatasource: DatasourceSelector(kind: BuiltinDatasourceKind.localCLI),
            defaultClient: client
        )
        #expect(client.count == 1)
        let frames = states[panel.id]?.frames

        let slices = PanelSeries.breakdown(metric: .tokensByModel, panel: panel,
                                           frames: frames, data: nil)
            .map { PieChartView.Entry(label: $0.label, value: $0.value) }
        let bucketed = PieChartView.bucketed(slices)
        #expect(bucketed.count == 2)

        var visibility = SeriesVisibility()
        visibility.toggle("opus", panelID: panel.id)
        let visible = PieChartView.visible(bucketed, hidden: visibility.hidden(for: panel.id))
        #expect(visible.map(\.label) == ["sonnet"])
        #expect(client.count == 1, "nothing was asked of the backend to make that happen")
    }
}
