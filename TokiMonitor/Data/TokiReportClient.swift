import Foundation

/// Runs `toki report` CLI commands and parses JSON output.
final class TokiReportClient: Sendable {
    private let runner: TokiReportRunner

    init(runner: TokiReportRunner = TokiReportRunner()) {
        self.runner = runner
    }

    /// Query toki report for a given period, returns flat list of model summaries.
    func queryAllSummaries(
        period: ReportPeriod,
        timezone: String = TimeZone.current.identifier,
        completion: @escaping @Sendable (Result<[TokiModelSummary], Error>) -> Void
    ) {
        // toki report [report-level-options] <subcommand> [subcommand-options]
        // Report-level: --output-format, -z, --no-cost, --provider
        // Subcommand-level: --since, --until, --project, --session-id
        let reportOptions: [String] = ["-z", timezone]
        let subcommandArgs: [String] = [period.subcommand, "--since", period.sinceDate]

        runner.runReport(reportOptions: reportOptions, subcommandArgs: subcommandArgs) { result in
            switch result {
            case .success(let data):
                do {
                    let summaries = try Self.parseCliOutput(data)
                    completion(.success(summaries))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Parse toki CLI JSON output.
    /// CLI may output multiple JSON objects (one per provider), each with
    /// `{"data": [{"period": "...", "usage_per_models": [...]}], "type": "..."}`.
    private static func parseCliOutput(_ data: Data) throws -> [TokiModelSummary] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReportError.parseFailed("Invalid UTF-8")
        }

        var allSummaries: [TokiModelSummary] = []
        let decoder = JSONDecoder()

        // Split on `}\n{` to handle multiple JSON objects concatenated
        // First try single JSON parse
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonObjects = splitJsonObjects(trimmed)

        for jsonStr in jsonObjects {
            guard let jsonData = jsonStr.data(using: .utf8) else { continue }
            guard let report = try? decoder.decode(TokiCliReport.self, from: jsonData) else { continue }

            for entry in report.data {
                if let models = entry.usagePerModels {
                    allSummaries.append(contentsOf: models)
                }
            }
        }

        return allSummaries
    }

    /// Split concatenated JSON objects: `{...}\n{...}` → ["{...}", "{...}"]
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
