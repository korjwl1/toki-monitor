import Foundation
import Testing
@testable import TokiMonitor

@Suite("TimeSeriesData cached properties")
struct TimeSeriesDataCacheTests {

    private func makeSummary(_ model: String, tokens: UInt64, cost: Double, events: Int) -> TokiModelSummary {
        TokiModelSummary(
            model: model,
            inputTokens: tokens / 2,
            outputTokens: tokens / 2,
            totalTokens: tokens,
            events: events,
            costUsd: cost,
            cacheCreationInputTokens: nil,
            cacheReadInputTokens: nil,
            cachedInputTokens: nil,
            reasoningOutputTokens: nil
        )
    }

    @Test("allModelNames is sorted and unique")
    func allModelNames() {
        let points = [
            TimeSeriesPoint(date: Date(), models: [
                makeSummary("opus", tokens: 100, cost: 0.01, events: 1),
                makeSummary("sonnet", tokens: 200, cost: 0.02, events: 2),
            ]),
            TimeSeriesPoint(date: Date(), models: [
                makeSummary("opus", tokens: 50, cost: 0.005, events: 1),
                makeSummary("haiku", tokens: 300, cost: 0.003, events: 3),
            ]),
        ]
        let data = TimeSeriesData(points: points, granularity: .hourly)
        #expect(data.allModelNames == ["haiku", "opus", "sonnet"])
    }

    @Test("topModel returns highest token model")
    func topModel() {
        let points = [
            TimeSeriesPoint(date: Date(), models: [
                makeSummary("opus", tokens: 100, cost: 0.01, events: 1),
                makeSummary("sonnet", tokens: 500, cost: 0.02, events: 2),
            ]),
        ]
        let data = TimeSeriesData(points: points, granularity: .hourly)
        #expect(data.topModel == "sonnet")
    }

    @Test("totalTokens, totalCost, totalEvents aggregate correctly")
    func totals() {
        let points = [
            TimeSeriesPoint(date: Date(), models: [
                makeSummary("opus", tokens: 100, cost: 1.0, events: 2),
            ]),
            TimeSeriesPoint(date: Date(), models: [
                makeSummary("opus", tokens: 200, cost: 2.0, events: 3),
            ]),
        ]
        let data = TimeSeriesData(points: points, granularity: .hourly)
        #expect(data.totalTokens == 300)
        #expect(data.totalCost == 3.0)
        #expect(data.totalEvents == 5)
    }

    @Test("modelIndex provides O(1) lookup")
    func modelIndex() {
        let point = TimeSeriesPoint(date: Date(), models: [
            makeSummary("opus", tokens: 100, cost: 0.01, events: 1),
            makeSummary("sonnet", tokens: 200, cost: 0.02, events: 2),
        ])
        #expect(point.modelIndex["opus"]?.totalTokens == 100)
        #expect(point.modelIndex["sonnet"]?.totalTokens == 200)
        #expect(point.modelIndex["haiku"] == nil)
    }

    @Test("chartPoints uses modelIndex for extraction")
    func chartPoints() {
        let date = Date()
        let points = [
            TimeSeriesPoint(date: date, models: [
                makeSummary("opus", tokens: 100, cost: 0.5, events: 3),
            ]),
        ]
        let data = TimeSeriesData(points: points, granularity: .hourly)

        let tokenPoints = data.tokensFor(model: "opus")
        #expect(tokenPoints.count == 1)
        #expect(tokenPoints[0].value == 100.0)

        let costPoints = data.costFor(model: "opus")
        #expect(costPoints[0].value == 0.5)

        let eventPoints = data.eventsFor(model: "opus")
        #expect(eventPoints[0].value == 3.0)

        let missing = data.tokensFor(model: "haiku")
        #expect(missing[0].value == 0.0)
    }

    @Test("Empty points produce empty aggregates")
    func emptyData() {
        let data = TimeSeriesData(points: [], granularity: .hourly)
        #expect(data.allModelNames.isEmpty)
        #expect(data.topModel == nil)
        #expect(data.totalTokens == 0)
        #expect(data.totalCost == 0)
        #expect(data.totalEvents == 0)
    }
}
