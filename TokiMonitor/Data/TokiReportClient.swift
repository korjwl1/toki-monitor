import Foundation

/// Runs `toki report` CLI commands and parses output.
final class TokiReportClient: Sendable {
    private let runner: TokiReportRunner

    init(runner: TokiReportRunner = TokiReportRunner()) {
        self.runner = runner
    }

    /// Run a raw PromQL query and return parsed date→models map.
    func queryPromQL(query: String) async throws -> [Date: [TokiModelSummary]] {
        let data = try await runner.runReport(
            reportOptions: ["-z", "UTC"],
            subcommandArgs: ["query", query]
        )
        return TokiReportParser.parseReport(data)
    }

    /// Run a pre-interpolated PromQL query and return TimeSeriesData with gap-fill.
    func queryPromQLAsTimeSeries(query: String, time: TimeConfig) async throws -> TimeSeriesData {
        let sinceFmt = DateFormatter()
        sinceFmt.dateFormat = "yyyyMMddHHmmss"
        sinceFmt.timeZone = TimeZone(identifier: "UTC")
        let buffer = max(60, time.duration * 0.1)
        let sinceDate = time.fromDate.addingTimeInterval(-buffer)
        var reportOptions = ["-z", "UTC", "--since", sinceFmt.string(from: sinceDate)]
        if !time.isRelative {
            reportOptions += ["--until", sinceFmt.string(from: time.toDate)]
        }
        let data = try await runner.runReport(
            reportOptions: reportOptions,
            subcommandArgs: ["query", query]
        )
        let pointsByDate = TokiReportParser.parseReport(data)
        var points = pointsByDate.map { TimeSeriesPoint(date: $0.key, models: $0.value) }
            .sorted { $0.date < $1.date }
        points = Self.gapFillEpochAligned(points: points, time: time)
        let granularity: TimeSeriesGranularity = time.bucketSeconds < 3600 ? .fifteenMinute
            : time.bucketSeconds < 86400 ? .hourly : .daily
        return TimeSeriesData(points: points, granularity: granularity)
    }

    // MARK: - Gap Fill (epoch-aligned, matches toki's bucket boundaries)

    private static func gapFillEpochAligned(
        points: [TimeSeriesPoint],
        time: TimeConfig
    ) -> [TimeSeriesPoint] {
        let step = TimeInterval(time.bucketSeconds)
        guard step > 0 else { return points }

        let fromEpoch = time.fromDate.timeIntervalSince1970
        let toEpoch = time.toDate.timeIntervalSince1970

        let alignedStart = floor(fromEpoch / step) * step
        let alignedEnd = toEpoch

        let existingDates = Set(points.map { Int(floor($0.date.timeIntervalSince1970 / step) * step) })

        var filled = points
        var current = alignedStart
        while current <= alignedEnd {
            let bucket = Int(current)
            if !existingDates.contains(bucket) {
                filled.append(TimeSeriesPoint(date: Date(timeIntervalSince1970: current), models: []))
            }
            current += step
        }
        return filled.sorted { $0.date < $1.date }
    }
}
