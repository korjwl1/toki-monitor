import Testing
import Foundation
@testable import TokiMonitor

/// Every panel type reads its data through one path now. These tests pin the
/// two things that path must not lose: the grouping dimensions the frames
/// carry, and the legacy behaviour for a datasource that serves no frames.
@Suite("Panel series")
@MainActor
struct PanelSeriesTests {

    private func frame(_ labels: [String: String],
                       tokens: [Double?], cost: [Double?]? = nil,
                       events: [Double?]? = nil) -> Frame {
        var fields: [Field] = [
            Field(name: "time", labels: labels,
                  values: .time(tokens.indices.map {
                      Date(timeIntervalSince1970: Double($0) * 3600)
                  })),
            Field(name: "total_tokens", labels: labels, values: .number(tokens)),
        ]
        if let cost {
            fields.append(Field(name: "cost_usd", labels: labels, values: .number(cost)))
        }
        if let events {
            fields.append(Field(name: "events", labels: labels, values: .number(events)))
        }
        return Frame(refId: "A", fields: fields)
    }

    private func panel(_ metric: PanelMetric, _ type: PanelType) -> PanelConfig {
        PanelConfig(title: "p", panelType: type, metric: metric,
                    gridPosition: GridPosition(column: 0, row: 0, width: 6, height: 2))
    }

    // MARK: - Tables

    /// The legacy extractor keyed rows by a single opaque name, so the same
    /// project reported by two providers became one row and the reader could
    /// not tell where the number came from.
    @Test("a table keeps every grouping dimension as its own row")
    func tableKeepsDimensions() {
        let set = FrameSet(frames: [
            frame(["project": "toki", "provider": "claude_code"], tokens: [10, 5]),
            frame(["project": "toki", "provider": "codex"], tokens: [3]),
        ])
        let rows = PanelSeries.rows(frames: set, data: nil)
        #expect(rows.count == 2)
        #expect(rows.map(\.model).contains("toki · claude_code"))
        #expect(rows.first?.tokens == 15, "rows are sorted by size, largest first")
    }

    @Test("a table sums each measure over the window")
    func tableSumsMeasures() throws {
        let set = FrameSet(frames: [
            frame(["model": "opus"], tokens: [10, 20], cost: [1.5, 2.5], events: [1, 2])
        ])
        let row = try #require(PanelSeries.rows(frames: set, data: nil).first)
        #expect(row.tokens == 30)
        #expect(row.cost == 4.0)
        #expect(row.events == 3)
    }

    // MARK: - Proportions

    /// A pie shows proportions of a whole, so one project must be one slice
    /// even when the query also grouped by provider.
    @Test("a breakdown aggregates by its dimension, not by series")
    func breakdownAggregatesByLabel() throws {
        let set = FrameSet(frames: [
            frame(["project": "toki", "provider": "claude_code"], tokens: [10]),
            frame(["project": "toki", "provider": "codex"], tokens: [5]),
            frame(["project": "other", "provider": "codex"], tokens: [1]),
        ])
        let slices = PanelSeries.breakdown(metric: .tokensByProject,
                                           panel: panel(.tokensByProject, .pieChart),
                                           frames: set, data: nil)
        #expect(slices.count == 2)
        let toki = try #require(slices.first { $0.label == "toki" })
        #expect(toki.value == 15)
        #expect(slices.first?.label == "toki", "largest slice first")
    }

    @Test("a model breakdown answers with models, not full series names")
    func modelBreakdownUsesTheModelLabel() {
        let set = FrameSet(frames: [
            frame(["model": "opus", "provider": "claude_code"], tokens: [7])
        ])
        let slices = PanelSeries.breakdown(metric: .modelBreakdown,
                                           panel: panel(.modelBreakdown, .pieChart),
                                           frames: set, data: nil)
        #expect(slices.map(\.label) == ["opus"])
    }

    /// A frame with no such label still has to appear somewhere; dropping it
    /// would make the proportions wrong.
    @Test("a series missing the dimension keeps its full name")
    func missingLabelKeepsFullName() {
        let set = FrameSet(frames: [frame(["provider": "codex"], tokens: [4])])
        let slices = PanelSeries.breakdown(metric: .modelBreakdown,
                                           panel: panel(.modelBreakdown, .pieChart),
                                           frames: set, data: nil)
        #expect(slices.count == 1)
        #expect(slices[0].value == 4)
    }

    // MARK: - Charts

    @Test("chart points honour the legend's hidden set")
    func chartPointsRespectHiddenSeries() {
        let set = FrameSet(frames: [
            frame(["model": "opus", "provider": "claude_code"], tokens: [1, 2]),
            frame(["model": "gpt", "provider": "codex"], tokens: [3, 4]),
        ])
        let all = PanelSeries.chartPoints(metric: .tokensByModel,
                                          panel: panel(.tokensByModel, .timeSeries),
                                          frames: set, data: nil, hidden: [])
        #expect(all.count == 2)
        let one = PanelSeries.chartPoints(metric: .tokensByModel,
                                          panel: panel(.tokensByModel, .timeSeries),
                                          frames: set, data: nil, hidden: ["gpt"])
        #expect(one.count == 1, "hiding is keyed by model even when the name carries provider")
        #expect(one.first?.model == "opus · claude_code")
    }

    /// The chart is a counter chart, so an unreported bucket draws at zero —
    /// but only at the chart, which is why the frame still holds nil.
    @Test("an unreported bucket draws at zero without being stored as zero")
    func gapsDrawAtZero() throws {
        let set = FrameSet(frames: [frame(["model": "opus"], tokens: [nil, 5])])
        let points = try #require(PanelSeries.chartPoints(
            metric: .tokensByModel, panel: panel(.tokensByModel, .timeSeries),
            frames: set, data: nil, hidden: []).first?.points)
        #expect(points.map(\.value) == [0, 5])
        #expect(set.frames[0].field(named: "total_tokens")?.values.numbers == [nil, 5])
    }

    // MARK: - The fallback

    /// A datasource that has not been migrated must render exactly as before.
    @Test("no frames falls back to the legacy extractor")
    func fallsBackWithoutFrames() {
        let summary = TokiModelSummary(
            model: "opus", inputTokens: 1, outputTokens: 1, totalTokens: 2, events: 1,
            costUsd: 0.5, cacheCreationInputTokens: nil, cacheReadInputTokens: nil,
            cachedInputTokens: nil, reasoningOutputTokens: nil
        )
        let data = TimeSeriesData(
            points: [TimeSeriesPoint(date: Date(timeIntervalSince1970: 0), models: [summary])],
            granularity: .hourly
        )
        #expect(PanelSeries.rows(frames: nil, data: data).first?.model == "opus")
        #expect(PanelSeries.rows(frames: FrameSet(), data: data).first?.model == "opus",
                "an empty frame set is not a frame-serving datasource")
        #expect(PanelSeries.breakdown(metric: .modelBreakdown,
                                      panel: panel(.modelBreakdown, .pieChart),
                                      frames: nil, data: data).first?.label == "opus")
        #expect(PanelSeries.chartPoints(metric: .tokensByModel,
                                        panel: panel(.tokensByModel, .timeSeries),
                                        frames: nil, data: data,
                                        hidden: []).count == 1)
    }
}
