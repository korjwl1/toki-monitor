import Foundation

// MARK: - Report Period (legacy, used by queryAllSummaries)

enum ReportPeriod: String, CaseIterable {
    case daily, weekly, monthly

    var displayName: String {
        switch self {
        case .daily: L.tr("일간", "Daily")
        case .weekly: L.tr("주간", "Weekly")
        case .monthly: L.tr("월간", "Monthly")
        }
    }

    var subcommand: String { rawValue }

    var sinceDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let date: Date
        switch self {
        case .daily: date = Date()
        case .weekly: date = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        case .monthly: date = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        }
        return formatter.string(from: date)
    }
}

// MARK: - Time Range

enum DashboardTimeRange: String, CaseIterable, Identifiable {
    case sixHours
    case twelveHours
    case twentyFourHours
    case sevenDays
    case fourteenDays
    case thirtyDays

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sixHours: L.enumStr.sixHours
        case .twelveHours: L.enumStr.twelveHours
        case .twentyFourHours: L.enumStr.twentyFourHours
        case .sevenDays: L.enumStr.sevenDays
        case .fourteenDays: L.enumStr.fourteenDays
        case .thirtyDays: L.enumStr.thirtyDays
        }
    }

    var granularity: TimeSeriesGranularity {
        switch self {
        case .sixHours, .twelveHours, .twentyFourHours: .hourly
        case .sevenDays, .fourteenDays, .thirtyDays: .daily
        }
    }

    var subcommand: String {
        granularity == .daily ? "daily" : "hourly"
    }

    var duration: TimeInterval {
        switch self {
        case .sixHours: 6 * 3600
        case .twelveHours: 12 * 3600
        case .twentyFourHours: 24 * 3600
        case .sevenDays: 7 * 86400
        case .fourteenDays: 14 * 86400
        case .thirtyDays: 30 * 86400
        }
    }

    var sinceDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let date = Date().addingTimeInterval(-duration)
        return formatter.string(from: date)
    }
}

enum TimeSeriesGranularity {
    case oneMinute       // 1m
    case fiveMinute      // 5m
    case fifteenMinute   // 15m
    case thirtyMinute    // 30m
    case hourly          // 1h
    case threeHour       // 3h
    case sixHour         // 6h
    case daily           // 1d

    var stepInterval: TimeInterval {
        switch self {
        case .oneMinute: 60
        case .fiveMinute: 300
        case .fifteenMinute: 900
        case .thirtyMinute: 1800
        case .hourly: 3600
        case .threeHour: 10800
        case .sixHour: 21600
        case .daily: 86400
        }
    }

    var bucket: String {
        switch self {
        case .oneMinute: "1m"
        case .fiveMinute: "5m"
        case .fifteenMinute: "15m"
        case .thirtyMinute: "30m"
        case .hourly: "1h"
        case .threeHour: "3h"
        case .sixHour: "6h"
        case .daily: "1d"
        }
    }
}

// MARK: - Time Series Data

struct TimeSeriesPoint: Identifiable {
    let id = UUID()
    let date: Date
    var models: [TokiModelSummary]
    let modelIndex: [String: TokiModelSummary]

    init(date: Date, models: [TokiModelSummary]) {
        self.date = date
        self.models = models
        self.modelIndex = Dictionary(models.map { ($0.model, $0) }, uniquingKeysWith: { _, new in new })
    }

    var totalTokens: UInt64 {
        models.reduce(0) { $0 + $1.totalTokens }
    }

    var totalCost: Double {
        models.compactMap(\.costUsd).reduce(0, +)
    }

    var totalEvents: Int {
        models.reduce(0) { $0 + $1.events }
    }
}

struct TimeSeriesData {
    let points: [TimeSeriesPoint]
    let granularity: TimeSeriesGranularity
    let allModelNames: [String]
    let topModel: String?
    let totalTokens: UInt64
    let totalCost: Double
    let totalEvents: Int

    init(points: [TimeSeriesPoint], granularity: TimeSeriesGranularity) {
        self.points = points
        self.granularity = granularity

        var names = Set<String>()
        var modelTokens: [String: UInt64] = [:]
        var tokens: UInt64 = 0
        var cost: Double = 0
        var events: Int = 0

        for point in points {
            tokens += point.totalTokens
            cost += point.totalCost
            events += point.totalEvents
            for m in point.models {
                names.insert(m.model)
                modelTokens[m.model, default: 0] += m.totalTokens
            }
        }

        self.allModelNames = names.sorted()
        self.topModel = modelTokens.max(by: { $0.value < $1.value })?.key
        self.totalTokens = tokens
        self.totalCost = cost
        self.totalEvents = events
    }

    struct ChartPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    func chartPoints(for model: String, extracting value: (TokiModelSummary) -> Double) -> [ChartPoint] {
        points.map { point in
            let v = point.modelIndex[model].map(value) ?? 0
            return ChartPoint(date: point.date, value: v)
        }
    }

    func tokensFor(model: String) -> [ChartPoint] { chartPoints(for: model) { Double($0.totalTokens) } }
    func costFor(model: String) -> [ChartPoint] { chartPoints(for: model) { $0.costUsd ?? 0 } }
    func eventsFor(model: String) -> [ChartPoint] { chartPoints(for: model) { Double($0.events) } }
}

// MARK: - Per-Panel Data State

enum PanelDataState {
    case idle
    case loading
    case loaded(TimeSeriesData)
    case error(String)

    var timeSeriesData: TimeSeriesData? {
        if case .loaded(let data) = self { return data }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var isEmpty: Bool {
        guard let data = timeSeriesData else { return true }
        return data.points.isEmpty || data.allModelNames.isEmpty
    }
}
