import Testing
import Foundation
@testable import TokiMonitor

/// Contract Q4: a panel the ad hoc filter could not reach has to say so.
///
/// `QueryRewriter` leaves a query it cannot place a filter into exactly as it
/// was — the right call, because a guessed edit produces a query that still
/// parses and answers a different question. The cost of that call is a panel
/// showing every project while the toolbar shows `project = toki`, and it is
/// paid by the reader unless something carries the fact out to the screen.
///
/// `QueryRewriter.rewrite` reports it, `PanelFetchCoordinator` turns the report
/// into a notice on the result, and the panel draws a badge from that. These
/// pin the middle link — the one where the fact used to stop.
@Suite("Unapplied filter notice")
@MainActor
struct UnappliedFilterNoticeTests {

    // MARK: - Fixtures

    /// Answers everything, and remembers what it was asked.
    final class RecordingDatasource: QueryDataSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _executed: [String] = []
        /// Queries that should come back with no frames at all.
        private let emptyFor: Set<String>

        init(emptyFor: Set<String> = []) { self.emptyFor = emptyFor }

        var executed: [String] { lock.withLock { _executed } }

        func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
            lock.withLock { _executed.append(query) }
            return TimeSeriesData(points: [], granularity: .hourly)
        }

        func queryPromQL(query: String, time: TimeConfig) async throws -> QueryResult {
            let series = try await queryPromQLAsTimeSeries(query: query, time: time)
            guard !emptyFor.contains(query) else {
                return QueryResult(timeSeries: series, frames: FrameSet())
            }
            return QueryResult(timeSeries: series, frames: FrameSet(frames: [
                Frame(refId: "A", name: query, fields: [
                    Field(name: "time", values: .time([Date(timeIntervalSince1970: 0)])),
                    Field(name: "total_tokens", values: .number([1])),
                ])
            ]))
        }
    }

    private func adHoc(_ filters: [AdHocFilter]) -> DashboardVariable {
        var v = DashboardVariable(name: "filters", type: .custom)
        v.plugin = VariablePluginRef(kind: BuiltinVariablePluginKind.adHoc, spec: Data())
        v.adHocFilters = filters
        return v
    }

    private let projectFilter = AdHocFilter(key: "project", op: .equals, value: "toki")

    private func panel(_ queries: [(String, String)]) -> PanelConfig {
        PanelConfig(
            title: "Panel", panelType: .timeSeries, metric: .totalTokens,
            gridPosition: GridPosition(column: 0, row: 0, width: 12, height: 4),
            targets: queries.map {
                PanelTarget(refId: $0.0, metric: .totalTokens, query: $0.1)
            }
        )
    }

    private func fetch(_ panels: [PanelConfig], client: RecordingDatasource,
                       variables: [DashboardVariable]) async -> [UUID: PanelDataState] {
        await PanelFetchCoordinator().fetchRegular(
            panels: panels, time: TimeConfig(), variables: variables,
            activeDatasource: DatasourceSelector(kind: BuiltinDatasourceKind.localCLI),
            defaultClient: client
        )
    }

    // MARK: - The plan knows

    @Test("a query the filter cannot be placed in is planned as unapplied")
    func planReportsUnapplied() {
        let plans = PanelFetchCoordinator.plan(
            for: panel([("A", "unknown_metric[1h]")]),
            time: TimeConfig(), variables: [adHoc([projectFilter])]
        )
        #expect(plans.count == 1)
        #expect(plans[0].appliedFilters.hasUnapplied)
        #expect(plans[0].appliedFilters.reason?.isEmpty == false)
        #expect(plans[0].query == "unknown_metric[1h]", "the query itself is left alone")
    }

    @Test("a query the filter lands in is planned as applied")
    func planReportsApplied() {
        let plans = PanelFetchCoordinator.plan(
            for: panel([("A", "usage[1h]")]),
            time: TimeConfig(), variables: [adHoc([projectFilter])]
        )
        #expect(!plans[0].appliedFilters.hasUnapplied)
        #expect(plans[0].query.contains("project=\"toki\""))
    }

    // MARK: - The result carries it (T056)

    @Test("the result of a panel the filter missed carries a notice")
    func resultCarriesNotice() async {
        let client = RecordingDatasource()
        let p = panel([("A", "unknown_metric[1h]")])
        let states = await fetch([p], client: client, variables: [adHoc([projectFilter])])
        let notices = states[p.id]?.frames?.setNotices ?? []
        #expect(notices.count == 1)
        #expect(notices[0].contains("project") || notices[0].contains("필터"),
                "the notice names what did not happen: \(notices)")
    }

    @Test("a panel the filter reached carries no notice")
    func filteredPanelIsQuiet() async {
        let client = RecordingDatasource()
        let p = panel([("A", "usage[1h]")])
        let states = await fetch([p], client: client, variables: [adHoc([projectFilter])])
        #expect(states[p.id]?.frames?.setNotices.isEmpty == true)
    }

    @Test("a dashboard with no filters says nothing about filters")
    func noFiltersNoNotice() async {
        let client = RecordingDatasource()
        let p = panel([("A", "unknown_metric[1h]")])
        let states = await fetch([p], client: client, variables: [])
        #expect(states[p.id]?.frames?.setNotices.isEmpty == true)
    }

    /// The reason a notice on the frames alone was not enough: a query that
    /// matched nothing has no frames to hang it on, and "the filter never
    /// reached this panel" is exactly the thing a reader staring at an empty
    /// panel needs to know.
    @Test("a filtered query that returned nothing still says the filter missed")
    func noticeSurvivesAnEmptyResult() async {
        let client = RecordingDatasource(emptyFor: ["unknown_metric[1h]"])
        let p = panel([("A", "unknown_metric[1h]")])
        let states = await fetch([p], client: client, variables: [adHoc([projectFilter])])
        #expect(states[p.id]?.frames?.frames.isEmpty == true)
        #expect(states[p.id]?.frames?.setNotices.count == 1)
    }

    @Test("on a multi-query panel the notice names the query it is about")
    func noticeNamesTheQuery() {
        let plans = PanelFetchCoordinator.plan(
            for: panel([("A", "usage[1h]"), ("B", "unknown_metric[1h]")]),
            time: TimeConfig(), variables: [adHoc([projectFilter])]
        )
        let notices = PanelFetchCoordinator.unappliedFilterNotices(plans)
        #expect(notices.count == 1)
        #expect(notices[0].hasPrefix("B: "))
    }

    @Test("on a single-query panel the notice is not prefixed with a refId")
    func singleQueryNoticeIsNotPrefixed() {
        let plans = PanelFetchCoordinator.plan(
            for: panel([("A", "unknown_metric[1h]")]),
            time: TimeConfig(), variables: [adHoc([projectFilter])]
        )
        let notices = PanelFetchCoordinator.unappliedFilterNotices(plans)
        #expect(notices.count == 1)
        #expect(!notices[0].hasPrefix("A: "))
    }

    /// Inspect lists everything a result has to say; the panel face shows the
    /// filter notice. Both read the same list, so they cannot disagree.
    @Test("the notice is among what Inspect lists")
    func inspectSeesIt() {
        let set = FrameSet(frames: [], errors: [:], setNotices: ["filter did not apply"])
        #expect(set.notices == ["filter did not apply"])
    }
}
