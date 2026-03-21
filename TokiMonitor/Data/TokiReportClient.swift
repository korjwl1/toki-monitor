import Foundation

/// Runs `toki report` CLI commands and parses JSON output.
final class TokiReportClient: Sendable {
    let runner: TokiReportRunner

    init(runner: TokiReportRunner = TokiReportRunner()) {
        self.runner = runner
    }

    /// Legacy: flat list of model summaries for a period.
    func queryAllSummaries(
        period: ReportPeriod,
        timezone: String = "UTC",
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

    func queryTimeSeries(
        timeRange: DashboardTimeRange,
        timezone: String = "UTC",
        completion: @escaping @Sendable (Result<TimeSeriesData, Error>) -> Void
    ) {
        let bucket = timeRange.granularity == .hourly ? "1h" : "1d"
        let sinceFmt = DateFormatter()
        sinceFmt.dateFormat = "yyyyMMddHHmmss"
        sinceFmt.timeZone = TimeZone(identifier: "UTC")
        let since = sinceFmt.string(from: Date().addingTimeInterval(-timeRange.duration - 3600))
        let query = "usage{since=\"\(since)\"}[\(bucket)] by (model)"

        let reportOptions: [String] = ["-z", timezone]
        let subcommandArgs: [String] = ["query", query]

        runner.runReport(reportOptions: reportOptions, subcommandArgs: subcommandArgs) { result in
            switch result {
            case .success(let data):
                do {
                    let tsData = try Self.parseReportOutput(
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

    // MARK: - Parsing (new format)

    /// Parse the new toki JSON format:
    /// ```json
    /// {
    ///   "information": { "type": "hourly", ... },
    ///   "providers": {
    ///     "claude_code": [{ "period": "2026-03-21T14:00", "usage_per_models": [...] }],
    ///     "codex": [...]
    ///   }
    /// }
    /// ```
    private static func parseReportOutput(
        _ data: Data, timeRange: DashboardTimeRange, timezone: String
    ) throws -> TimeSeriesData {
        let text = try Self.extractJson(from: data)
        let decoder = JSONDecoder()

        // Try new format first
        if let jsonData = text.data(using: .utf8),
           let report = try? decoder.decode(TokiReportV2.self, from: jsonData) {
            return try parseV2(report, timeRange: timeRange, timezone: timezone)
        }

        // Fallback: try legacy format (concatenated JSON objects)
        return try parseLegacy(text, timeRange: timeRange, timezone: timezone)
    }

    private static func parseV2(
        _ report: TokiReportV2, timeRange: DashboardTimeRange, timezone: String
    ) throws -> TimeSeriesData {
        let tz = TimeZone(identifier: timezone) ?? .current

        let hourFormatter = DateFormatter()
        hourFormatter.locale = Locale(identifier: "en_US_POSIX")
        hourFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        hourFormatter.timeZone = tz

        let hourFormatterLong = DateFormatter()
        hourFormatterLong.locale = Locale(identifier: "en_US_POSIX")
        hourFormatterLong.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        hourFormatterLong.timeZone = tz

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = tz

        var pointsByDate: [Date: [TokiModelSummary]] = [:]

        for (_, entries) in report.providers {
            for entry in entries {
                guard let periodStr = entry.period,
                      let models = entry.usagePerModels
                else { continue }

                // Strip model suffix from PromQL period: "2026-03-21T14:00|model-name"
                let dateStr: String
                if let pipeIndex = periodStr.firstIndex(of: "|") {
                    dateStr = String(periodStr[..<pipeIndex])
                } else {
                    dateStr = periodStr
                }

                // Try multiple date formats
                let date: Date?
                if dateStr.contains("T") {
                    date = hourFormatter.date(from: dateStr)
                        ?? hourFormatterLong.date(from: dateStr)
                } else {
                    date = dayFormatter.date(from: dateStr)
                }

                guard let parsedDate = date else { continue }
                pointsByDate[parsedDate, default: []].append(contentsOf: models)
            }
        }

        var points = pointsByDate.map { date, models in
            TimeSeriesPoint(date: date, models: models)
        }.sorted { $0.date < $1.date }

        points = gapFill(points: points, timeRange: timeRange, timezone: timezone)
        return TimeSeriesData(points: points, granularity: timeRange.granularity)
    }

    /// Parse legacy concatenated JSON format (fallback)
    private static func parseLegacy(
        _ text: String, timeRange: DashboardTimeRange, timezone: String
    ) throws -> TimeSeriesData {
        let decoder = JSONDecoder()
        let jsonObjects = splitJsonObjects(text)

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
                  let report = try? decoder.decode(TokiCliReportLegacy.self, from: jsonData)
            else { continue }

            for entry in report.data {
                guard let periodStr = entry.period, let models = entry.usagePerModels else { continue }
                let dateStr = periodStr.contains("|")
                    ? String(periodStr[..<periodStr.firstIndex(of: "|")!])
                    : periodStr
                let date = dateStr.contains("T")
                    ? hourFormatter.date(from: dateStr)
                    : dayFormatter.date(from: dateStr)
                guard let d = date else { continue }
                pointsByDate[d, default: []].append(contentsOf: models)
            }
        }

        var points = pointsByDate.map { TimeSeriesPoint(date: $0.key, models: $0.value) }
            .sorted { $0.date < $1.date }
        points = gapFill(points: points, timeRange: timeRange, timezone: timezone)
        return TimeSeriesData(points: points, granularity: timeRange.granularity)
    }

    /// Parse legacy flat output (for queryAllSummaries).
    private static func parseFlatOutput(_ data: Data) throws -> [TokiModelSummary] {
        let text = try extractJson(from: data)
        let decoder = JSONDecoder()

        // Try V2 format
        if let jsonData = text.data(using: .utf8),
           let report = try? decoder.decode(TokiReportV2.self, from: jsonData) {
            var all: [TokiModelSummary] = []
            for (_, entries) in report.providers {
                for entry in entries {
                    if let models = entry.usagePerModels {
                        all.append(contentsOf: models)
                    }
                }
            }
            return all
        }

        // Legacy format
        var allSummaries: [TokiModelSummary] = []
        for jsonStr in splitJsonObjects(text) {
            guard let jsonData = jsonStr.data(using: .utf8),
                  let report = try? decoder.decode(TokiCliReportLegacy.self, from: jsonData)
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

    /// Extract JSON from toki output, skipping "[toki]" log lines.
    private static func extractJson(from data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReportError.parseFailed("Invalid UTF-8")
        }
        // Skip lines starting with "[toki]" (e.g., "[toki] Pricing: not modified")
        let lines = text.components(separatedBy: "\n")
        let jsonLines = lines.filter { !$0.hasPrefix("[toki]") }
        return jsonLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
                    if next < text.endIndex { start = next }
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

// JSON structures defined in TokenAggregator.swift:
// TokiReportV2, TokiReportInfo, TokiCliEntry, TokiCliReportLegacy
