import Foundation

/// Plugin wrapper around `ServerQueryClient` (toki-sync PromQL proxy).
///
/// Both methods forward and neither catches. That is the whole contract of
/// this layer for contract Q2: a query the backend refuses must arrive at the
/// caller as a thrown error carrying the server's sentence, never as a
/// successfully-returned empty result. An empty `QueryResult` here would render
/// as "no data in this range" — a panel that looks answered, showing a fact
/// about the data, when what actually happened is that the question was
/// rejected.
final class PromQLProxyDatasource: DatasourcePlugin, @unchecked Sendable {
    let kind: String = BuiltinDatasourceKind.promQLProxy

    private let client: ServerQueryClient

    @MainActor
    init(client: ServerQueryClient = ServerQueryClient()) {
        self.client = client
    }

    func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
        try await client.queryPromQLAsTimeSeries(query: query, time: time)
    }

    /// Forwarded explicitly, for the same reason as the local wrapper: the
    /// protocol default would discard frames the client already built.
    func queryPromQL(query: String, time: TimeConfig) async throws -> QueryResult {
        try await client.queryPromQL(query: query, time: time)
    }
}

// MARK: - Telling a refusal from a failure

/// Was this the backend saying "I cannot execute that", or something going
/// wrong on the way?
///
/// The distinction changes what the reader should do, so the UI needs to be
/// able to make it: a refusal is fixed by editing the query and retrying it
/// unchanged will fail identically, while a network error is worth retrying
/// untouched. Both backends have a refusal channel — HTTP 400 with
/// `{"error": …}` from the sync server, a non-zero exit with a stderr line
/// from the daemon — and in both cases the sentence is the backend's own.
enum DatasourceRefusal {

    /// The backend's refusal text, or nil when the error is not a refusal.
    static func reason(_ error: Error) -> String? {
        if let server = error as? ServerQueryError, case let .rejected(_, reason) = server {
            return reason
        }
        if let cli = error as? CLIRunnerError, case let .exitCode(_, message) = cli {
            return message
        }
        return nil
    }

    /// True when the query itself is what failed.
    static func isRefusal(_ error: Error) -> Bool { reason(error) != nil }
}
