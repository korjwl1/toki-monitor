import Testing
import Foundation
@testable import TokiMonitor

/// One logical series can arrive split across providers — a project is not
/// provider-specific, so `by (project)` can yield the same name twice in one
/// bucket. The point index used to keep only the last of them while the
/// bucket's totals summed both, so a stat card and its chart disagreed.
@Suite("Duplicate series names are summed, not dropped")
struct SeriesMergeTests {

    private func summary(_ model: String, tokens: UInt64, events: Int,
                         cost: Double? = nil, cacheRead: UInt64? = nil) -> TokiModelSummary {
        TokiModelSummary(
            model: model, inputTokens: tokens / 2, outputTokens: tokens / 2,
            totalTokens: tokens, events: events, costUsd: cost,
            cacheCreationInputTokens: nil, cacheReadInputTokens: cacheRead,
            cachedInputTokens: nil, reasoningOutputTokens: nil
        )
    }

    @Test("the index agrees with the bucket total")
    func indexAgreesWithTotal() {
        let point = TimeSeriesPoint(date: Date(), models: [
            summary("shared-project", tokens: 100, events: 2, cost: 1.5),
            summary("shared-project", tokens: 40, events: 1, cost: 0.5),
        ])
        #expect(point.totalTokens == 140, "the bucket total sums both entries")
        let indexed = point.modelIndex["shared-project"]
        #expect(indexed?.totalTokens == 140, "the index must not drop one of them")
        #expect(indexed?.events == 3)
        #expect(indexed?.costUsd == 2.0)
    }

    /// Optional provider-specific columns must not be invented for a provider
    /// that never reported them, nor lost when only one side has them.
    @Test("optional columns stay nil when neither side reported them")
    func optionalsArePreserved() {
        let a = summary("p", tokens: 10, events: 1, cacheRead: 7)
        let b = summary("p", tokens: 10, events: 1)
        let merged = a.merged(with: b)
        #expect(merged.cacheReadInputTokens == 7, "present on one side is kept")
        #expect(merged.cacheCreationInputTokens == nil, "absent on both stays absent")
        #expect(merged.costUsd == nil, "absent on both stays absent rather than becoming 0")
    }

    @Test("distinct names are untouched")
    func distinctNamesUnaffected() {
        let point = TimeSeriesPoint(date: Date(), models: [
            summary("a", tokens: 10, events: 1),
            summary("b", tokens: 20, events: 2),
        ])
        #expect(point.modelIndex.count == 2)
        #expect(point.modelIndex["a"]?.totalTokens == 10)
        #expect(point.modelIndex["b"]?.totalTokens == 20)
    }
}
