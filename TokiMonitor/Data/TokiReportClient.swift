import Foundation

/// Raw result from a report query, tagged with schema name.
struct SchemaTaggedSummary: Sendable {
    let schema: String
    let summaries: [TokiModelSummary]
}

/// Runs `toki report` CLI commands and parses JSON output.
final class TokiReportClient: Sendable {
    private let runner: TokiReportRunner

    init(runner: TokiReportRunner = TokiReportRunner()) {
        self.runner = runner
    }

    /// Query toki for usage summary via CLI.
    func querySummary(
        timeRange: TimeRange,
        provider: String? = nil,
        timezone: String = TimeZone.current.identifier,
        completion: @escaping @Sendable (Result<[SchemaTaggedSummary], Error>) -> Void
    ) {
        var args: [String] = []

        // Subcommand based on time range
        switch timeRange {
        case .thirtyMinutes:
            args += ["hourly"]
        case .oneHour:
            args += ["hourly"]
        case .today:
            args += ["daily"]
        }

        args += ["-z", timezone]

        if let provider {
            args += ["--provider", provider]
        }

        runner.runReport(args: args) { result in
            switch result {
            case .success(let data):
                do {
                    let response = try JSONDecoder().decode(TokiReportResponse.self, from: data)
                    guard response.ok else {
                        completion(.failure(ReportError.queryFailed(response.error ?? "Unknown error")))
                        return
                    }
                    let tagged = response.data?.compactMap { item -> SchemaTaggedSummary? in
                        guard let summaries = item.data, !summaries.isEmpty else { return nil }
                        return SchemaTaggedSummary(schema: item.schema ?? "unknown", summaries: summaries)
                    } ?? []
                    completion(.success(tagged))
                } catch {
                    // CLI might output non-JSON (table format fallback)
                    // Try parsing as raw array
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Flat query — merges all schemas into one list.
    func queryAllSummaries(
        timeRange: TimeRange,
        timezone: String = TimeZone.current.identifier,
        completion: @escaping @Sendable (Result<[TokiModelSummary], Error>) -> Void
    ) {
        querySummary(timeRange: timeRange, timezone: timezone) { result in
            switch result {
            case .success(let tagged):
                completion(.success(tagged.flatMap(\.summaries)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    enum ReportError: Error, LocalizedError {
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .queryFailed(let msg): "Report query failed: \(msg)"
            }
        }
    }
}
