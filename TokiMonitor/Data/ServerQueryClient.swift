import Foundation

/// Queries toki token metrics from the sync server's PromQL proxy.
///
/// Endpoints (JWT-authenticated):
///   GET {httpURL}/api/v1/query_range?query=...&start=...&end=...&step=...
///
/// The server injects `user_id` filtering automatically — no need to include it
/// in the query. VictoriaMetrics Prometheus-compatible response format is parsed.
final class ServerQueryClient: @unchecked Sendable, QueryDataSource {
    @MainActor private let syncClient: SyncClient

    @MainActor
    init(syncClient: SyncClient = .shared) {
        self.syncClient = syncClient
    }

    // MARK: - Public API

    /// Run a standard PromQL range query against the toki-sync server proxy.
    /// Rewrites local-compatible `usage` metric to `toki_tokens_total`
    /// so the VictoriaMetrics backend returns per-type breakdowns.
    ///
    /// Also issues a parallel `count_over_time` query (on `type="input"` only)
    /// to get accurate event counts. `sum_over_time` destroys event count
    /// information, so we cannot derive API call counts from token sums.
    func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
        let rewritten = Self.rewriteForServer(query)
        let eventsQuery = Self.rewriteForEventCount(query)
        let creds = try await requireCredentials()

        // Floor start to bucket boundary — matches local daemon's epoch-floor bucketing
        let step = time.bucketSeconds
        let rawStart = Int(time.fromDate.timeIntervalSince1970)
        let flooredStart = Date(timeIntervalSince1970: Double((rawStart / step) * step))

        // Range queries for chart + totals (LOCAL range sum = SERVER range sum, verified)
        async let tokenData = queryRange(rewritten, start: flooredStart, end: time.toDate,
                                         step: time.bucketString, creds: creds, retryOn401: true)
        async let eventsData = queryRange(eventsQuery, start: flooredStart, end: time.toDate,
                                          step: time.bucketString, creds: creds, retryOn401: true)

        let byDate = parseVMRangeResponse(try await tokenData)
        let eventCounts = parseVMEventCounts(try await eventsData)
        let merged = mergeEventCounts(byDate: byDate, eventCounts: eventCounts)

        var points = merged.map { TimeSeriesPoint(date: $0.key, models: $0.value) }
            .sorted { $0.date < $1.date }
        points = TimeSeriesGapFiller.fill(points: points, time: time)
        let granularity: TimeSeriesGranularity = time.bucketSeconds < 3600 ? .fifteenMinute
            : time.bucketSeconds < 86400 ? .hourly : .daily

        return TimeSeriesData(points: points, granularity: granularity)
    }

    // MARK: - Query Rewriting

    /// Rewrite query for event counting using `toki_events_total`.
    /// Every API call writes exactly one `toki_events_total` data point (value=1),
    /// regardless of whether token values are zero.
    /// Uses `sum_over_time` to count events (sum of 1s = event count).
    static func rewriteForEventCount(_ query: String) -> String {
        var result = query
        // usage{<labels>} → toki_events_total{<labels>}
        result = result.replacingOccurrences(
            of: #"usage\{([^}]*)\}"#,
            with: #"toki_events_total{$1}"#,
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"toki_events_total\{\}"#,
            with: "toki_events_total",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"usage\["#,
            with: #"toki_events_total["#,
            options: .regularExpression
        )
        // increase() → sum_over_time() (sum of 1s = event count)
        result = result.replacingOccurrences(
            of: #"increase\("#,
            with: "sum_over_time(",
            options: .regularExpression
        )
        return result
    }

    /// Rewrite local `usage{...}` metric to `toki_tokens_total{...}` for the
    /// VictoriaMetrics backend. The local toki CLI's `usage` metric aggregates all
    /// token types (input, output, cache_create, cache_read, etc.) into one value.
    /// The server stores each type as a separate series under `toki_tokens_total`.
    ///
    /// Also injects `type` into `by (...)` clauses so the parser receives per-type
    /// breakdowns for accurate cost estimation and token categorization.
    static func rewriteForServer(_ query: String) -> String {
        var result = query

        // Metric-specific rewrites:
        // cost{} → toki_cost_usd{} (no type injection needed)
        // events{} → toki_events_total{} (no type injection needed)
        // usage{} → toki_tokens_total{} (needs type injection)
        let isCostQuery = result.contains("cost{") || result.contains("cost[")
        let isEventsQuery = result.contains("events{") || result.contains("events[")

        if isCostQuery {
            result = result.replacingOccurrences(of: #"cost\{([^}]*)\}"#, with: #"toki_cost_usd{$1}"#, options: .regularExpression)
            result = result.replacingOccurrences(of: #"toki_cost_usd\{\}"#, with: "toki_cost_usd", options: .regularExpression)
            result = result.replacingOccurrences(of: #"cost\["#, with: #"toki_cost_usd["#, options: .regularExpression)
        } else if isEventsQuery {
            result = result.replacingOccurrences(of: #"events\{([^}]*)\}"#, with: #"toki_events_total{$1}"#, options: .regularExpression)
            result = result.replacingOccurrences(of: #"toki_events_total\{\}"#, with: "toki_events_total", options: .regularExpression)
            result = result.replacingOccurrences(of: #"events\["#, with: #"toki_events_total["#, options: .regularExpression)
        } else {
            // usage → toki_tokens_total
            result = result.replacingOccurrences(of: #"usage\{([^}]*)\}"#, with: #"toki_tokens_total{$1}"#, options: .regularExpression)
            result = result.replacingOccurrences(of: #"toki_tokens_total\{\}"#, with: "toki_tokens_total", options: .regularExpression)
            result = result.replacingOccurrences(of: #"usage\["#, with: #"toki_tokens_total["#, options: .regularExpression)
        }

        // increase() → sum_over_time() (VM stores gauge, not counter)
        result = result.replacingOccurrences(
            of: #"increase\("#,
            with: "sum_over_time(",
            options: .regularExpression
        )

        // Inject `type` into by() only for token queries (not cost/events)
        if !isCostQuery && !isEventsQuery {
            result = result.replacingOccurrences(
                of: #"by\s*\(([^)]*)\)"#,
                with: "by ($1, type)",
                options: .regularExpression
            )
            // Clean up if type was already present
            result = result.replacingOccurrences(
                of: #", type, type\)"#,
                with: ", type)",
                options: .regularExpression
            )
        }
        return result
    }

    // MARK: - HTTP

    private func queryInstant(
        _ promql: String,
        at time: Date,
        creds: SyncCredentials,
        retryOn401: Bool
    ) async throws -> Data {
        guard var components = URLComponents(string: "\(creds.httpURL)/api/v1/query") else {
            throw ServerQueryError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: promql),
            URLQueryItem(name: "time", value: "\(Int(time.timeIntervalSince1970))"),
            URLQueryItem(name: "scope", value: "self"),
        ]
        guard let url = components.url else { throw ServerQueryError.invalidURL }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ServerQueryError.invalidResponse }

        if http.statusCode == 401, retryOn401 {
            do {
                let refreshed = try await syncClient.refreshAccessToken(creds)
                return try await queryInstant(promql, at: time, creds: refreshed, retryOn401: false)
            } catch is SyncClientError {
                await SyncManager.shared.markTokenExpired()
                throw ServerQueryError.tokenExpired
            } catch {
                throw ServerQueryError.httpError(0)
            }
        }
        guard http.statusCode == 200 else { throw ServerQueryError.httpError(http.statusCode) }
        return data
    }

    private func queryRange(
        _ promql: String,
        start: Date,
        end: Date,
        step: String,
        creds: SyncCredentials,
        retryOn401: Bool
    ) async throws -> Data {
        guard var components = URLComponents(string: "\(creds.httpURL)/api/v1/query_range") else {
            throw ServerQueryError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: promql),
            URLQueryItem(name: "start", value: "\(Int(start.timeIntervalSince1970))"),
            URLQueryItem(name: "end",   value: "\(Int(end.timeIntervalSince1970))"),
            URLQueryItem(name: "step",  value: step),
            URLQueryItem(name: "scope", value: "self"),
        ]
        guard let url = components.url else { throw ServerQueryError.invalidURL }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ServerQueryError.invalidResponse }

        if http.statusCode == 401, retryOn401 {
            do {
                let refreshed = try await syncClient.refreshAccessToken(creds)
                return try await queryRange(promql, start: start, end: end, step: step,
                                            creds: refreshed, retryOn401: false)
            } catch is SyncClientError {
                await SyncManager.shared.markTokenExpired()
                throw ServerQueryError.tokenExpired
            } catch {
                throw ServerQueryError.httpError(0)
            }
        }
        guard http.statusCode == 200 else {
            throw ServerQueryError.httpError(http.statusCode)
        }
        return data
    }

    // MARK: - Response Parsing

    /// Parses Prometheus/VictoriaMetrics API response into the app's model format.
    ///
    /// Response shape:
    /// ```json
    /// { "status": "success",
    ///   "data": { "resultType": "matrix",
    ///             "result": [{ "metric": {"model":"claude-opus-4-5",...},
    ///                          "values": [[ts, "123"], ...] }] } }
    /// ```
    private func parseVMRangeResponse(_ data: Data) -> [Date: [TokiModelSummary]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj  = json["data"]   as? [String: Any],
              let results  = dataObj["result"] as? [[String: Any]] else { return [:] }

        // Intermediate accumulator keyed by (date, model).
        // Collects per-type token values before building TokiModelSummary.
        struct BucketKey: Hashable { let date: Date; let model: String }
        struct TokenBucket {
            var input: UInt64 = 0
            var output: UInt64 = 0
            var cacheCreation: UInt64 = 0
            var cacheRead: UInt64 = 0
            var total: UInt64 = 0
            var events: Int = 0
        }
        var buckets: [BucketKey: TokenBucket] = [:]

        for result in results {
            guard let metric     = result["metric"] as? [String: String],
                  let valuePairs = result["values"] as? [[Any]] else { continue }

            // Prefer "model" label; fall back to "project" (for project queries), then "provider"
            let modelName = metric["model"] ?? metric["project"] ?? metric["provider"] ?? "unknown"
            let tokenType = metric["type"]  // e.g. "input", "output", "cache_create", "cache_read"

            for pair in valuePairs {
                guard pair.count >= 2,
                      let tsNum   = pair[0] as? NSNumber,
                      let valStr  = pair[1] as? String,
                      let val     = Double(valStr) else { continue }
                let date = Date(timeIntervalSince1970: tsNum.doubleValue)
                let uval = UInt64(max(0, val))
                let key = BucketKey(date: date, model: modelName)
                var bucket = buckets[key] ?? TokenBucket()

                switch tokenType {
                case "input":
                    bucket.input += uval
                case "output":
                    bucket.output += uval
                case "cache_create":
                    bucket.cacheCreation += uval
                case "cache_read":
                    bucket.cacheRead += uval
                case "cached_input":        // Codex: subset of input
                    bucket.cacheRead += uval
                case "reasoning_output":    // Codex: subset of output
                    bucket.cacheCreation += uval
                default:
                    // No type label (aggregated query) — treat as input
                    bucket.input += uval
                }
                // Count all types in total — the local CLI's total_tokens includes
                // input + output + cache_creation + cache_read
                bucket.total += uval
                // Events are NOT counted here — sum_over_time values cannot tell us
                // how many API calls occurred. A parallel count_over_time query
                // provides accurate event counts (see mergeEventCounts).
                buckets[key] = bucket
            }
        }

        var byDate: [Date: [TokiModelSummary]] = [:]
        for (key, bucket) in buckets {
            let cacheCreation: UInt64? = bucket.cacheCreation > 0 ? bucket.cacheCreation : nil
            let cacheRead: UInt64? = bucket.cacheRead > 0 ? bucket.cacheRead : nil
            let estimatedCost = ModelPricing.estimateCost(
                model: key.model,
                inputTokens: bucket.input,
                outputTokens: bucket.output,
                cacheCreationInputTokens: cacheCreation,
                cacheReadInputTokens: cacheRead
            )
            let summary = TokiModelSummary(
                model:        key.model,
                inputTokens:  bucket.input,
                outputTokens: bucket.output,
                totalTokens:  bucket.total,
                events:       bucket.events,
                costUsd:      estimatedCost,
                cacheCreationInputTokens: cacheCreation,
                cacheReadInputTokens:     cacheRead,
                cachedInputTokens:        nil,
                reasoningOutputTokens:    nil
            )
            byDate[key.date, default: []].append(summary)
        }
        return byDate
    }

    // MARK: - Event Count Parsing

    /// Parse a `count_over_time` response into (date, model) → event count.
    /// The query is filtered to `type="input"` so each data point = one API call.
    private func parseVMEventCounts(_ data: Data) -> [Date: [String: Int]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj  = json["data"]   as? [String: Any],
              let results  = dataObj["result"] as? [[String: Any]] else { return [:] }

        var counts: [Date: [String: Int]] = [:]

        for result in results {
            guard let metric     = result["metric"] as? [String: String],
                  let valuePairs = result["values"] as? [[Any]] else { continue }

            let modelName = metric["model"] ?? metric["project"] ?? metric["provider"] ?? "unknown"

            for pair in valuePairs {
                guard pair.count >= 2,
                      let tsNum   = pair[0] as? NSNumber,
                      let valStr  = pair[1] as? String,
                      let valDbl  = Double(valStr) else { continue }
                let date = Date(timeIntervalSince1970: tsNum.doubleValue)
                let val = Int(max(0, valDbl))
                counts[date, default: [:]][modelName, default: 0] += val
            }
        }
        return counts
    }

    /// Merge event counts from a parallel `count_over_time` query into the
    /// token data parsed by `parseVMRangeResponse`.
    private func mergeEventCounts(
        byDate: [Date: [TokiModelSummary]],
        eventCounts: [Date: [String: Int]]
    ) -> [Date: [TokiModelSummary]] {
        var merged: [Date: [TokiModelSummary]] = [:]
        for (date, summaries) in byDate {
            let dateCounts = eventCounts[date] ?? [:]
            merged[date] = summaries.map { summary in
                let events = dateCounts[summary.model] ?? 0
                return TokiModelSummary(
                    model: summary.model,
                    inputTokens: summary.inputTokens,
                    outputTokens: summary.outputTokens,
                    totalTokens: summary.totalTokens,
                    events: events,
                    costUsd: summary.costUsd,
                    cacheCreationInputTokens: summary.cacheCreationInputTokens,
                    cacheReadInputTokens: summary.cacheReadInputTokens,
                    cachedInputTokens: summary.cachedInputTokens,
                    reasoningOutputTokens: summary.reasoningOutputTokens
                )
            }
        }
        return merged
    }

    // MARK: - Helpers

    @MainActor
    private func requireCredentials() throws -> SyncCredentials {
        guard let c = syncClient.load() else { throw ServerQueryError.notConfigured }
        return c
    }
}

enum ServerQueryError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .notConfigured:    return L.sync.notConfigured
        case .invalidURL:       return L.tr("잘못된 URL", "Invalid URL")
        case .invalidResponse:  return L.tr("잘못된 응답", "Invalid response")
        case .httpError(let c): return "HTTP \(c)"
        case .tokenExpired:     return L.sync.tokenExpired
        }
    }
}
