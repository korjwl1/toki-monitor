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

    /// Run a PromQL query via `toki query`, bounding the scan with
    /// --start/--end when given. (These were previously accepted but silently
    /// dropped, so TokenAggregator's graph-range fetch scanned all history.)
    func queryPromQL(query: String, since: String? = nil, until: String? = nil) async throws -> [Date: [TokiModelSummary]] {
        var arguments = ["query", "-z", "UTC", "--output-format", "json"]
        if let since { arguments += ["--start", since] }
        if let until { arguments += ["--end", until] }
        arguments.append(query)
        let data = try await CLIProcessRunner.run(
            executable: TokiPath.resolved,
            arguments: arguments
        )
        return TokiReportParser.parseReport(data)
    }

    /// Fetch rate-limit window rows via `toki query windows` for the plan-fit
    /// statistics view. Returns (provider, row) pairs.
    func queryWindows(startEpoch: Int, endEpoch: Int) async throws -> [(provider: String, row: WindowRow)] {
        let data = try await CLIProcessRunner.run(
            executable: TokiPath.resolved,
            arguments: ["query", "-z", "UTC", "--output-format", "json",
                        "--start", "\(startEpoch)", "--end", "\(endEpoch)", "windows"]
        )
        // Envelope: {"information": {...}, "providers": {"<name>": [WindowRow...]}}
        struct Envelope: Decodable {
            let providers: [String: [WindowRow]]?
        }
        // A non-empty payload that fails to decode is an ERROR (schema
        // mismatch, old CLI) — swallowing it here made every failure look
        // like "no data yet" upstream.
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let providers = envelope.providers ?? [:]
        return providers.flatMap { name, rows in rows.map { (name, $0) } }
    }

    /// Run a range query via `toki query --start/--end/--step` (Prometheus/VM query_range compatible).
    /// Start is floored to bucket boundary so local daemon's epoch-floor bucketing
    /// produces the same step grid as VM's start-aligned steps.
    func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
        try await queryPromQL(query: query, time: time).timeSeries
    }

    /// Runs the query once and derives BOTH shapes from the single response.
    /// Fetching twice would double the CLI cost and could return different
    /// data across the two calls.
    func queryPromQL(query: String, time: TimeConfig) async throws -> QueryResult {
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
        let series = TimeSeriesData(points: points, granularity: granularity)
        let frames = FrameAdapter.frames(
            providers: TokiReportParser.providerEntries(data),
            query: query,
            datasource: "local",
            time: time
        )
        return QueryResult(timeSeries: series, frames: frames)
    }

}
