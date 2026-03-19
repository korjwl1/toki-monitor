import Foundation

/// Raw event received from toki UDS trace stream.
/// Format: {"type":"event","data":{...}}
struct TokiEventEnvelope: Codable {
    let type: String
    let data: TokiEventData
}

struct TokiEventData: Codable {
    let model: String
    let source: String
    let provider: String?         // "Claude Code", "Codex CLI"
    let timestamp: String?        // ISO 8601 from session file
    let inputTokens: UInt64
    let outputTokens: UInt64
    let totalTokens: UInt64?
    let costUsd: Double?

    // Claude Code specific
    let cacheCreationInputTokens: UInt64?
    let cacheReadInputTokens: UInt64?

    // Codex specific
    let cachedInputTokens: UInt64?
    let reasoningOutputTokens: UInt64?

    enum CodingKeys: String, CodingKey {
        case model, source, provider, timestamp
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

/// Domain-friendly token event with client-side metadata.
struct TokenEvent: Identifiable {
    let id: UUID
    let model: String
    let source: String
    let providerName: String?
    let inputTokens: UInt64
    let outputTokens: UInt64
    let cacheCreationInputTokens: UInt64
    let cacheReadInputTokens: UInt64
    let cachedInputTokens: UInt64
    let reasoningOutputTokens: UInt64
    let costUSD: Double?
    let receivedAt: Date
    let originalTimestamp: String?

    var totalTokens: UInt64 {
        inputTokens + outputTokens + cacheCreationInputTokens
        + cacheReadInputTokens + cachedInputTokens + reasoningOutputTokens
    }

    init(from data: TokiEventData) {
        self.id = UUID()
        self.model = data.model
        self.source = data.source
        self.providerName = data.provider
        self.inputTokens = data.inputTokens
        self.outputTokens = data.outputTokens
        self.cacheCreationInputTokens = data.cacheCreationInputTokens ?? 0
        self.cacheReadInputTokens = data.cacheReadInputTokens ?? 0
        self.cachedInputTokens = data.cachedInputTokens ?? 0
        self.reasoningOutputTokens = data.reasoningOutputTokens ?? 0
        self.costUSD = data.costUsd
        self.receivedAt = Date()
        self.originalTimestamp = data.timestamp
    }
}
