import Foundation

/// Extracts display-ready values from TimeSeriesData for panel rendering.
/// Stateless — takes data in, returns display values. No ViewModel dependency.
@MainActor
enum PanelDataExtractor {

    // MARK: - Stat Panel Output

    struct StatValue {
        let value: String
        let subtitle: String?
    }

    static func statValue(
        for metric: PanelMetric,
        data: TimeSeriesData?
    ) -> StatValue {
        guard let data else { return StatValue(value: "-", subtitle: nil) }
        switch metric {
        case .totalTokens:
            return StatValue(value: TokenFormatter.formatTokens(data.totalTokens), subtitle: nil)
        case .totalCost:
            return StatValue(value: TokenFormatter.formatCost(data.totalCost), subtitle: nil)
        case .apiCalls:
            return StatValue(value: "\(data.totalEvents)", subtitle: nil)
        case .topModel:
            return StatValue(value: data.topModel ?? "-", subtitle: nil)
        case .cacheHitRate:
            let rate = computeCacheHitRate(from: data)
            return StatValue(value: String(format: "%.1f%%", rate * 100), subtitle: nil)
        case .reasoningTokens:
            let total = computeReasoningTokens(from: data)
            return StatValue(value: TokenFormatter.formatTokens(total), subtitle: nil)
        default:
            return StatValue(value: "-", subtitle: nil)
        }
    }

    // MARK: - Time Series Output

    static func chartPoints(
        for metric: PanelMetric,
        model: String,
        data: TimeSeriesData?
    ) -> [TimeSeriesData.ChartPoint] {
        guard let data else { return [] }
        switch metric {
        case .tokensByModel, .totalTokens:
            return data.tokensFor(model: model)
        case .costByModel, .totalCost:
            return data.costFor(model: model)
        case .eventsByModel, .apiCalls:
            return data.eventsFor(model: model)
        case .inputVsOutput:
            return data.tokensFor(model: model)
        default:
            return []
        }
    }

    /// Returns chart point arrays keyed by model name for all enabled models.
    static func allModelChartPoints(
        for metric: PanelMetric,
        enabledModels: Set<String>,
        data: TimeSeriesData?
    ) -> [(model: String, points: [TimeSeriesData.ChartPoint])] {
        guard let data else { return [] }
        let filtered = data.allModelNames.filter { enabledModels.contains($0) }
        return filtered.map { model in
            (model: model, points: chartPoints(for: metric, model: model, data: data))
        }
    }

    // MARK: - Table Output

    struct ModelRow: Identifiable {
        let id: String
        let model: String
        let tokens: UInt64
        let cost: Double
        let events: Int
    }

    static func tableRows(from data: TimeSeriesData?) -> [ModelRow] {
        guard let data else { return [] }
        var aggregated: [String: (tokens: UInt64, cost: Double, events: Int)] = [:]

        for point in data.points {
            for model in point.models {
                var entry = aggregated[model.model, default: (0, 0, 0)]
                entry.tokens += model.totalTokens
                entry.cost += model.costUsd ?? 0
                entry.events += model.events
                aggregated[model.model] = entry
            }
        }

        return aggregated.map { key, val in
            ModelRow(id: key, model: key, tokens: val.tokens, cost: val.cost, events: val.events)
        }.sorted { $0.tokens > $1.tokens }
    }

    // MARK: - Project Breakdown

    static func projectBreakdown(from data: TimeSeriesData?) -> [(project: String, tokens: UInt64)] {
        guard let data else { return [] }
        var totals: [String: UInt64] = [:]
        for point in data.points {
            for model in point.models {
                totals[model.model, default: 0] += model.totalTokens
            }
        }
        return totals
            .map { (project: DashboardViewModel.cleanProjectName($0.key), tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }
    }

    // MARK: - Helpers

    private static func computeCacheHitRate(from data: TimeSeriesData?) -> Double {
        guard let data else { return 0 }
        var totalInput: UInt64 = 0
        var totalCacheRead: UInt64 = 0
        for point in data.points {
            for model in point.models {
                totalInput += model.inputTokens
                totalCacheRead += model.cacheReadInputTokens ?? 0
                totalCacheRead += model.cachedInputTokens ?? 0
            }
        }
        guard totalInput > 0 else { return 0 }
        return Double(totalCacheRead) / Double(totalInput)
    }

    private static func computeReasoningTokens(from data: TimeSeriesData?) -> UInt64 {
        guard let data else { return 0 }
        var total: UInt64 = 0
        for point in data.points {
            for model in point.models {
                total += model.reasoningOutputTokens ?? 0
            }
        }
        return total
    }
}
