import Foundation

/// Per-model usage summary from toki report.
/// Fields vary by provider schema:
/// - claude_code: cache_creation_input_tokens, cache_read_input_tokens
/// - codex: cached_input_tokens, reasoning_output_tokens
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
