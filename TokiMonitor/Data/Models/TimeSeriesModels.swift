import Foundation

// MARK: - Report Period (legacy, used by queryAllSummaries)

enum ReportPeriod: String, CaseIterable {
    case daily, weekly, monthly

    var displayName: String {
        switch self {
        case .daily: "일간"
        case .weekly: "주간"
        case .monthly: "월간"
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
        granularity == .hourly ? "hourly" : "daily"
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
    case hourly, daily

    var stepInterval: TimeInterval {
        switch self {
        case .hourly: 3600
        case .daily: 86400
        }
    }
}

// MARK: - Time Series Data

struct TimeSeriesPoint: Identifiable {
    let id = UUID()
    let date: Date
    var models: [TokiModelSummary]

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

    var allModelNames: [String] {
        var names = Set<String>()
        for point in points {
            for model in point.models {
                names.insert(model.model)
            }
        }
        return names.sorted()
    }

    struct ChartPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    func tokensFor(model: String) -> [ChartPoint] {
        points.map { point in
            let tokens = point.models.first { $0.model == model }?.totalTokens ?? 0
            return ChartPoint(date: point.date, value: Double(tokens))
        }
    }

    func costFor(model: String) -> [ChartPoint] {
        points.map { point in
            let cost = point.models.first { $0.model == model }?.costUsd ?? 0
            return ChartPoint(date: point.date, value: cost)
        }
    }

    func eventsFor(model: String) -> [ChartPoint] {
        points.map { point in
            let events = point.models.first { $0.model == model }?.events ?? 0
            return ChartPoint(date: point.date, value: Double(events))
        }
    }

    /// Summary stats across all points
    var totalTokens: UInt64 { points.reduce(0) { $0 + $1.totalTokens } }
    var totalCost: Double { points.reduce(0) { $0 + $1.totalCost } }
    var totalEvents: Int { points.reduce(0) { $0 + $1.totalEvents } }

    var topModel: String? {
        var modelTokens: [String: UInt64] = [:]
        for point in points {
            for m in point.models {
                modelTokens[m.model, default: 0] += m.totalTokens
            }
        }
        return modelTokens.max(by: { $0.value < $1.value })?.key
    }
}
