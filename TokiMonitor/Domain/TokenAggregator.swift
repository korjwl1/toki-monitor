import Foundation

enum TimeRange: String, CaseIterable, Codable {
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case today = "today"

    var displayName: String {
        switch self {
        case .thirtyMinutes: "30분"
        case .oneHour: "1시간"
        case .today: "오늘"
        }
    }

    var queryBucket: String {
        switch self {
        case .thirtyMinutes: "1h"
        case .oneHour: "1h"
        case .today: "1d"
        }
    }
}

/// Aggregates token events for rate calculation and sparkline history.
/// Keeps raw events and re-bins on demand — no data loss when changing time range.
@MainActor
@Observable
final class TokenAggregator {
    private(set) var tokensPerMinute: Double = 0
    private(set) var recentHistory: [Double] = []
    private(set) var providerSummaries: [ProviderSummary] = []
    private(set) var totalSummary: TotalSummary?
    private(set) var perProviderRates: [String: Double] = [:]
    private(set) var perProviderHistory: [String: [Double]] = [:]

    private var allEvents: [TokenEvent] = []
    /// Raw rate events with timestamps — kept for the full graph time range for re-binning.
    private var rateEvents: [(date: Date, tokens: UInt64, providerId: String)] = []
    private let rateWindow: TimeInterval = 30
    private let historyBins = 30
    private var refreshTimer: Timer?

    var timeRange: TimeRange = .oneHour
    var graphTimeRange: GraphTimeRange = .oneHourGraph {
        didSet {
            // No data loss — just rebuild from raw events
            rebuildHistory()
            restartRefreshTimer()
        }
    }

    /// Call when a new token event arrives.
    func addEvent(_ event: TokenEvent) {
        let total = event.inputTokens + event.outputTokens
        let provider = ProviderRegistry.resolve(model: event.model)
        rateEvents.append((date: event.receivedAt, tokens: total, providerId: provider.id))
        allEvents.append(event)
        pruneRateEvents()
        recalculateRate()
        rebuildHistory()
        recalculateProviderSummaries()
    }

    /// Start periodic refresh for sparkline history (recalculates bins from raw data).
    func startSampling() {
        restartRefreshTimer()
    }

    func stopSampling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Rate Calculation

    private func recalculateRate() {
        let cutoff = Date().addingTimeInterval(-rateWindow)
        let recentTokens = rateEvents.filter { $0.date >= cutoff }
        let totalTokens = recentTokens.reduce(UInt64(0)) { $0 + $1.tokens }
        let minutes = rateWindow / 60.0
        tokensPerMinute = Double(totalTokens) / minutes

        // Per-provider rates
        var providerTotals: [String: UInt64] = [:]
        for e in recentTokens {
            providerTotals[e.providerId, default: 0] += e.tokens
        }
        perProviderRates = providerTotals.mapValues { Double($0) / minutes }
    }

    // MARK: - History (re-binnable from raw events)

    /// Rebuild sparkline history by binning raw events into time slots.
    /// Called on every event and on timer tick — no sampling artifacts.
    private func rebuildHistory() {
        let now = Date()
        let totalDuration = Double(historyBins) * graphTimeRange.sampleInterval
        let binWidth = graphTimeRange.sampleInterval

        // Only consider events within the graph time window
        let windowStart = now.addingTimeInterval(-totalDuration)
        let relevantEvents = rateEvents.filter { $0.date >= windowStart }

        // Build per-bin token rates
        var globalBins = [Double](repeating: 0, count: historyBins)
        var providerBins: [String: [Double]] = [:]

        for event in relevantEvents {
            let age = now.timeIntervalSince(event.date)
            let binIndex = historyBins - 1 - Int(age / binWidth)
            guard binIndex >= 0 && binIndex < historyBins else { continue }

            // Convert to tokens/minute for this bin
            let rateContribution = Double(event.tokens) / (binWidth / 60.0)
            globalBins[binIndex] += rateContribution

            if providerBins[event.providerId] == nil {
                providerBins[event.providerId] = [Double](repeating: 0, count: historyBins)
            }
            providerBins[event.providerId]?[binIndex] += rateContribution
        }

        recentHistory = globalBins
        perProviderHistory = providerBins
    }

    private func restartRefreshTimer() {
        refreshTimer?.invalidate()
        // Refresh at the bin interval rate, but at least every 2 seconds
        let interval = min(graphTimeRange.sampleInterval, 2.0)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pruneRateEvents()
                self?.recalculateRate()
                self?.rebuildHistory()
            }
        }
    }

    /// Keep rate events for the full graph window + some buffer.
    private func pruneRateEvents() {
        let maxDuration = Double(historyBins) * graphTimeRange.sampleInterval + 60
        let cutoff = Date().addingTimeInterval(-maxDuration)
        rateEvents.removeAll { $0.date < cutoff }
    }

    // MARK: - Provider Summaries

    private func recalculateProviderSummaries() {
        pruneAllEvents()
        let cutoff = timeRangeCutoff()
        let filtered = allEvents.filter { $0.receivedAt >= cutoff }

        var map: [String: ProviderSummary] = [:]
        for event in filtered {
            let provider = ProviderRegistry.resolve(model: event.model)
            if map[provider.id] == nil {
                map[provider.id] = ProviderSummary(provider: provider)
            }
            map[provider.id]?.add(event: event)
        }

        providerSummaries = map.values.sorted { $0.totalTokens > $1.totalTokens }
        totalSummary = providerSummaries.count >= 2 ? TotalSummary(from: providerSummaries) : nil
    }

    private func timeRangeCutoff() -> Date {
        switch timeRange {
        case .thirtyMinutes:
            return Date().addingTimeInterval(-30 * 60)
        case .oneHour:
            return Date().addingTimeInterval(-60 * 60)
        case .today:
            return Calendar.current.startOfDay(for: Date())
        }
    }

    private func pruneAllEvents() {
        let cutoff = timeRangeCutoff()
        allEvents.removeAll { $0.receivedAt < cutoff }
    }
}
