import Foundation

/// Shared epoch-aligned gap-fill logic used by both ServerQueryClient and TokiReportClient.
enum TimeSeriesGapFiller {
    /// Fill missing time buckets with empty points so charts show continuous timelines.
    static func fill(points: [TimeSeriesPoint], time: TimeConfig) -> [TimeSeriesPoint] {
        let step = TimeInterval(time.bucketSeconds)
        guard step > 0 else { return points }

        let alignedStart = floor(time.fromDate.timeIntervalSince1970 / step) * step
        let alignedEnd = time.toDate.timeIntervalSince1970

        let existingKeys = Set(points.map { Int(floor($0.date.timeIntervalSince1970 / step) * step) })

        var filled = points
        var current = alignedStart
        while current <= alignedEnd {
            let bucket = Int(current)
            if !existingKeys.contains(bucket) {
                filled.append(TimeSeriesPoint(date: Date(timeIntervalSince1970: current), models: []))
            }
            current += step
        }
        return filled.sorted { $0.date < $1.date }
    }
}
