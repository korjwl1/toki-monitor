import Testing
import Foundation
@testable import TokiMonitor

/// A query variable's whole job is to answer "what values does this label
/// take?". It could not answer that before: the result had one series-name
/// slot, so the loader took whatever the query happened to put there and
/// trusted the user to have grouped by the right dimension — and any label
/// outside an allowlist of two returned nothing at all.
@Suite("Label values variable")
struct LabelValuesVariableTests {

    /// Serves frames the way a migrated datasource does.
    private struct FrameBackend: QueryDataSource {
        let frames: FrameSet
        func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
            TimeSeriesData(points: [], granularity: .hourly)
        }
        func queryPromQL(query: String, time: TimeConfig) async throws -> QueryResult {
            QueryResult(timeSeries: TimeSeriesData(points: [], granularity: .hourly),
                        frames: frames)
        }
    }

    /// Records what it was asked, so interpolation can be checked.
    private final class QuerySpy: QueryDataSource, @unchecked Sendable {
        var lastQuery: String?
        func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
            try await queryPromQL(query: query, time: time).timeSeries
        }
        func queryPromQL(query: String, time: TimeConfig) async throws -> QueryResult {
            lastQuery = query
            return QueryResult(timeSeries: TimeSeriesData(points: [], granularity: .hourly))
        }
    }

    private func frame(_ labels: [String: String]) -> Frame {
        Frame(refId: "A", fields: [
            Field(name: "time", labels: labels,
                  values: .time([Date(timeIntervalSince1970: 0)])),
            Field(name: "total_tokens", labels: labels, values: .number([1])),
        ])
    }

    private func spec(_ labelName: String, query: String = "q") -> Data {
        (try? JSONEncoder().encode(TokiLabelValuesVariableSpec(
            datasource: nil, query: query, labelName: labelName
        ))) ?? Data()
    }

    private func context(_ client: any QueryDataSource,
                         resolved: [String: String] = [:]) -> VariableLoadContext {
        VariableLoadContext(time: TimeConfig(), resolvedVariables: resolved, queryClient: client)
    }

    // MARK: - The label actually means the label

    @Test("options come from the named label, not from whatever the query grouped by")
    func readsTheNamedLabel() async throws {
        let set = FrameSet(frames: [
            frame(["model": "opus", "project": "toki"]),
            frame(["model": "gpt", "project": "toki"]),
            frame(["model": "opus", "project": "wireguard"]),
        ])
        let loader = TokiLabelValuesVariableLoader()
        let ctx = context(FrameBackend(frames: set))

        let projects = try await loader.loadOptions(specData: spec("project"), context: ctx)
        #expect(projects.map(\.value) == ["toki", "wireguard"])

        let models = try await loader.loadOptions(specData: spec("model"), context: ctx)
        #expect(models.map(\.value) == ["gpt", "opus"], "same query, different label, different answer")
    }

    /// `device_id` was offered in the editor and always resolved to nothing,
    /// because the loader accepted only `model` and `project`.
    @Test("a label outside the old allowlist resolves")
    func labelBeyondTheOldAllowlist() async throws {
        let set = FrameSet(frames: [
            frame(["device_id": "dev-a"]), frame(["device_id": "dev-b"]),
        ])
        let options = try await TokiLabelValuesVariableLoader()
            .loadOptions(specData: spec("device_id"), context: context(FrameBackend(frames: set)))
        #expect(options.map(\.value) == ["dev-a", "dev-b"])
    }

    /// Silence is the right answer when the query genuinely has no such label
    /// — as opposed to the old silence, which meant "I refuse to look".
    @Test("a label the data does not carry yields no options")
    func unknownLabelIsEmpty() async throws {
        let set = FrameSet(frames: [frame(["model": "opus"])])
        let options = try await TokiLabelValuesVariableLoader()
            .loadOptions(specData: spec("nope"), context: context(FrameBackend(frames: set)))
        #expect(options.isEmpty)
    }

    @Test("an empty label name asks nothing")
    func emptyLabelName() async throws {
        let set = FrameSet(frames: [frame(["model": "opus"])])
        let options = try await TokiLabelValuesVariableLoader()
            .loadOptions(specData: spec(""), context: context(FrameBackend(frames: set)))
        #expect(options.isEmpty)
    }

    // MARK: - Discovery

    @Test("the editor can ask which labels the query returns")
    func discoversLabelKeys() async throws {
        let set = FrameSet(frames: [frame(["model": "opus", "provider": "claude_code"])])
        let keys = try await TokiLabelValuesVariableLoader()
            .loadLabelKeys(specData: spec("model"), context: context(FrameBackend(frames: set)))
        #expect(keys == ["model", "provider"])
    }

    // MARK: - Fallback and interpolation

    /// A datasource that serves no frames must behave exactly as before.
    @Test("a frameless datasource falls back to the legacy names")
    func framelessFallback() async throws {
        let options = try await TokiLabelValuesVariableLoader()
            .loadOptions(specData: spec("model"), context: context(QuerySpy()))
        #expect(options.isEmpty, "the stub returns no series; the point is that it does not crash")
    }

    /// A value like `claude|gpt` or `.*` must reach the query intact.
    @Test("dependent variables interpolate without regex reinterpretation")
    func interpolationIsEscaped() async throws {
        let spy = QuerySpy()
        _ = try await TokiLabelValuesVariableLoader().loadOptions(
            specData: spec("model", query: "sum by (model) (usage{provider=~\"$provider\"})"),
            context: context(spy, resolved: ["provider": "claude_code|codex"])
        )
        #expect(spy.lastQuery?.contains("claude_code|codex") == true)
    }

    @Test("a longer identifier sharing a prefix is not partially replaced")
    func wordBoundaryIsRespected() async throws {
        let spy = QuerySpy()
        _ = try await TokiLabelValuesVariableLoader().loadOptions(
            specData: spec("model", query: "$prov $provider"),
            context: context(spy, resolved: ["prov": "X"])
        )
        #expect(spy.lastQuery == "X $provider")
    }
}
