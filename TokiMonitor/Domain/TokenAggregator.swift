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

/// Two data sources:
/// - **trace (UDS)**: real-time → `tokensPerMinute` for animation
/// - **report (PromQL)**: periodic re-fetch → sparklines, summaries
///
/// No client-side binning or overlay. Just fetch fresh data every N seconds.
@MainActor
@Observable
final class TokenAggregator {
    // MARK: - Real-time (trace only)

    private(set) var tokensPerMinute: Double = 0
    private(set) var perProviderRates: [String: Double] = [:]

    // MARK: - PromQL data (refreshed periodically)

    /// Sparkline bins for menu bar graph and dropdown charts.
    private(set) var recentHistory: [Double] = []
    /// Per-provider sparkline bins.
    private(set) var perProviderHistory: [String: [Double]] = [:]
    /// Provider summaries.
    private(set) var providerSummaries: [ProviderSummary] = []
    private(set) var totalSummary: TotalSummary?

    // MARK: - Config

    var timeRange: TimeRange = .oneHour
    var graphTimeRange: GraphTimeRange = .oneHourGraph {
        didSet {
            if oldValue != graphTimeRange {
                fetchReportData()
            }
        }
    }

    // MARK: - Private

    private var traceEvents: [(date: Date, tokens: UInt64, providerId: String)] = []
    private let rateWindow: TimeInterval = 30
    private let historyBins = 30
    private var rateTimer: Timer?
    private var reportTimer: Timer?
    private let reportClient = TokiReportClient()

    /// UI refresh interval — how often to re-fetch PromQL data.
    private let reportRefreshInterval: TimeInterval = 10

    // MARK: - Trace Events

    func addEvent(_ event: TokenEvent) {
        let total = event.inputTokens + event.outputTokens
        let provider = ProviderRegistry.resolve(model: event.model)
        traceEvents.append((date: event.receivedAt, tokens: total, providerId: provider.id))
        pruneTraceEvents()
        recalculateRate()
    }

    // MARK: - Start/Stop

    func startSampling() {
        // Rate recalc every 2s for animation
        rateTimer?.invalidate()
        rateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pruneTraceEvents()
                self?.recalculateRate()
            }
        }

        // PromQL re-fetch every 10s for charts
        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(withTimeInterval: reportRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchReportData()
            }
        }

        // Immediate first fetch
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
    }

    // MARK: - PromQL Fetch

    private func fetchReportData() {
        let bucket = graphTimeRange.promqlBucket
        let since = graphTimeRange.sinceTimestamp
        let reportOptions: [String] = ["-z", "UTC"]
        let query = "usage{since=\"\(since)\"}[\(bucket)] by (model)"
        let subcommandArgs: [String] = ["query", query]

        reportClient.runner.runReport(reportOptions: reportOptions, subcommandArgs: subcommandArgs) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .success(let data) = result {
                    self.parseAndApply(data)
                }
            }
        }
    }

    private func parseAndApply(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        let jsonText = text.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("[toki]") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let decoder = JSONDecoder()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")

        var pointsByDate: [Date: [TokiModelSummary]] = [:]

        if let jsonData = jsonText.data(using: .utf8),
           let report = try? decoder.decode(TokiReportV2.self, from: jsonData) {
            for (_, entries) in report.providers {
                parseEntries(entries, into: &pointsByDate, formatter: fmt)
            }
        } else {
            for jsonStr in splitJsonObjects(jsonText) {
                guard let jsonData = jsonStr.data(using: .utf8),
                      let report = try? decoder.decode(TokiCliReportLegacy.self, from: jsonData)
                else { continue }
                parseEntries(report.data, into: &pointsByDate, formatter: fmt)
            }
        }

        buildBins(from: pointsByDate)
        buildSummaries(from: pointsByDate)
    }

    private func parseEntries(
        _ entries: [TokiCliEntry],
        into pointsByDate: inout [Date: [TokiModelSummary]],
        formatter: DateFormatter
    ) {
        for entry in entries {
            guard let periodStr = entry.period, let models = entry.usagePerModels else { continue }
            let dateStr = periodStr.contains("|")
                ? String(periodStr[..<periodStr.firstIndex(of: "|")!])
                : periodStr

            var date: Date?
            for f in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
                formatter.dateFormat = f
                if let d = formatter.date(from: dateStr) { date = d; break }
            }
            guard let d = date else { continue }
            pointsByDate[d, default: []].append(contentsOf: models)
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

    private func splitJsonObjects(_ text: String) -> [String] {
        var objects: [String] = []
        var depth = 0
        var start = text.startIndex
        for i in text.indices {
            if text[i] == "{" { depth += 1 }
            if text[i] == "}" {
                depth -= 1
                if depth == 0 {
                    objects.append(String(text[start...i]))
                    let next = text.index(after: i)
                    if next < text.endIndex { start = next }
                }
            }
        }
        return objects
    }
}

// MARK: - JSON types (shared with TokiReportClient)

struct TokiReportV2: Codable {
    let information: TokiReportInfo?
    let providers: [String: [TokiCliEntry]]
}

struct TokiReportInfo: Codable {
    let type: String?
    let since: String?
    let until: String?
    let timezone: String?
}

struct TokiCliEntry: Codable {
    let period: String?
    let session: String?
    let usagePerModels: [TokiModelSummary]?

    enum CodingKeys: String, CodingKey {
        case period, session
        case usagePerModels = "usage_per_models"
    }
}

struct TokiCliReportLegacy: Codable {
    let data: [TokiCliEntry]
    let type: String?
}
