import Foundation

enum TimeRange: String, CaseIterable, Codable {
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case today = "today"

    var displayName: String {
        switch self {
        case .thirtyMinutes: L.enumStr.halfHour
        case .oneHour: L.enumStr.oneHour
        case .today: L.enumStr.today
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

/// Two data sources:
/// - **trace (UDS)**: real-time → `tokensPerMinute` for animation
/// - **report (PromQL)**: periodic re-fetch → sparklines, summaries
@MainActor
@Observable
final class TokenAggregator {
    // MARK: - Real-time (trace)

    private(set) var tokensPerMinute: Double = 0
    private(set) var perProviderRates: [String: Double] = [:]
    /// Active session count per provider (unique sources in rate window).
    private(set) var perProviderSessionCount: [String: Int] = [:]

    // MARK: - PromQL data

    private(set) var recentHistory: [Double] = []
    private(set) var perProviderHistory: [String: [Double]] = [:]
    private(set) var providerSummaries: [ProviderSummary] = []
    private(set) var totalSummary: TotalSummary?

    // MARK: - Config

    var timeRange: TimeRange = .oneHour
    var graphTimeRange: GraphTimeRange = .oneHourGraph {
        didSet {
            if oldValue != graphTimeRange { fetchReportData() }
        }
    }

    // MARK: - Private

    private var traceEvents: [(date: Date, tokens: UInt64, providerId: String, source: String)] = []
    private let rateWindow: TimeInterval = 30
    private let historyBins = 30
    private var rateTimer: Timer?
    private var reportTimer: Timer?
    private let reportClient = TokiReportClient()
    private let reportRefreshInterval: TimeInterval = 10

    // Timers are cleaned up via stopSampling(), called by StatusBarController's sleep handler.

    // MARK: - Trace Events

    func addEvent(_ event: TokenEvent) {
        let total = event.inputTokens + event.outputTokens
        let provider = ProviderRegistry.resolve(model: event.model)
        traceEvents.append((date: event.receivedAt, tokens: total, providerId: provider.id, source: event.source))
        pruneTraceEvents()
        recalculateRate()
    }

    // MARK: - Start/Stop

    func startSampling() {
        rateTimer?.invalidate()
        rateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pruneTraceEvents()
                self?.recalculateRate()
            }
        }

        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(withTimeInterval: reportRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchReportData()
            }
        }

        fetchReportData()
    }

    func stopSampling() {
        rateTimer?.invalidate()
        rateTimer = nil
        reportTimer?.invalidate()
        reportTimer = nil
    }

    // MARK: - Rate (trace, 30s window)

    private func pruneTraceEvents() {
        let cutoff = Date().addingTimeInterval(-rateWindow - 5)
        traceEvents.removeAll { $0.date < cutoff }
    }

    private func recalculateRate() {
        let cutoff = Date().addingTimeInterval(-rateWindow)
        let recent = traceEvents.filter { $0.date >= cutoff }
        let totalTokens = recent.reduce(UInt64(0)) { $0 + $1.tokens }
        let minutes = rateWindow / 60.0
        tokensPerMinute = Double(totalTokens) / minutes

        var providerTotals: [String: UInt64] = [:]
        for e in recent {
            providerTotals[e.providerId, default: 0] += e.tokens
        }
        perProviderRates = providerTotals.mapValues { Double($0) / minutes }

        // Count unique sessions per provider in rate window
        var sessionsByProvider: [String: Set<String>] = [:]
        for e in recent {
            sessionsByProvider[e.providerId, default: []].insert(e.source)
        }
        perProviderSessionCount = sessionsByProvider.mapValues(\.count)
    }

    // MARK: - PromQL Report

    private func fetchReportData() {
        let bucket = graphTimeRange.promqlBucket
        let since = graphTimeRange.sinceTimestamp
        let query = "usage{since=\"\(since)\"}[\(bucket)] by (model)"

        Task {
            guard let pointsByDate = try? await reportClient.queryPromQL(query: query) else { return }
            self.buildBins(from: pointsByDate)
            self.buildSummaries(from: pointsByDate)
        }
    }

    private func buildBins(from pointsByDate: [Date: [TokiModelSummary]]) {
        let now = Date()
        let binWidth = graphTimeRange.sampleInterval
        let totalDuration = Double(historyBins) * binWidth
        let windowStart = now.addingTimeInterval(-totalDuration)

        var globalBins = [Double](repeating: 0, count: historyBins)
        var providerBins: [String: [Double]] = [:]

        for (date, models) in pointsByDate {
            guard date >= windowStart else { continue }
            let age = now.timeIntervalSince(date)
            let binIndex = historyBins - 1 - Int(age / binWidth)
            guard binIndex >= 0 && binIndex < historyBins else { continue }

            for model in models {
                let rate = Double(model.totalTokens) / (binWidth / 60.0)
                globalBins[binIndex] += rate

                let pid = ProviderRegistry.resolve(model: model.model).id
                if providerBins[pid] == nil {
                    providerBins[pid] = [Double](repeating: 0, count: historyBins)
                }
                providerBins[pid]?[binIndex] += rate
            }
        }

        recentHistory = globalBins
        perProviderHistory = providerBins
    }

    private func buildSummaries(from pointsByDate: [Date: [TokiModelSummary]]) {
        let cutoff = timeRangeCutoff()
        var map: [String: ProviderSummary] = [:]

        for (date, models) in pointsByDate {
            guard date >= cutoff else { continue }
            for model in models {
                let provider = ProviderRegistry.resolve(model: model.model)
                if map[provider.id] == nil {
                    map[provider.id] = ProviderSummary(provider: provider)
                }
                map[provider.id]?.addSummary(model)
            }
        }

        providerSummaries = map.values.sorted { $0.totalTokens > $1.totalTokens }
        totalSummary = providerSummaries.count >= 2 ? TotalSummary(from: providerSummaries) : nil
    }

    private func timeRangeCutoff() -> Date {
        switch timeRange {
        case .thirtyMinutes: Date().addingTimeInterval(-30 * 60)
        case .oneHour: Date().addingTimeInterval(-60 * 60)
        case .today: Calendar.current.startOfDay(for: Date())
        }
    }
}
