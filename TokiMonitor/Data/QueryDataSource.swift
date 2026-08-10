import Foundation

/// One query's result: the legacy shape every panel still renders from, plus
/// the frame set that carries named labels and provenance.
///
/// Both are produced from the SAME response so they cannot disagree. Panels
/// migrate to `frames` one at a time; when none read `timeSeries` any more the
/// legacy half is deleted, and until then a datasource cannot serve one
/// without the other.
struct QueryResult: Sendable {
    var timeSeries: TimeSeriesData
    var frames: FrameSet

    init(timeSeries: TimeSeriesData, frames: FrameSet = FrameSet()) {
        self.timeSeries = timeSeries
        self.frames = frames
    }
}

/// Unified interface for querying time-series data from either local CLI or sync server.
protocol QueryDataSource: Sendable {
    func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData

    /// Same query, but also returning frames. Defaulted so a datasource that
    /// has not been migrated keeps compiling and simply serves no frames —
    /// which Inspect reports as "this source does not produce frames yet"
    /// rather than as an empty result.
    func queryPromQL(query: String, time: TimeConfig) async throws -> QueryResult
}

extension QueryDataSource {
    func queryPromQL(query: String, time: TimeConfig) async throws -> QueryResult {
        QueryResult(timeSeries: try await queryPromQLAsTimeSeries(query: query, time: time))
    }
}
