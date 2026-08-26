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
