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
    /// The query is passed as-is; the server injects `user_id` filtering automatically.
    func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
        let creds = try await requireCredentials()
        let data = try await queryRange(query, start: time.fromDate, end: time.toDate,
                                        step: time.bucketString, creds: creds, retryOn401: true)
        let byDate = parseVMRangeResponse(data)
        var points = byDate.map { TimeSeriesPoint(date: $0.key, models: $0.value) }
            .sorted { $0.date < $1.date }
        points = TimeSeriesGapFiller.fill(points: points, time: time)
        let granularity: TimeSeriesGranularity = time.bucketSeconds < 3600 ? .fifteenMinute
            : time.bucketSeconds < 86400 ? .hourly : .daily
        return TimeSeriesData(points: points, granularity: granularity)
    }

    // MARK: - HTTP

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

            // Prefer "model" label; fall back to "provider"
            let modelName = metric["model"] ?? metric["provider"] ?? "unknown"
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
                default:
                    // No type label (aggregated query) — treat as input
                    bucket.input += uval
                }
                bucket.total += uval
                if val > 0 { bucket.events += 1 }
                buckets[key] = bucket
            }
        }

        var byDate: [Date: [TokiModelSummary]] = [:]
        for (key, bucket) in buckets {
            let summary = TokiModelSummary(
                model:        key.model,
                inputTokens:  bucket.input,
                outputTokens: bucket.output,
                totalTokens:  bucket.total,
                events:       bucket.events,
                costUsd:      nil,
                cacheCreationInputTokens: bucket.cacheCreation > 0 ? bucket.cacheCreation : nil,
                cacheReadInputTokens:     bucket.cacheRead > 0 ? bucket.cacheRead : nil,
                cachedInputTokens:        nil,
                reasoningOutputTokens:    nil
            )
            byDate[key.date, default: []].append(summary)
        }
        return byDate
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
