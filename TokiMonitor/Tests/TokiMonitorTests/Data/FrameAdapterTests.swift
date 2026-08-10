import Testing
import Foundation
@testable import TokiMonitor

/// The acceptance criterion for the frame work: a query grouped by two
/// dimensions must keep them as INDEPENDENT NAMED labels, and provider must
/// survive. The previous contract lost both — it had one series-name slot, so
/// `by (model, project)` collapsed to an opaque string and provider was
/// discarded at parse time.
@Suite("Frame adapter recovers named dimensions")
struct FrameAdapterTests {

    private func summary(_ model: String, total: UInt64, events: Int = 1,
                         cost: Double? = nil) -> TokiModelSummary {
        TokiModelSummary(
            model: model, inputTokens: total / 2, outputTokens: total / 2,
            totalTokens: total, events: events, costUsd: cost,
            cacheCreationInputTokens: nil, cacheReadInputTokens: nil,
            cachedInputTokens: nil, reasoningOutputTokens: nil
        )
    }

    private func entry(_ period: String, _ models: [TokiModelSummary]) -> TokiReportEntry {
        TokiReportEntry(period: period, session: nil, usagePerModels: models)
    }

    // MARK: - The clause parser

    @Test("dimension names come from the query, in written order")
    func parsesGroupBy() {
        #expect(FrameAdapter.groupByDimensions(in: "sum(x[1d]) by (model, project)")
                == ["model", "project"])
        #expect(FrameAdapter.groupByDimensions(in: "sum(x[1d]) by(project)") == ["project"])
        #expect(FrameAdapter.groupByDimensions(in: "sum(x[1d])") == [])
        // Order is what makes positional recovery valid, so it must not be sorted.
        #expect(FrameAdapter.groupByDimensions(in: "sum(x[1d]) by (project, model)")
                == ["project", "model"])
    }

    // MARK: - The acceptance criterion

    @Test("two grouping dimensions survive as independent labels")
    func twoDimensionsSurvive() throws {
        let set = FrameAdapter.frames(
            providers: ["claude_code": [
                entry("2026-08-10T00:00:00|opus-5|toki", [summary("opus-5", total: 100)]),
                entry("2026-08-10T00:00:00|opus-5|wireguard", [summary("opus-5", total: 40)]),
            ]],
            query: "sum(toki_tokens_total[1d]) by (model, project)"
        )
        #expect(set.frames.count == 2, "two projects are two series, not one blended one")

        let toki = try #require(set.frames.first { $0.commonLabels["project"] == "toki" })
        #expect(toki.commonLabels["model"] == "opus-5")
        #expect(toki.commonLabels["provider"] == "claude_code")
        #expect(toki.field(named: "total_tokens")?.values.numbers?.first == 100)

        let wg = try #require(set.frames.first { $0.commonLabels["project"] == "wireguard" })
        #expect(wg.field(named: "total_tokens")?.values.numbers?.first == 40)
    }

    /// The old parser merged every provider into one map, discarding the key.
    @Test("provider is a label, not something merged away")
    func providerIsPreserved() throws {
        let set = FrameAdapter.frames(
            providers: [
                "claude_code": [entry("2026-08-10T00:00:00|toki", [summary("toki", total: 10)])],
                "codex": [entry("2026-08-10T00:00:00|toki", [summary("toki", total: 5)])],
            ],
            query: "sum(toki_tokens_total[1d]) by (project)"
        )
        #expect(set.frames.count == 2, "same project from two providers stays two series")
        let providers = Set(set.frames.compactMap { $0.commonLabels["provider"] })
        #expect(providers == ["claude_code", "codex"])
        // And they are not silently summed into each other.
        let claude = try #require(set.frames.first { $0.commonLabels["provider"] == "claude_code" })
        #expect(claude.field(named: "total_tokens")?.values.numbers?.first == 10)
    }

    /// With a single dimension the daemon puts the whole value in `model`
    /// (`inner_key`), so a name containing the separator is NOT corrupted.
    @Test("a single-dimension value containing the separator is preserved")
    func separatorInValueSurvives() throws {
        let set = FrameAdapter.frames(
            providers: ["codex": [
                entry("2026-08-10T00:00:00|weird|name", [summary("weird|name", total: 7)])
            ]],
            query: "sum(toki_tokens_total[1d]) by (project)"
        )
        let f = try #require(set.frames.first)
        #expect(f.commonLabels["project"] == "weird|name")
    }

    /// With MORE than one dimension the same situation is genuinely ambiguous.
    /// A wrong label is worse than a missing one, so it must be reported.
    @Test("an ambiguous multi-dimension split is reported, not guessed")
    func ambiguousSplitIsReported() throws {
        let set = FrameAdapter.frames(
            providers: ["codex": [
                entry("2026-08-10T00:00:00|opus|a|b", [summary("opus", total: 1)])
            ]],
            query: "sum(toki_tokens_total[1d]) by (model, project)"
        )
        #expect(!set.notices.isEmpty, "the caller must be told the dimensions were dropped")
        let f = try #require(set.frames.first)
        #expect(f.commonLabels["project"] == nil, "no invented label")
    }

    // MARK: - Shape guarantees

    @Test("ungrouped results keep the model name and stay rectangular")
    func ungroupedShape() throws {
        let set = FrameAdapter.frames(
            providers: ["claude_code": [
                entry("2026-08-10T00:00:00", [summary("opus-5", total: 10, cost: 1.0)]),
                entry("2026-08-11T00:00:00", [summary("opus-5", total: 20, cost: 2.0)]),
            ]],
            query: "sum(toki_tokens_total[1d])"
        )
        let f = try #require(set.frames.first)
        #expect(f.commonLabels["model"] == "opus-5")
        #expect(f.rowCount == 2)
        #expect(f.isRectangular, "readers index across columns; ragged frames are a producer bug")
        #expect(f.timeField != nil)
        #expect(f.field(named: "cost_usd")?.values.numbers == [1.0, 2.0])
    }

    /// A column nobody reported must be absent, not a wall of zeroes that
    /// looks like real measured data.
    @Test("optional measures appear only when reported")
    func optionalColumnsAreOmitted() throws {
        let set = FrameAdapter.frames(
            providers: ["codex": [entry("2026-08-10T00:00:00", [summary("gpt", total: 5)])]],
            query: "sum(toki_tokens_total[1d])"
        )
        let f = try #require(set.frames.first)
        #expect(f.field(named: "cache_read_input_tokens") == nil)
        #expect(f.field(named: "cost_usd") == nil)
        #expect(f.field(named: "total_tokens") != nil)
    }

    @Test("rows are ordered by time regardless of arrival order")
    func rowsAreSorted() throws {
        let set = FrameAdapter.frames(
            providers: ["codex": [
                entry("2026-08-12T00:00:00", [summary("gpt", total: 3)]),
                entry("2026-08-10T00:00:00", [summary("gpt", total: 1)]),
                entry("2026-08-11T00:00:00", [summary("gpt", total: 2)]),
            ]],
            query: "sum(toki_tokens_total[1d])"
        )
        let f = try #require(set.frames.first)
        #expect(f.field(named: "total_tokens")?.values.numbers == [1, 2, 3])
    }

    @Test("the same series twice in one bucket is summed, not overwritten")
    func duplicateBucketIsSummed() throws {
        let set = FrameAdapter.frames(
            providers: ["codex": [
                entry("2026-08-10T00:00:00", [summary("gpt", total: 4, events: 1),
                                              summary("gpt", total: 6, events: 2)])
            ]],
            query: "sum(toki_tokens_total[1d])"
        )
        let f = try #require(set.frames.first)
        #expect(f.rowCount == 1)
        #expect(f.field(named: "total_tokens")?.values.numbers?.first == 10)
        #expect(f.field(named: "events")?.values.numbers?.first == 3)
    }

    @Test("provenance travels with the frame for Inspect")
    func provenanceIsRecorded() throws {
        let q = "sum(toki_tokens_total[1d]) by (project)"
        let set = FrameAdapter.frames(
            providers: ["codex": [entry("2026-08-10T00:00:00|toki", [summary("toki", total: 1)])]],
            query: q, refId: "B", datasource: "local"
        )
        let f = try #require(set.frames.first)
        #expect(f.refId == "B")
        #expect(f.meta.executedQuery == q)
        #expect(f.meta.datasource == "local")
    }

    @Test("display name is stable and derived from labels")
    func displayNameIsStable() throws {
        let set = FrameAdapter.frames(
            providers: ["codex": [
                entry("2026-08-10T00:00:00|opus|toki", [summary("opus", total: 1)])
            ]],
            query: "sum(x[1d]) by (model, project)"
        )
        let f = try #require(set.frames.first)
        // Sorted by label key (model, project, provider) so one series never
        // renders under two different names between runs.
        #expect(f.displayName == "opus · toki · codex")
    }
}
