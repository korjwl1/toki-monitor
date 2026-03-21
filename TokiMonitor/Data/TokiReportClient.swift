import Foundation

/// Runs `toki report` CLI commands and parses output.
final class TokiReportClient: Sendable {
    private let runner: TokiReportRunner

    init(runner: TokiReportRunner = TokiReportRunner()) {
        self.runner = runner
    }

    /// Flat list of model summaries for a period.
    func queryAllSummaries(
        period: ReportPeriod,
        completion: @escaping @Sendable (Result<[TokiModelSummary], Error>) -> Void
    ) {
        let reportOptions: [String] = ["-z", "UTC"]
        let subcommandArgs: [String] = [period.subcommand, "--since", period.sinceDate]

        runner.runReport(reportOptions: reportOptions, subcommandArgs: subcommandArgs) { result in
            switch result {
            case .success(let data):
                completion(.success(TokiReportParser.parseFlatSummaries(data)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Time-series data for dashboard charts via PromQL.
    func queryTimeSeries(
        timeRange: DashboardTimeRange,
        completion: @escaping @Sendable (Result<TimeSeriesData, Error>) -> Void
    ) {
        let bucket = timeRange.granularity == .hourly ? "1h" : "1d"
        let sinceFmt = DateFormatter()
        sinceFmt.dateFormat = "yyyyMMddHHmmss"
        sinceFmt.timeZone = TimeZone(identifier: "UTC")
        let since = sinceFmt.string(from: Date().addingTimeInterval(-timeRange.duration - 3600))
        let query = "usage{since=\"\(since)\"}[\(bucket)] by (model)"

        let reportOptions: [String] = ["-z", "UTC"]
        let subcommandArgs: [String] = ["query", query]

        runner.runReport(reportOptions: reportOptions, subcommandArgs: subcommandArgs) { result in
            switch result {
            case .success(let data):
                let pointsByDate = TokiReportParser.parseReport(data)
                var points = pointsByDate.map { TimeSeriesPoint(date: $0.key, models: $0.value) }
                    .sorted { $0.date < $1.date }
                points = Self.gapFill(points: points, timeRange: timeRange)
                let tsData = TimeSeriesData(points: points, granularity: timeRange.granularity)
                completion(.success(tsData))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Run a raw PromQL query and return parsed date→models map.
    func queryPromQL(
        query: String,
        completion: @escaping @Sendable (Result<[Date: [TokiModelSummary]], Error>) -> Void
    ) {
        let reportOptions: [String] = ["-z", "UTC"]
        let subcommandArgs: [String] = ["query", query]

        runner.runReport(reportOptions: reportOptions, subcommandArgs: subcommandArgs) { result in
            switch result {
            case .success(let data):
                completion(.success(TokiReportParser.parseReport(data)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Gap Fill

    private static func gapFill(
        points: [TimeSeriesPoint],
        timeRange: DashboardTimeRange
    ) -> [TimeSeriesPoint] {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let now = Date()
        let step = timeRange.granularity.stepInterval
        let start: Date
        if timeRange.granularity == .hourly {
            let c = calendar.dateComponents([.year, .month, .day, .hour], from: now.addingTimeInterval(-timeRange.duration))
            start = calendar.date(from: c) ?? now.addingTimeInterval(-timeRange.duration)
        } else {
            let c = calendar.dateComponents([.year, .month, .day], from: now.addingTimeInterval(-timeRange.duration))
            start = calendar.date(from: c) ?? now.addingTimeInterval(-timeRange.duration)
        }

        let existingDates = Set(points.map(\.date))
        var filled = points
        var current = start
        while current <= now {
            if !existingDates.contains(current) {
                filled.append(TimeSeriesPoint(date: current, models: []))
            }
            current = current.addingTimeInterval(step)
        }
        return filled.sorted { $0.date < $1.date }
    }
}
