import Foundation

/// Plugin wrapper around `TokiReportClient` (local `toki` CLI).
final class LocalCLIDatasource: DatasourcePlugin, @unchecked Sendable {
    let kind: String = BuiltinDatasourceKind.localCLI
    let displayName: String = L.sync.local

    private let client: TokiReportClient

    init(client: TokiReportClient = TokiReportClient()) {
        self.client = client
    }

    func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
        try await client.queryPromQLAsTimeSeries(query: query, time: time)
    }
}
