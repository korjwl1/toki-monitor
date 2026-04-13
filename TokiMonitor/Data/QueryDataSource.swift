import Foundation

/// Unified interface for querying time-series data from either local CLI or sync server.
protocol QueryDataSource: Sendable {
    func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData
}
