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
        try await queryPromQL(query: query, time: time).timeSeries
    }

    /// One request, both shapes — the server returns the same envelope the CLI
    /// does, so frames come from the same bytes rather than a second round trip.
    func queryPromQL(query: String, time: TimeConfig) async throws -> QueryResult {
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

        let series = TimeSeriesData(points: points, granularity: granularity)
        let frames = FrameAdapter.frames(
            providers: TokiReportParser.providerEntries(data),
            query: query,
            datasource: "server",
            time: time
        )
        return QueryResult(timeSeries: series, frames: frames)
    }

    /// Fetch merged multi-device window rows from the server (windows metric,
    /// scope=self). The server's rows are the field-wise merge of every synced
    /// device — the authoritative statistics source for multi-device accounts.
    func queryWindows(startEpoch: Int, endEpoch: Int) async throws -> [(provider: String, row: WindowRow)] {
        let creds = try await requireCredentials()
        let data = try await tokiQuery("windows", start: startEpoch, end: endEpoch,
                                       step: "1h", creds: creds, retryOn401: true)
        struct Envelope: Decodable {
            let schema: Int?
            let windows: [String: [WindowRow]]?
        }
        // Decode/schema failures must THROW: an HTTP-200 body we cannot read
        // is a failed source, and mapping it to [] made Plan Fit display
        // \"no data yet\" over real errors (and set serverFailed=false).
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        if let schema = envelope.schema, schema != 1 {
            throw ServerQueryError.invalidResponse
        }
        let providers = envelope.windows ?? [:]
        return providers.flatMap { name, rows in rows.map { (name, $0) } }
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
        guard http.statusCode == 200 else {
            throw ServerQueryError.from(status: http.statusCode, body: data)
        }
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
        guard http.statusCode == 200 else {
            throw ServerQueryError.from(status: http.statusCode, body: data)
        }
        return data
    }

    // MARK: - Helpers

    @MainActor
    private func requireCredentials() throws -> SyncCredentials {
        guard let c = syncClient.load() else { throw ServerQueryError.notConfigured }
        return c
    }
}

enum ServerQueryError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case invalidResponse
    case httpError(Int)
    /// The server refused the request and said why. The reason is the server's
    /// own sentence, kept intact.
    case rejected(status: Int, reason: String)
    case tokenExpired
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:        return L.sync.notConfigured
        case .invalidURL:           return L.tr("잘못된 URL", "Invalid URL")
        case .invalidResponse:      return L.tr("잘못된 응답", "Invalid response")
        case .httpError(let c):     return "HTTP \(c)"
        // Verbatim, with no wrapper of ours: contract Q2 exists because the
        // reason is the only thing that tells the reader which token to fix,
        // and "HTTP 400" tells them nothing at all.
        case .rejected(_, let r):   return r
        case .tokenExpired:         return L.sync.tokenExpired
        case .networkError(let m):  return m
        }
    }
}

// MARK: - Reading a refusal
//
// The server answers a query it cannot execute with 400 and
// `{"error": "unsupported query: <reason>"}` (toki_sync `AppError`). Until this
// existed the client threw away the body and threw `HTTP 400`, so the one piece
// of information that names the unsupported token — the whole point of the
// server-side fix — never reached the screen.
//
// Split out as a pure function so it is testable without a URLSession: what
// must not regress is the READING of the body, not the transport.

extension ServerQueryError {

    /// Map a non-2xx response onto an error that keeps whatever the server
    /// said. Falls back to the bare status only when the body says nothing
    /// usable — never to an empty result.
    static func from(status: Int, body: Data) -> ServerQueryError {
        guard let reason = refusalReason(in: body) else { return .httpError(status) }
        return .rejected(status: status, reason: reason)
    }

    /// The server's sentence, or nil when the body carries none.
    static func refusalReason(in body: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            for key in ["error", "message", "detail"] {
                if let text = object[key] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return nil
        }
        // A plain-text body is worth showing too, but only when it reads like a
        // sentence. An HTML error page from something in front of the server is
        // noise, and a long body is a payload rather than an explanation.
        guard let text = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !text.hasPrefix("<"), text.count <= 300
        else { return nil }
        return text
    }
}
