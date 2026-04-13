import Foundation

/// Runs `toki query` CLI commands and parses output.
final class TokiReportClient: Sendable, QueryDataSource {

    /// Run an instant PromQL query via `toki query` (top-level command, no --since/--until).
    /// The PromQL itself determines the time range via range vectors.
    func queryPromQL(query: String) async throws -> [Date: [TokiModelSummary]] {
        let data = try await CLIProcessRunner.run(
            executable: TokiPath.resolved,
            arguments: ["query", "-z", "UTC", "--output-format", "json", query]
        )
        return TokiReportParser.parseReport(data)
    }

    /// Run a PromQL query via `toki query` (top-level command).
    /// The `since`/`until` parameters are accepted for API compatibility but ignored —
    /// the PromQL range vector (e.g. `[1h]`) determines the time window.
    func queryPromQL(query: String, since: String? = nil, until: String? = nil) async throws -> [Date: [TokiModelSummary]] {
        let data = try await CLIProcessRunner.run(
            executable: TokiPath.resolved,
            arguments: ["query", "-z", "UTC", "--output-format", "json", query]
        )
        return TokiReportParser.parseReport(data)
    }

    /// Run a range query via `toki query --start/--end/--step` (Prometheus/VM query_range compatible).
    /// Start is floored to bucket boundary so local daemon's epoch-floor bucketing
    /// produces the same step grid as VM's start-aligned steps.
    func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
        let step = time.bucketSeconds
        let rawStart = Int(time.fromDate.timeIntervalSince1970)
        let startEpoch = (rawStart / step) * step  // floor to bucket boundary
        let endEpoch = Int(time.toDate.timeIntervalSince1970)
        let data = try await CLIProcessRunner.run(
            executable: TokiPath.resolved,
            arguments: ["query", "-z", "UTC", "--output-format", "json",
                         "--start", "\(startEpoch)", "--end", "\(endEpoch)",
                         "--step", time.bucketString, query]
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
