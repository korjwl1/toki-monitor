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
    let inputTokens: UInt64
    let outputTokens: UInt64
    let cacheCreationInputTokens: UInt64
    let cacheReadInputTokens: UInt64
    let costUsd: Double?

    enum CodingKeys: String, CodingKey {
        case model, source
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case costUsd = "cost_usd"
    }
}

/// Domain-friendly token event with client-side metadata.
struct TokenEvent: Identifiable {
    let id: UUID
    let model: String
    let source: String
    let inputTokens: UInt64
    let outputTokens: UInt64
    let cacheCreationInputTokens: UInt64
    let cacheReadInputTokens: UInt64
    let costUSD: Double?
    let receivedAt: Date

    var totalTokens: UInt64 {
        inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    init(from data: TokiEventData) {
        self.id = UUID()
        self.model = data.model
        self.source = data.source
        self.inputTokens = data.inputTokens
        self.outputTokens = data.outputTokens
        self.cacheCreationInputTokens = data.cacheCreationInputTokens
        self.cacheReadInputTokens = data.cacheReadInputTokens
        self.costUSD = data.costUsd
        self.receivedAt = Date()
    }
}
