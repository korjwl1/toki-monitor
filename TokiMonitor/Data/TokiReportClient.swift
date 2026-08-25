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

    /// Per-model token usage with the PROVIDER key kept.
    ///
    /// `queryPromQL` folds every provider into one date-keyed dictionary, which
    /// is right for a total and wrong for the plan-fit model breakdown: Claude
    /// has model-scoped window limits and Codex has none, so the two sides come
    /// from different sources and must not be presented as symmetric. Merging
    /// the providers here would erase the distinction before the page could
    /// draw it.
    func queryModelUsageByProvider(
        query: String,
        since: String? = nil,
        until: String? = nil
    ) async throws -> [String: [Date: [TokiModelSummary]]] {
        var arguments = ["query", "-z", "UTC", "--output-format", "json"]
        if let since { arguments += ["--start", since] }
        if let until { arguments += ["--end", until] }
        arguments.append(query)
        let data = try await CLIProcessRunner.run(
            executable: TokiPath.resolved,
            arguments: arguments
        )
        var byProvider: [String: [Date: [TokiModelSummary]]] = [:]
        for (provider, entries) in TokiReportParser.providerEntries(data) {
            var points: [Date: [TokiModelSummary]] = [:]
            TokiReportParser.parseEntries(entries, into: &points)
            guard !points.isEmpty else { continue }
            byProvider[provider] = points
        }
        return byProvider
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

    /// Window rows for a panel, as interval frames.
    ///
    /// The legacy `timeSeries` half stays empty on purpose: there is no honest
    /// series to derive from a set of spans, and filling it with something
    /// plausible is how a panel ends up drawing a shape the data never had.
    private func queryWindowFrames(query: String, time: TimeConfig) async throws -> QueryResult {
        let rows = try await queryWindows(
            startEpoch: Int(time.fromDate.timeIntervalSince1970),
            endEpoch: Int(time.toDate.timeIntervalSince1970)
        )
        var byProvider: [String: [WindowRow]] = [:]
        for (provider, row) in rows { byProvider[provider, default: []].append(row) }
        let frames = WindowFrameAdapter.frames(
            rowsByProvider: byProvider,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            query: query,
            datasource: "local"
        )
        return QueryResult(
            timeSeries: TimeSeriesData(points: [], granularity: .hourly),
            frames: frames
        )
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
        // Windows are intervals, not samples. Routing them through the bucket
        // pipeline would mean inventing a series out of spans; instead they
        // reach panels as interval frames, which the state timeline draws.
        if QueryRewriter.metricName(in: query) == "windows" {
            return try await queryWindowFrames(query: query, time: time)
        }
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
