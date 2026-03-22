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
        let bucket = timeRange.granularity.bucket
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
                let points = pointsByDate.map { TimeSeriesPoint(date: $0.key, models: $0.value) }
                    .sorted { $0.date < $1.date }
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

    /// Time-series data from TimeConfig (Grafana-style relative time).
    func queryTimeSeriesFromConfig(
        time: TimeConfig,
        completion: @escaping @Sendable (Result<TimeSeriesData, Error>) -> Void
    ) {
        let bucket = time.bucketString
        let sinceFmt = DateFormatter()
        sinceFmt.dateFormat = "yyyyMMddHHmmss"
        sinceFmt.timeZone = TimeZone(identifier: "UTC")
        let buffer = max(60, time.duration * 0.1) // proportional buffer (10%, min 1m)
        let sinceDate = time.fromDate.addingTimeInterval(-buffer)
        let since = sinceFmt.string(from: sinceDate)
        let query = "usage{since=\"\(since)\"}[\(bucket)] by (model)"

        let reportOptions: [String] = ["-z", "UTC"]
        let subcommandArgs: [String] = ["query", query]

        runner.runReport(reportOptions: reportOptions, subcommandArgs: subcommandArgs) { result in
            switch result {
            case .success(let data):
                let pointsByDate = TokiReportParser.parseReport(data)
                var points = pointsByDate.map { TimeSeriesPoint(date: $0.key, models: $0.value) }
                    .sorted { $0.date < $1.date }
                points = Self.gapFillEpochAligned(points: points, time: time)
                let tsData = TimeSeriesData(points: points, granularity: time.bucketSeconds < 3600 ? .fifteenMinute : time.bucketSeconds < 86400 ? .hourly : .daily)
                completion(.success(tsData))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Gap Fill (epoch-aligned, matches toki's bucket boundaries)

    /// Gap-fill using same alignment as toki: floor(epoch / bucket) * bucket
    private static func gapFillEpochAligned(
        points: [TimeSeriesPoint],
        time: TimeConfig
    ) -> [TimeSeriesPoint] {
        let step = TimeInterval(time.bucketSeconds)
        guard step > 0 else { return points }

        let fromEpoch = time.fromDate.timeIntervalSince1970
        let toEpoch = time.toDate.timeIntervalSince1970

        // Align start to toki's bucket boundary: floor(epoch / bucket) * bucket
        let alignedStart = floor(fromEpoch / step) * step
        let alignedEnd = toEpoch

        let existingDates = Set(points.map { Int(floor($0.date.timeIntervalSince1970 / step) * step) })

        var filled = points
        var current = alignedStart
        while current <= alignedEnd {
            let bucket = Int(current)
            if !existingDates.contains(bucket) {
                filled.append(TimeSeriesPoint(date: Date(timeIntervalSince1970: current), models: []))
            }
            current += step
        }
        return filled.sorted { $0.date < $1.date }
    }
}
