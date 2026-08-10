import Foundation

/// Plugin wrapper around `TokiReportClient` (local `toki` CLI).
final class LocalCLIDatasource: DatasourcePlugin, @unchecked Sendable {
    let kind: String = BuiltinDatasourceKind.localCLI

    private let client: TokiReportClient

    init(client: TokiReportClient = TokiReportClient()) {
        self.client = client
    }

    func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
        try await client.queryPromQLAsTimeSeries(query: query, time: time)
    }

    /// Forwarded explicitly. Without this the protocol's default extension
    /// takes over and drops the frames the client already produced — the
    /// wrapper would silently downgrade its own backend.
    func queryPromQL(query: String, time: TimeConfig) async throws -> QueryResult {
        try await client.queryPromQL(query: query, time: time)
    }
}
