import Foundation

/// Runs `toki report` CLI commands and parses JSON output.
final class TokiReportClient: Sendable {
    private let runner: TokiReportRunner

    init(runner: TokiReportRunner = TokiReportRunner()) {
        self.runner = runner
    }

    /// Legacy: flat list of model summaries for a period.
    func queryAllSummaries(
        period: ReportPeriod,
        timezone: String = TimeZone.current.identifier,
        completion: @escaping @Sendable (Result<[TokiModelSummary], Error>) -> Void
    ) {
        let reportOptions: [String] = ["-z", timezone]
        let subcommandArgs: [String] = [period.subcommand, "--since", period.sinceDate]

        runner.runReport(reportOptions: reportOptions, subcommandArgs: subcommandArgs) { result in
            switch result {
            case .success(let data):
                do {
                    let summaries = try Self.parseFlatOutput(data)
                    completion(.success(summaries))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Time Series via PromQL

    /// Query time-series data using toki's PromQL engine.
    /// Example: `usage[1h] by (model)` with `--since 20260321`
    func queryTimeSeries(
        timeRange: DashboardTimeRange,
        timezone: String = TimeZone.current.identifier,
        completion: @escaping @Sendable (Result<TimeSeriesData, Error>) -> Void
    ) {
        let bucket = timeRange.granularity == .hourly ? "1h" : "1d"
        let query = "usage[\(bucket)] by (model)"

        let reportOptions: [String] = [
            "-z", timezone,
            "--since", timeRange.sinceDate,
        ]
        let subcommandArgs: [String] = ["query", query]

        runner.runReport(reportOptions: reportOptions, subcommandArgs: subcommandArgs) { result in
            switch result {
            case .success(let data):
                do {
                    let tsData = try Self.parsePromQLOutput(
                        data, timeRange: timeRange, timezone: timezone
                    )
                    completion(.success(tsData))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Parsing

    /// Parse PromQL output where period = "2026-03-21T17:00:00|model-name"
    private static func parsePromQLOutput(
        _ data: Data, timeRange: DashboardTimeRange, timezone: String
    ) throws -> TimeSeriesData {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReportError.parseFailed("Invalid UTF-8")
        }

        let decoder = JSONDecoder()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonObjects = splitJsonObjects(trimmed)

        let hourFormatter = DateFormatter()
        hourFormatter.locale = Locale(identifier: "en_US_POSIX")
        hourFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        hourFormatter.timeZone = TimeZone(identifier: timezone) ?? .current

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: timezone) ?? .current

        var pointsByDate: [Date: [TokiModelSummary]] = [:]

        for jsonStr in jsonObjects {
            guard let jsonData = jsonStr.data(using: .utf8),
                  let report = try? decoder.decode(TokiCliReport.self, from: jsonData)
            else { continue }

            for entry in report.data {
                guard let periodStr = entry.period,
                      let models = entry.usagePerModels
                else { continue }

                // PromQL period format: "2026-03-21T17:00:00|model-name" or "2026-03-21|model-name"
                let dateStr: String
                if let pipeIndex = periodStr.firstIndex(of: "|") {
                    dateStr = String(periodStr[..<pipeIndex])
                } else {
                    dateStr = periodStr
                }

                let formatter = dateStr.contains("T") ? hourFormatter : dayFormatter
                guard let date = formatter.date(from: dateStr) else { continue }

                pointsByDate[date, default: []].append(contentsOf: models)
            }
        }

        var points = pointsByDate.map { date, models in
            TimeSeriesPoint(date: date, models: models)
        }.sorted { $0.date < $1.date }

        points = gapFill(points: points, timeRange: timeRange, timezone: timezone)
        return TimeSeriesData(points: points, granularity: timeRange.granularity)
    }

    /// Parse legacy flat output.
    private static func parseFlatOutput(_ data: Data) throws -> [TokiModelSummary] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReportError.parseFailed("Invalid UTF-8")
        }

        var allSummaries: [TokiModelSummary] = []
        let decoder = JSONDecoder()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        for jsonStr in splitJsonObjects(trimmed) {
            guard let jsonData = jsonStr.data(using: .utf8),
                  let report = try? decoder.decode(TokiCliReport.self, from: jsonData)
            else { continue }

            for entry in report.data {
                if let models = entry.usagePerModels {
                    allSummaries.append(contentsOf: models)
                }
            }
        }
        return allSummaries
    }

    // MARK: - Utilities

    private static func splitJsonObjects(_ text: String) -> [String] {
        var objects: [String] = []
        var depth = 0
        var start = text.startIndex

        for i in text.indices {
            if text[i] == "{" { depth += 1 }
            if text[i] == "}" {
                depth -= 1
                if depth == 0 {
                    objects.append(String(text[start...i]))
                    let next = text.index(after: i)
                    if next < text.endIndex {
                        start = next
                    }
                }
            }
        }
        return objects
    }

    private static func gapFill(
        points: [TimeSeriesPoint],
        timeRange: DashboardTimeRange,
        timezone: String
    ) -> [TimeSeriesPoint] {
        let tz = TimeZone(identifier: timezone) ?? .current
        var calendar = Calendar.current
        calendar.timeZone = tz

        let now = Date()
        let step = timeRange.granularity.stepInterval

        let start: Date
        if timeRange.granularity == .hourly {
            let c = calendar.dateComponents([.year, .month, .day, .hour], from: now.addingTimeInterval(-timeRange.duration))
            start = calendar.date(from: c) ?? now.addingTimeInterval(-timeRange.duration)
        } else {
            let c = calendar.dateComponents([.year, .month, .day], from: now.addingTimeInterval(-timeRange.duration))
            start = calendar.date(from: c) ?? now.addingTimeInterval(-timeRange.duration)
        }

        let existingDates = Set(points.map(\.date))
        var filled = points
        var current = start

        while current <= now {
            if !existingDates.contains(current) {
                filled.append(TimeSeriesPoint(date: current, models: []))
            }
            current = current.addingTimeInterval(step)
        }

        return filled.sorted { $0.date < $1.date }
    }

    enum ReportError: Error, LocalizedError {
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .parseFailed(let msg): "Report parse failed: \(msg)"
            }
        }
    }
}

/// CLI output format: `{"data": [...], "type": "every 1d"}`
private struct TokiCliReport: Codable {
    let data: [TokiCliEntry]
    let type: String?
}

private struct TokiCliEntry: Codable {
    let period: String?
    let session: String?
    let usagePerModels: [TokiModelSummary]?

    enum CodingKeys: String, CodingKey {
        case period, session
        case usagePerModels = "usage_per_models"
    }
}
