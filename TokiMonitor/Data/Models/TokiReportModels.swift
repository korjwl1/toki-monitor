import Foundation

/// Per-model usage summary from toki report.
struct TokiModelSummary: Codable, Identifiable {
    var id: String { model }
    let model: String
    let inputTokens: UInt64
    let outputTokens: UInt64
    let totalTokens: UInt64
    let events: Int
    let costUsd: Double?

    // Claude Code specific
    let cacheCreationInputTokens: UInt64?
    let cacheReadInputTokens: UInt64?

    // Codex specific
    let cachedInputTokens: UInt64?
    let reasoningOutputTokens: UInt64?

    enum CodingKeys: String, CodingKey {
        case model, events
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case costUsd = "cost_usd"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
    }
}

// MARK: - Report JSON Structures

/// V2 format: `{"information": {...}, "providers": {"claude_code": [...]}}`
struct TokiReportV2: Codable {
    let information: TokiReportInfo?
    let providers: [String: [TokiReportEntry]]
}

struct TokiReportInfo: Codable {
    let type: String?
    let since: String?
    let until: String?
    let timezone: String?
}

/// Shared entry used by both V2 and legacy formats.
struct TokiReportEntry: Codable {
    let period: String?
    let session: String?
    let usagePerModels: [TokiModelSummary]?

    enum CodingKeys: String, CodingKey {
        case period, session
        case usagePerModels = "usage_per_models"
    }
}

/// Legacy format: `{"data": [...], "type": "every 1h"}`
struct TokiReportLegacy: Codable {
    let data: [TokiReportEntry]
    let type: String?
}

// MARK: - Report Parsing Utilities

enum TokiReportParser {
    /// Skip `[toki]` log lines from CLI output.
    static func extractJson(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("[toki]") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split concatenated JSON objects: `{...}\n{...}` → ["{...}", "{...}"]
    static func splitJsonObjects(_ text: String) -> [String] {
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

    /// Parse period string from PromQL/report, extracting date portion.
    /// Handles: "2026-03-21T14:00|model-name" → "2026-03-21T14:00"
    static func extractDateString(from period: String) -> String {
        if let pipe = period.firstIndex(of: "|") {
            return String(period[..<pipe])
        }
        return period
    }

    /// Shared UTC date formatters for toki report periods.
    static let utcFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"].map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = fmt
            return f
        }
    }()

    /// Parse a period date string to Date using UTC formatters.
    static func parseDate(_ dateStr: String) -> Date? {
        for fmt in utcFormatters {
            if let d = fmt.date(from: dateStr) { return d }
        }
        return nil
    }

    /// Extract label portion after `|` in period string (model or project name).
    /// e.g. "2026-03-29T08:00:00|claude-opus-4-6" → "claude-opus-4-6"
    static func extractLabel(from period: String) -> String? {
        guard let pipe = period.firstIndex(of: "|") else { return nil }
        let label = String(period[period.index(after: pipe)...])
        return label.isEmpty ? nil : label
    }

    /// Parse entries into a date-keyed dictionary of model summaries.
    /// When the PromQL `sum by (model)` query returns "(total)" as the model name,
    /// the actual model/label name is extracted from the period string after the `|`.
    static func parseEntries(
        _ entries: [TokiReportEntry],
        into pointsByDate: inout [Date: [TokiModelSummary]]
    ) {
        for entry in entries {
            guard let periodStr = entry.period,
                  let models = entry.usagePerModels else { continue }
            let dateStr = extractDateString(from: periodStr)
            guard let date = parseDate(dateStr) else { continue }
            let periodLabel = extractLabel(from: periodStr)
            let resolved = models.map { summary -> TokiModelSummary in
                var correctedModel = summary.model
                // PromQL aggregation produces "(total)" — recover real name from period label
                if correctedModel == "(total)", let label = periodLabel {
                    correctedModel = label
                }
                // Compute cost client-side when not provided by CLI
                let cost = summary.costUsd ?? ModelPricing.estimateCost(
                    model: correctedModel,
                    inputTokens: summary.inputTokens,
                    outputTokens: summary.outputTokens,
                    cacheCreationInputTokens: summary.cacheCreationInputTokens,
                    cacheReadInputTokens: summary.cacheReadInputTokens,
                    cachedInputTokens: summary.cachedInputTokens
                )
                return TokiModelSummary(
                    model: correctedModel,
                    inputTokens: summary.inputTokens,
                    outputTokens: summary.outputTokens,
                    totalTokens: summary.totalTokens,
                    events: summary.events,
                    costUsd: cost,
                    cacheCreationInputTokens: summary.cacheCreationInputTokens,
                    cacheReadInputTokens: summary.cacheReadInputTokens,
                    cachedInputTokens: summary.cachedInputTokens,
                    reasoningOutputTokens: summary.reasoningOutputTokens
                )
            }
            pointsByDate[date, default: []].append(contentsOf: resolved)
        }
    }

    /// Parse report data (V2 or legacy) into date-keyed dictionary.
    static func parseReport(_ data: Data) -> [Date: [TokiModelSummary]] {
        guard let jsonText = extractJson(from: data) else { return [:] }

        let decoder = JSONDecoder()
        var pointsByDate: [Date: [TokiModelSummary]] = [:]

        // Try V2 format
        if let jsonData = jsonText.data(using: .utf8),
           let report = try? decoder.decode(TokiReportV2.self, from: jsonData) {
            for (_, entries) in report.providers {
                parseEntries(entries, into: &pointsByDate)
            }
            return pointsByDate
        }

        // Legacy format (concatenated JSON objects)
        for jsonStr in splitJsonObjects(jsonText) {
            guard let jsonData = jsonStr.data(using: .utf8),
                  let report = try? decoder.decode(TokiReportLegacy.self, from: jsonData)
            else { continue }
            parseEntries(report.data, into: &pointsByDate)
        }
        return pointsByDate
    }

    /// Parse report data into flat model summaries.
    static func parseFlatSummaries(_ data: Data) -> [TokiModelSummary] {
        let pointsByDate = parseReport(data)
        return pointsByDate.values.flatMap { $0 }
    }
}
