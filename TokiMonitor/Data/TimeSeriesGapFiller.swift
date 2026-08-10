import Foundation

/// Shared epoch-aligned gap-fill logic used by both ServerQueryClient and TokiReportClient.
enum TimeSeriesGapFiller {
    /// Every bucket start in the requested window, epoch-aligned to the step.
    ///
    /// The daemon emits only buckets that contain events, so without this a
    /// "last 24 hours" chart draws whatever three hours happened to have
    /// traffic. Frames need the identical axis — a chart built from frames and
    /// one built from points must not disagree about what window was asked for.
    static func bucketStarts(time: TimeConfig) -> [Date] {
        let step = TimeInterval(time.bucketSeconds)
        guard step > 0 else { return [] }
        let alignedStart = floor(time.fromDate.timeIntervalSince1970 / step) * step
        let alignedEnd = time.toDate.timeIntervalSince1970

        var out: [Date] = []
        var current = alignedStart
        // A pathological step/range combination must not spin forever.
        while current <= alignedEnd && out.count < 10_000 {
            out.append(Date(timeIntervalSince1970: current))
            current += step
        }
        return out
    }

    /// Fill missing time buckets with empty points so charts show continuous timelines.
    static func fill(points: [TimeSeriesPoint], time: TimeConfig) -> [TimeSeriesPoint] {
        let step = TimeInterval(time.bucketSeconds)
        guard step > 0 else { return points }

        let existingKeys = Set(points.map { Int(floor($0.date.timeIntervalSince1970 / step) * step) })

        var filled = points
        for slot in bucketStarts(time: time)
        where !existingKeys.contains(Int(slot.timeIntervalSince1970)) {
            filled.append(TimeSeriesPoint(date: slot, models: []))
        }
        return filled.sorted { $0.date < $1.date }
    }
}
