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

    /// toki query bucket string.
    var queryBucket: String {
        switch self {
        case .thirtyMinutes: "1h"  // toki doesn't have 30m bucket, use 1h
        case .oneHour: "1h"
        case .today: "1d"
        }
    }
}

/// Aggregates token events for rate calculation and recent history.
@MainActor
@Observable
final class TokenAggregator {
    private(set) var tokensPerMinute: Double = 0
    private(set) var recentHistory: [Double] = []  // last N rate samples for sparkline
    private(set) var providerSummaries: [ProviderSummary] = []
    private(set) var totalSummary: TotalSummary?

    // Per-provider rates and history for perProvider display mode
    private(set) var perProviderRates: [String: Double] = [:]
    private(set) var perProviderHistory: [String: [Double]] = [:]

    private var allEvents: [TokenEvent] = []
    private var events: [(date: Date, tokens: UInt64, providerId: String)] = []
    private let rateWindow: TimeInterval = 30  // seconds for rate calc
    private let historySize = 30  // number of sparkline data points
    private var sampleTimer: Timer?
    var timeRange: TimeRange = .oneHour

    var graphTimeRange: GraphTimeRange = .oneMinute {
        didSet {
            if oldValue != graphTimeRange {
                recentHistory = []
                perProviderHistory = [:]
                restartSampling()
            }
        }
    }

    /// Call when a new token event arrives.
    func addEvent(_ event: TokenEvent) {
        let total = event.inputTokens + event.outputTokens
        let provider = ProviderRegistry.resolve(model: event.model)
        events.append((date: event.receivedAt, tokens: total, providerId: provider.id))
        allEvents.append(event)
        pruneOldEvents()
        recalculateRate()
        recalculateProviderSummaries()
    }

    /// Start periodic sampling for sparkline history.
    func startSampling() {
        sampleTimer?.invalidate()
        let interval = graphTimeRange.sampleInterval
        sampleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleRate()
            }
        }
    }

    func stopSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
    }

    // MARK: - Private

    private func restartSampling() {
        stopSampling()
        startSampling()
    }

    private func pruneOldEvents() {
        let cutoff = Date().addingTimeInterval(-rateWindow)
        events.removeAll { $0.date < cutoff }
    }

    private func recalculateRate() {
        pruneOldEvents()
        let totalTokens = events.reduce(UInt64(0)) { $0 + $1.tokens }
        let minutes = rateWindow / 60.0
        tokensPerMinute = Double(totalTokens) / minutes

        // Per-provider rates
        var providerTotals: [String: UInt64] = [:]
        for e in events {
            providerTotals[e.providerId, default: 0] += e.tokens
        }
        var newRates: [String: Double] = [:]
        for (pid, total) in providerTotals {
            newRates[pid] = Double(total) / minutes
        }
        perProviderRates = newRates
    }

    private func sampleRate() {
        recalculateRate()

        // Global history
        recentHistory.append(tokensPerMinute)
        if recentHistory.count > historySize {
            recentHistory.removeFirst(recentHistory.count - historySize)
        }

        // Per-provider history
        let allProviderIds = Set(perProviderRates.keys).union(perProviderHistory.keys)
        for pid in allProviderIds {
            let rate = perProviderRates[pid] ?? 0
            var history = perProviderHistory[pid] ?? []
            history.append(rate)
            if history.count > historySize {
                history.removeFirst(history.count - historySize)
            }
            perProviderHistory[pid] = history
        }
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

    /// Prune allEvents older than the current time range to prevent unbounded growth.
    private func pruneAllEvents() {
        let cutoff = timeRangeCutoff()
        allEvents.removeAll { $0.receivedAt < cutoff }
    }
}
