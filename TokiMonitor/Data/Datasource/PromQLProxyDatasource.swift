import Foundation

/// Plugin wrapper around `ServerQueryClient` (toki-sync PromQL proxy).
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
}
