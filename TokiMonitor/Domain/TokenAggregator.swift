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
    private(set) var perProviderCostPerMinute: [String: Double] = [:]
    /// Active session count per provider (unique sources in rate window).
    private(set) var perProviderSessionCount: [String: Int] = [:]

    // MARK: - Anomaly Detection

    enum SpendAlert: Equatable {
        case normal
        case elevated   // above historical average
        case critical   // velocity threshold exceeded
    }

    private(set) var spendAlert: SpendAlert = .normal
    private(set) var perProviderSpendAlerts: [String: SpendAlert] = [:]
    /// Cost per minute in current rate window.
    private(set) var costPerMinute: Double = 0
    /// Historical average cost per minute (from 24h PromQL query).
    private(set) var historicalAvgCostPerMinute: Double?
    /// Settings reference for thresholds.
    weak var settings: AppSettings?

    // MARK: - PromQL data

    private(set) var recentHistory: [Double] = []
    private(set) var perProviderHistory: [String: [Double]] = [:]
    private(set) var providerSummaries: [ProviderSummary] = []
    private var isFetchingReport = false
    private(set) var totalSummary: TotalSummary?

    // MARK: - Config

    var timeRange: TimeRange = .oneHour
    var graphTimeRange: GraphTimeRange = .oneHourGraph {
        didSet {
            if oldValue != graphTimeRange { fetchReportData() }
        }
    }

    // MARK: - Private

    private var traceEvents: [(date: Date, tokens: UInt64, cost: Double, providerId: String, source: String)] = []
    private let rateWindow: TimeInterval = 30   // Window for session counting + event pruning
    private let historyBins = 30
    private var rateTimer: Timer?

    // EMA (Exponential Moving Average) for smooth rate transitions.
    // Instead of flat window average (which creates cliffs when events exit the window),
    // EMA blends each second's measurement with the previous rate:
    //   rate = alpha × instant_rate + (1 - alpha) × prev_rate
    // This gives natural ramp-up (~3s to 90%) and gradual decay (no sudden drop to 0).
    private let emaAlpha: Double = 0.3  // Smoothing factor (0.3 = responsive yet smooth)
    private var lastTickTime: Date = Date()
    private var tokensSinceLastTick: UInt64 = 0
    private var costSinceLastTick: Double = 0
    private var providerTokensSinceLastTick: [String: UInt64] = [:]
    private var providerCostSinceLastTick: [String: Double] = [:]
    private var reportTimer: Timer?
    private let reportClient = TokiReportClient()
    private let reportRefreshInterval: TimeInterval = 10

    // Timers are cleaned up via stopSampling(), called by StatusBarController's sleep handler.

    // MARK: - Trace Events

    func addEvent(_ event: TokenEvent) {
        let total = event.totalTokens
        let cost = event.costUSD ?? 0
        let provider = ProviderRegistry.resolve(model: event.model)
        traceEvents.append((date: event.receivedAt, tokens: total, cost: cost, providerId: provider.id, source: event.source))

        // Accumulate for next EMA tick
        tokensSinceLastTick += total
        costSinceLastTick += cost
        providerTokensSinceLastTick[provider.id, default: 0] += total
        providerCostSinceLastTick[provider.id, default: 0] += cost
    }

    // MARK: - Start/Stop

    func startSampling() {
        lastTickTime = Date()
        rateTimer?.invalidate()
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.emaTick()
                self?.pruneTraceEvents()
                self?.recalculateSessionCounts()
            }
        }

        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(withTimeInterval: reportRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchReportData()
            }
        }

        fetchReportData()
        fetchHistoricalBaseline()
    }

    func stopSampling() {
        rateTimer?.invalidate()
        rateTimer = nil
        reportTimer?.invalidate()
        reportTimer = nil
    }

    // MARK: - Historical Baseline (Level 2)

    private func fetchHistoricalBaseline() {
        Task { [weak self] in
            guard let self else { return }
            // Instant query: the [1h] range vector scans last 1 hour per bucket over full DB.
            // For historical baseline we want 24h of 1h buckets.
            let sinceFmt = DateFormatter()
            sinceFmt.dateFormat = "yyyyMMddHHmmss"
            sinceFmt.timeZone = TimeZone(identifier: "UTC")
            let sinceStr = sinceFmt.string(from: Date().addingTimeInterval(-86400)) // 24h ago
            let query = "usage[1h] by (model)"

            guard let pointsByDate = try? await self.reportClient.queryPromQL(query: query, since: sinceStr) else { return }

            // Sum total cost across all points
            var totalCost: Double = 0
            for (_, models) in pointsByDate {
                for m in models {
                    totalCost += m.costUsd ?? 0
                }
            }

            // Average cost per minute over 24h
            self.historicalAvgCostPerMinute = totalCost / (24 * 60)
        }
    }

    // MARK: - Rate (EMA-based)

    private func pruneTraceEvents() {
        let cutoff = Date().addingTimeInterval(-rateWindow - 5)
        traceEvents.removeAll { $0.date < cutoff }
    }

    /// EMA tick: blend this second's instantaneous rate with previous EMA value.
    /// Called every 1 second by rateTimer.
    private func emaTick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTickTime)
        guard dt > 0 else { return }
        lastTickTime = now

        // Instantaneous rate for this tick (extrapolated to per-minute)
        let instantTokensPerMin = Double(tokensSinceLastTick) * (60.0 / dt)
        let instantCostPerMin = costSinceLastTick * (60.0 / dt)

        // EMA blend: responsive ramp-up, smooth decay
        tokensPerMinute = emaAlpha * instantTokensPerMin + (1 - emaAlpha) * tokensPerMinute
        costPerMinute = emaAlpha * instantCostPerMin + (1 - emaAlpha) * costPerMinute

        // Per-provider EMA
        var allProviders = Set(providerTokensSinceLastTick.keys)
        allProviders.formUnion(perProviderRates.keys)

        for pid in allProviders {
            let instantTok = Double(providerTokensSinceLastTick[pid] ?? 0) * (60.0 / dt)
            let instantCost = (providerCostSinceLastTick[pid] ?? 0) * (60.0 / dt)
            perProviderRates[pid] = emaAlpha * instantTok + (1 - emaAlpha) * (perProviderRates[pid] ?? 0)
            perProviderCostPerMinute[pid] = emaAlpha * instantCost + (1 - emaAlpha) * (perProviderCostPerMinute[pid] ?? 0)
        }

        // Reset accumulators
        tokensSinceLastTick = 0
        costSinceLastTick = 0
        providerTokensSinceLastTick.removeAll()
        providerCostSinceLastTick.removeAll()

        // Clamp near-zero values to exactly zero (avoid 0.001 tok/m forever)
        if tokensPerMinute < 100 { tokensPerMinute = 0 }
        if costPerMinute < 0.001 { costPerMinute = 0 }
        for (pid, rate) in perProviderRates where rate < 100 {
            perProviderRates[pid] = 0
        }
        for (pid, cost) in perProviderCostPerMinute where cost < 0.001 {
            perProviderCostPerMinute[pid] = 0
        }

        updateSpendAlert()
    }

    /// Session counts still use the window approach (need to see unique sources over time).
    private func recalculateSessionCounts() {
        let cutoff = Date().addingTimeInterval(-rateWindow)
        let recent = traceEvents.filter { $0.date >= cutoff }
        var sessionsByProvider: [String: Set<String>] = [:]
        for e in recent {
            sessionsByProvider[e.providerId, default: []].insert(e.source)
        }
        perProviderSessionCount = sessionsByProvider.mapValues(\.count)
    }

    private var lastAlertCheckTime: Date = .distantPast
    private let alertCheckInterval: TimeInterval = 30

    private func updateSpendAlert() {
        let now = Date()
        guard now.timeIntervalSince(lastAlertCheckTime) >= alertCheckInterval else { return }
        lastAlertCheckTime = now

        guard let s = settings else {
            spendAlert = .normal
            perProviderSpendAlerts = [:]
            return
        }

        // 전역 + 개별 provider 이상 감지가 모두 꺼져있으면 계산 생략
        let anyEnabled = s.velocityAlertEnabled || s.historicalAlertEnabled
            || perProviderCostPerMinute.keys.contains {
                s.effectiveVelocityAlertEnabled(for: $0) || s.effectiveHistoricalAlertEnabled(for: $0)
            }
        guard anyEnabled else {
            if spendAlert != .normal { spendAlert = .normal }
            if !perProviderSpendAlerts.isEmpty { perProviderSpendAlerts = [:] }
            return
        }

        let newAlert: SpendAlert
        if s.velocityAlertEnabled, costPerMinute >= s.velocityThreshold {
            newAlert = .critical
        } else if s.historicalAlertEnabled,
                  let avg = historicalAvgCostPerMinute, avg > 0,
                  costPerMinute > avg * s.historicalMultiplier {
            newAlert = .elevated
        } else {
            newAlert = .normal
        }

        spendAlert = newAlert

        var providerAlerts: [String: SpendAlert] = [:]
        providerAlerts.reserveCapacity(perProviderCostPerMinute.count)
        for (pid, cost) in perProviderCostPerMinute {
            let providerAlert: SpendAlert
            if s.effectiveVelocityAlertEnabled(for: pid),
               cost >= s.effectiveVelocityThreshold(for: pid) {
                providerAlert = .critical
            } else if s.effectiveHistoricalAlertEnabled(for: pid),
                      let avg = historicalAvgCostPerMinute, avg > 0,
                      cost > avg * s.effectiveHistoricalMultiplier(for: pid) {
                providerAlert = .elevated
            } else {
                providerAlert = .normal
            }
            providerAlerts[pid] = providerAlert
        }
        perProviderSpendAlerts = providerAlerts
    }

    // MARK: - PromQL Report

    private func fetchReportData() {
        guard !isFetchingReport else { return }
        isFetchingReport = true

        let bucket = graphTimeRange.promqlBucket
        let sinceStr = graphTimeRange.sinceTimestamp
        let query = "usage[\(bucket)] by (model)"

        Task {
            defer { self.isFetchingReport = false }
            guard let pointsByDate = try? await reportClient.queryPromQL(query: query, since: sinceStr) else { return }
            self.buildBins(from: pointsByDate)
            self.buildSummaries(from: pointsByDate)
        }
    }

    private func buildBins(from pointsByDate: [Date: [TokiModelSummary]]) {
        let now = Date()
        let binWidth = graphTimeRange.sampleInterval
        let totalDuration = Double(historyBins) * binWidth
        let windowStart = now.addingTimeInterval(-totalDuration)
        let rateScale = 1.0 / (binWidth / 60.0)

        var globalBins = [Double](repeating: 0, count: historyBins)
        var providerBins: [String: [Double]] = [:]
        providerBins.reserveCapacity(8)

        for (date, models) in pointsByDate {
            guard date >= windowStart else { continue }
            let binIndex = historyBins - 1 - Int(now.timeIntervalSince(date) / binWidth)
            guard binIndex >= 0 && binIndex < historyBins else { continue }

            for model in models {
                let rate = Double(model.totalTokens) * rateScale
                globalBins[binIndex] += rate

                let pid = ProviderRegistry.resolve(model: model.model).id
                providerBins[pid, default: [Double](repeating: 0, count: historyBins)][binIndex] += rate
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
