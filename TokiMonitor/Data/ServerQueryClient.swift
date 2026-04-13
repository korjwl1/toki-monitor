import Foundation

/// Queries toki token metrics from the sync server's EventStore.
///
/// Endpoints (JWT-authenticated):
///   GET {httpURL}/api/v1/toki/query?query=...&start=...&end=...&step=...
///
/// The server injects `user_id` filtering automatically — no need to include it
/// in the query. Returns toki-format JSON (same parser as local CLI).
final class ServerQueryClient: @unchecked Sendable, QueryDataSource {
    @MainActor private let syncClient: SyncClient

    @MainActor
    init(syncClient: SyncClient = .shared) {
        self.syncClient = syncClient
    }

    // MARK: - Public API

    /// Run a PromQL query against the toki-sync server.
    /// Server returns toki-format JSON (same as `toki query --output-format json`).
    /// No client-side rewriting or special parsing — same parser as local.
    func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
        let creds = try await requireCredentials()

        let step = time.bucketSeconds
        let rawStart = Int(time.fromDate.timeIntervalSince1970)
        let startEpoch = (rawStart / step) * step
        let endEpoch = Int(time.toDate.timeIntervalSince1970)

        let data = try await tokiQuery(query, start: startEpoch, end: endEpoch,
                                       step: time.bucketString, creds: creds, retryOn401: true)

        // Same parser as local TokiReportClient
        let pointsByDate = TokiReportParser.parseReport(data)
        var points = pointsByDate.map { TimeSeriesPoint(date: $0.key, models: $0.value) }
            .sorted { $0.date < $1.date }
        points = TimeSeriesGapFiller.fill(points: points, time: time)
        let granularity: TimeSeriesGranularity = time.bucketSeconds < 3600 ? .fifteenMinute
            : time.bucketSeconds < 86400 ? .hourly : .daily

        return TimeSeriesData(points: points, granularity: granularity)
    }

    // MARK: - HTTP

    /// Query /api/v1/toki/query — returns toki-format JSON (same as local CLI).
    private func tokiQuery(
        _ promql: String,
        start: Int,
        end: Int,
        step: String,
        creds: SyncCredentials,
        retryOn401: Bool,
        retryOnTransient: Bool = true
    ) async throws -> Data {
        guard var components = URLComponents(string: "\(creds.httpURL)/api/v1/toki/query") else {
            throw ServerQueryError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: promql),
            URLQueryItem(name: "start", value: "\(start)"),
            URLQueryItem(name: "end", value: "\(end)"),
            URLQueryItem(name: "step", value: step),
            URLQueryItem(name: "scope", value: "self"),
        ]
        guard let url = components.url else { throw ServerQueryError.invalidURL }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            // Retry once on transient network errors (timeout, connection reset)
            if retryOnTransient {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                return try await tokiQuery(promql, start: start, end: end, step: step,
                                           creds: creds, retryOn401: retryOn401, retryOnTransient: false)
            }
            throw ServerQueryError.networkError(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw ServerQueryError.invalidResponse }

        // Retry once on server errors (5xx)
        if http.statusCode >= 500, retryOnTransient {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try await tokiQuery(promql, start: start, end: end, step: step,
                                       creds: creds, retryOn401: retryOn401, retryOnTransient: false)
        }

        if http.statusCode == 401, retryOn401 {
            do {
                let refreshed = try await syncClient.refreshAccessToken(creds)
                return try await tokiQuery(promql, start: start, end: end, step: step, creds: refreshed, retryOn401: false)
            } catch is SyncClientError {
                await SyncManager.shared.markTokenExpired()
                throw ServerQueryError.tokenExpired
            } catch {
                throw ServerQueryError.httpError(http.statusCode)
            }
        }
        guard http.statusCode == 200 else { throw ServerQueryError.httpError(http.statusCode) }
        return data
    }

    private func queryInstant(
        _ promql: String,
        at time: Date,
        creds: SyncCredentials,
        retryOn401: Bool,
        retryOnTransient: Bool = true
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

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            if retryOnTransient {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return try await queryInstant(promql, at: time, creds: creds, retryOn401: retryOn401, retryOnTransient: false)
            }
            throw ServerQueryError.networkError(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw ServerQueryError.invalidResponse }

        if http.statusCode >= 500, retryOnTransient {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try await queryInstant(promql, at: time, creds: creds, retryOn401: retryOn401, retryOnTransient: false)
        }

        if http.statusCode == 401, retryOn401 {
            do {
                let refreshed = try await syncClient.refreshAccessToken(creds)
                return try await queryInstant(promql, at: time, creds: refreshed, retryOn401: false)
            } catch is SyncClientError {
                await SyncManager.shared.markTokenExpired()
                throw ServerQueryError.tokenExpired
            } catch {
                throw ServerQueryError.httpError(http.statusCode)
            }
        }
        guard http.statusCode == 200 else { throw ServerQueryError.httpError(http.statusCode) }
        return data
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
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:        return L.sync.notConfigured
        case .invalidURL:           return L.tr("잘못된 URL", "Invalid URL")
        case .invalidResponse:      return L.tr("잘못된 응답", "Invalid response")
        case .httpError(let c):     return "HTTP \(c)"
        case .tokenExpired:         return L.sync.tokenExpired
        case .networkError(let m):  return m
        }
    }
}
