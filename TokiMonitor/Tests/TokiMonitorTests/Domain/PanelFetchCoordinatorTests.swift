import Testing
import Foundation
@testable import TokiMonitor

/// The coordinator decides which queries run and what each panel ends up
/// holding, and until now nothing tested it. The defect it existed with was
/// invisible from the outside: the editor accepted queries B..Z, saved them,
/// exported them — and only A was ever sent. A panel with two queries redrew,
/// looked answered, and showed one of them (contract Q5).
///
/// So these tests are mostly about what the fetch DOES, not about what it
/// returns: which query strings reached a backend, and in what state a panel
/// ends when some of them fail.
/// A frame that names the query it came from, so a test can tell whose result
/// landed in a panel. File scope because the recording datasource builds it off
/// the main actor.
private func namedFrame(_ query: String) -> Frame {
    Frame(refId: "A", name: query, fields: [
        Field(name: "time", values: .time([Date(timeIntervalSince1970: 0)])),
        Field(name: "total_tokens", values: .number([1])),
    ], meta: FrameMeta(executedQuery: query))
}

@Suite("Panel fetch coordinator")
@MainActor
struct PanelFetchCoordinatorTests {

    // MARK: - Fixtures

    /// Records every query it is asked for, and answers from a table.
    final class RecordingDatasource: QueryDataSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _executed: [String] = []
        private let answers: [String: Result<TimeSeriesData, Error>]
        private let fallback: Result<TimeSeriesData, Error>

        init(answers: [String: Result<TimeSeriesData, Error>] = [:],
             fallback: Result<TimeSeriesData, Error> = .success(
                TimeSeriesData(points: [], granularity: .hourly))) {
            self.answers = answers
            self.fallback = fallback
        }

        var executed: [String] {
            lock.withLock { _executed }
        }

        func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
            lock.withLock { _executed.append(query) }
            switch answers[query] ?? fallback {
            case .success(let data): return data
            case .failure(let error): throw error
            }
        }

        func queryPromQL(query: String, time: TimeConfig) async throws -> QueryResult {
            let series = try await queryPromQLAsTimeSeries(query: query, time: time)
            return QueryResult(timeSeries: series,
                               frames: FrameSet(frames: [namedFrame(query)]))
        }
    }

    struct StubError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func panel(_ title: String, targets: [PanelTarget],
                       metric: PanelMetric = .totalTokens) -> PanelConfig {
        PanelConfig(
            title: title,
            panelType: .timeSeries,
            metric: metric,
            gridPosition: GridPosition(column: 0, row: 0, width: 12, height: 4),
            targets: targets
        )
    }

    private func target(_ refId: String, _ query: String?, hide: Bool = false) -> PanelTarget {
        PanelTarget(refId: refId, metric: .totalTokens, query: query, hide: hide)
    }

    private func fetch(_ panels: [PanelConfig],
                       client: RecordingDatasource,
                       variables: [DashboardVariable] = []) async -> [UUID: PanelDataState] {
        await PanelFetchCoordinator().fetchRegular(
            panels: panels,
            time: TimeConfig(),
            variables: variables,
            activeDatasource: DatasourceSelector(kind: BuiltinDatasourceKind.localCLI),
            defaultClient: client
        )
    }

    private func frameNames(_ state: PanelDataState?) -> [String] {
        (state?.frames?.frames ?? []).compactMap(\.name)
    }

    // MARK: - Every refId runs (T035)

    @Test("all three queries of a panel are executed, not just A")
    func everyTargetRuns() async {
        let client = RecordingDatasource()
        let p = panel("three", targets: [
            target("A", "usage[1h]"),
            target("B", "cost[1h]"),
            target("C", "events[1h]"),
        ])
        let states = await fetch([p], client: client)
        #expect(client.executed.sorted() == ["cost[1h]", "events[1h]", "usage[1h]"])
        #expect(frameNames(states[p.id]).sorted() == ["cost[1h]", "events[1h]", "usage[1h]"])
    }

    @Test("each result is tagged with the refId that asked for it")
    func framesCarryTheirRefId() async {
        let client = RecordingDatasource()
        let p = panel("two", targets: [target("A", "usage[1h]"), target("B", "cost[1h]")])
        let states = await fetch([p], client: client)
        let byRef = Dictionary(uniqueKeysWithValues:
            (states[p.id]?.frames?.frames ?? []).map { ($0.refId, $0.name ?? "") })
        #expect(byRef["A"] == "usage[1h]")
        #expect(byRef["B"] == "cost[1h]")
    }

    /// The default query is a template like any other, so what reaches the
    /// backend is its interpolated form.
    private func interpolated(_ template: String) -> String {
        VariableResolver.interpolate(template: template, time: TimeConfig(), variables: [])
    }

    @Test("a panel with no targets still runs its metric's default query")
    func defaultQuery() async {
        let client = RecordingDatasource()
        let p = panel("bare", targets: [], metric: .totalCost)
        _ = await fetch([p], client: client)
        #expect(client.executed == [interpolated(PanelMetric.totalCost.defaultQuery)])
    }

    @Test("a target with no PromQL override runs its own metric's default")
    func perTargetMetric() async {
        let client = RecordingDatasource()
        var p = panel("mixed", targets: [
            PanelTarget(refId: "A", metric: .totalTokens),
            PanelTarget(refId: "B", metric: .apiCalls),
        ])
        p.queries = nil
        _ = await fetch([p], client: client)
        #expect(client.executed.contains(interpolated(PanelMetric.totalTokens.defaultQuery)))
        #expect(client.executed.contains(interpolated(PanelMetric.apiCalls.defaultQuery)),
                "B is a different metric and must not inherit A's")
    }

    @Test("queries beyond Z are not reachable, and A..Z all are")
    func manyTargets() async {
        let client = RecordingDatasource()
        let letters = (0..<26).map { String(UnicodeScalar(65 + $0)!) }
        let p = panel("many", targets: letters.map { target($0, "usage{model=\"\($0)\"}") })
        _ = await fetch([p], client: client)
        #expect(client.executed.count == 26,
                "the concurrency cap must not drop the queries it defers")
    }

    // MARK: - Perses query envelopes

    @Test("every query envelope is executed, not the first")
    func everyEnvelopeRuns() async {
        let client = RecordingDatasource()
        var p = panel("envelopes", targets: [])
        p.queries = ["usage[1h]", "cost[1h]"].enumerated().map { index, query in
            envelope(refId: String(UnicodeScalar(65 + index)!), query: query)
        }
        _ = await fetch([p], client: client)
        #expect(client.executed.sorted() == ["cost[1h]", "usage[1h]"])
    }

    private func envelope(refId: String, query: String, hide: Bool = false) -> Query {
        let spec = TokiPromQLQuerySpec(datasource: nil, metric: .totalTokens,
                                       query: query, hide: hide ? true : nil)
        return Query(
            kind: BuiltinQueryKind.timeSeriesQuery,
            spec: QuerySpec(name: refId, plugin: QueryPluginRef(
                kind: BuiltinQueryPluginKind.tokiPromQLQuery,
                spec: (try? JSONEncoder().encode(spec)) ?? Data()
            ))
        )
    }

    // MARK: - hide executes and does not render (T036)

    @Test("a hidden query is executed")
    func hiddenQueryRuns() async {
        let client = RecordingDatasource()
        let p = panel("hidden", targets: [
            target("A", "usage[1h]"),
            target("B", "cost[1h]", hide: true),
        ])
        _ = await fetch([p], client: client)
        #expect(client.executed.sorted() == ["cost[1h]", "usage[1h]"],
                "hide is about the legend, not about whether the query runs")
    }

    @Test("a hidden query does not reach what the panel draws")
    func hiddenQueryDoesNotRender() async {
        let client = RecordingDatasource()
        let p = panel("hidden", targets: [
            target("A", "usage[1h]"),
            target("B", "cost[1h]", hide: true),
        ])
        let states = await fetch([p], client: client)
        #expect(frameNames(states[p.id]) == ["usage[1h]"])
    }

    @Test("hide on a query envelope is honoured too")
    func hiddenEnvelope() async {
        let client = RecordingDatasource()
        var p = panel("hidden envelope", targets: [])
        p.queries = [envelope(refId: "A", query: "usage[1h]"),
                     envelope(refId: "B", query: "cost[1h]", hide: true)]
        let states = await fetch([p], client: client)
        #expect(client.executed.sorted() == ["cost[1h]", "usage[1h]"])
        #expect(frameNames(states[p.id]) == ["usage[1h]"])
    }

    @Test("a hidden query failing does not make the panel look failed")
    func hiddenFailureIsNotThePanelsFailure() async {
        let client = RecordingDatasource(answers: [
            "cost[1h]": .failure(StubError(message: "boom")),
        ])
        let p = panel("hidden failure", targets: [
            target("A", "usage[1h]"),
            target("B", "cost[1h]", hide: true),
        ])
        let states = await fetch([p], client: client)
        guard case .loaded = states[p.id] else {
            Issue.record("the visible query answered; the panel is loaded")
            return
        }
        #expect(states[p.id]?.frames?.errors["B"] == nil,
                "a query nobody is looking at does not raise an error at them")
    }

    @Test("a panel whose every query is hidden is empty, not failed")
    func allHidden() async {
        let client = RecordingDatasource()
        let p = panel("all hidden", targets: [target("A", "usage[1h]", hide: true)])
        let states = await fetch([p], client: client)
        guard case .loaded = states[p.id] else {
            Issue.record("hiding everything is a display choice, not a failure")
            return
        }
        #expect(frameNames(states[p.id]).isEmpty)
    }

    // MARK: - Partial failure (T037)

    @Test("one query failing does not blank the others")
    func partialFailureKeepsTheRest() async {
        let client = RecordingDatasource(answers: [
            "cost[1h]": .failure(StubError(message: "daemon says no")),
        ])
        let p = panel("partial", targets: [
            target("A", "usage[1h]"),
            target("B", "cost[1h]"),
            target("C", "events[1h]"),
        ])
        let states = await fetch([p], client: client)
        guard case .loaded = states[p.id] else {
            Issue.record("two queries answered; the panel has something to draw")
            return
        }
        #expect(frameNames(states[p.id]).sorted() == ["events[1h]", "usage[1h]"])
    }

    @Test("the query that failed is named, with its own reason")
    func failedTargetIsReported() async {
        let client = RecordingDatasource(answers: [
            "cost[1h]": .failure(StubError(message: "unsupported query: `cost`")),
        ])
        let p = panel("partial", targets: [target("A", "usage[1h]"), target("B", "cost[1h]")])
        let states = await fetch([p], client: client)
        #expect(states[p.id]?.frames?.errors["B"] == "unsupported query: `cost`")
        #expect(states[p.id]?.frames?.errors["A"] == nil)
    }

    @Test("when every visible query fails the panel fails, with every reason")
    func totalFailure() async {
        let client = RecordingDatasource(fallback: .failure(StubError(message: "no daemon")))
        let p = panel("dead", targets: [target("A", "usage[1h]"), target("B", "cost[1h]")])
        let states = await fetch([p], client: client)
        guard case .error(let message) = states[p.id] else {
            Issue.record("nothing answered; the panel failed")
            return
        }
        #expect(message.contains("A: no daemon"))
        #expect(message.contains("B: no daemon"))
    }

    @Test("a single-query panel fails with the reason alone, unprefixed")
    func singleQueryFailure() async {
        let client = RecordingDatasource(fallback: .failure(StubError(message: "no daemon")))
        let p = panel("one", targets: [target("A", "usage[1h]")])
        let states = await fetch([p], client: client)
        guard case .error(let message) = states[p.id] else {
            Issue.record("expected failure")
            return
        }
        #expect(message == "no daemon", "one query needs no refId to identify it")
    }

    // MARK: - Grouping and interpolation

    @Test("panels sharing a query share one round trip")
    func sharedQueryRunsOnce() async {
        let client = RecordingDatasource()
        let a = panel("a", targets: [target("A", "usage[1h]")])
        let b = panel("b", targets: [target("A", "usage[1h]")])
        let states = await fetch([a, b], client: client)
        #expect(client.executed == ["usage[1h]"])
        #expect(frameNames(states[a.id]) == ["usage[1h]"])
        #expect(frameNames(states[b.id]) == ["usage[1h]"],
                "sharing the request must not mean only one panel gets the answer")
    }

    @Test("two targets of one panel with the same query share one round trip")
    func duplicateTargetsRunOnce() async {
        let client = RecordingDatasource()
        let p = panel("dupes", targets: [target("A", "usage[1h]"), target("B", "usage[1h]")])
        let states = await fetch([p], client: client)
        #expect(client.executed == ["usage[1h]"])
        #expect(frameNames(states[p.id]).count == 2, "both refIds still get a result")
    }

    @Test("every target's query is interpolated, not only A's")
    func interpolationPerTarget() async {
        let client = RecordingDatasource()
        let p = panel("vars", targets: [
            target("A", "usage[$__interval]"),
            target("B", "cost[$__interval]"),
        ])
        let time = TimeConfig()
        _ = await PanelFetchCoordinator().fetchRegular(
            panels: [p], time: time, variables: [],
            activeDatasource: DatasourceSelector(kind: BuiltinDatasourceKind.localCLI),
            defaultClient: client
        )
        #expect(client.executed.allSatisfy { !$0.contains("$__interval") })
        #expect(client.executed.contains("cost[\(time.bucketString)]"))
    }

    // MARK: - Planning, without any fetching

    @Test("planning names every query a panel declares, in order")
    func planIsOrdered() {
        let p = panel("plan", targets: [
            target("A", "usage[1h]"), target("B", "cost[1h]", hide: true),
        ])
        let plans = PanelFetchCoordinator.plan(for: p, time: TimeConfig(), variables: [])
        #expect(plans.map(\.refId) == ["A", "B"])
        #expect(plans.map(\.hidden) == [false, true])
        #expect(plans.allSatisfy { $0.panelID == p.id })
    }

    @Test("a query envelope wins over the legacy target it was built from")
    func envelopeWinsOverTarget() {
        var p = panel("both", targets: [target("A", "legacy[1h]")])
        p.queries = [envelope(refId: "A", query: "envelope[1h]")]
        let plans = PanelFetchCoordinator.plan(for: p, time: TimeConfig(), variables: [])
        #expect(plans.map(\.query) == ["envelope[1h]"])
    }
}
