import Foundation

/// Request sent to toki daemon for report queries.
/// Format: {"query":"usage[1h]","tz":"Asia/Seoul"}
struct TokiReportRequest: Codable {
    let query: String
    let tz: String?
}

/// Top-level response from toki report query.
struct TokiReportResponse: Codable {
    let ok: Bool
    let data: [TokiReportItem]?
    let error: String?
}

/// Individual item in a report response.
struct TokiReportItem: Codable {
    let type: String
    let data: [TokiModelSummary]?
    let items: [String]?
}

/// Per-model usage summary from toki report.
struct TokiModelSummary: Codable, Identifiable {
    var id: String { model }
    let model: String
    let inputTokens: UInt64
    let outputTokens: UInt64
    let cacheCreationInputTokens: UInt64
    let cacheReadInputTokens: UInt64
    let totalTokens: UInt64
    let events: Int
    let costUsd: Double?

    enum CodingKeys: String, CodingKey {
        case model, events
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case totalTokens = "total_tokens"
        case costUsd = "cost_usd"
    }
}
