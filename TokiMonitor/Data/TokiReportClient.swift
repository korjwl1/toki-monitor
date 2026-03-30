import Foundation

/// Runs `toki report` CLI commands and parses output.
final class TokiReportClient: Sendable, QueryDataSource {
    private let runner: TokiReportRunner

    init(runner: TokiReportRunner = TokiReportRunner()) {
        self.runner = runner
    }

    /// Run a raw PromQL query and return parsed date→models map.
    /// Optionally pass `since`/`until` timestamps (yyyyMMddHHmmss, UTC) as CLI flags.
    func queryPromQL(query: String, since: String? = nil, until: String? = nil) async throws -> [Date: [TokiModelSummary]] {
        var reportOptions = ["-z", "UTC"]
        if let since { reportOptions += ["--since", since] }
        if let until { reportOptions += ["--until", until] }
        let data = try await runner.runReport(
            reportOptions: reportOptions,
            subcommandArgs: ["query", query]
        )
        return TokiReportParser.parseReport(data)
    }

    /// Run a pre-interpolated PromQL query and return TimeSeriesData with gap-fill.
    func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
        let sinceFmt = DateFormatter()
        sinceFmt.dateFormat = "yyyyMMddHHmmss"
        sinceFmt.timeZone = TimeZone(identifier: "UTC")
        let buffer = max(60, time.duration * 0.1)
        let sinceDate = time.fromDate.addingTimeInterval(-buffer)
        var reportOptions = ["-z", "UTC", "--since", sinceFmt.string(from: sinceDate)]
        if !time.isRelative {
            reportOptions += ["--until", sinceFmt.string(from: time.toDate)]
        }
        let data = try await runner.runReport(
            reportOptions: reportOptions,
            subcommandArgs: ["query", query]
        )
        let pointsByDate = TokiReportParser.parseReport(data)
        var points = pointsByDate.map { TimeSeriesPoint(date: $0.key, models: $0.value) }
            .sorted { $0.date < $1.date }
        points = TimeSeriesGapFiller.fill(points: points, time: time)
        let granularity: TimeSeriesGranularity = time.bucketSeconds < 3600 ? .fifteenMinute
            : time.bucketSeconds < 86400 ? .hourly : .daily
        return TimeSeriesData(points: points, granularity: granularity)
    }

}
