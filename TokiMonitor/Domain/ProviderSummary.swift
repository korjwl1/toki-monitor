import SwiftUI

/// Aggregated token usage for a single provider over a time range.
struct ProviderSummary: Identifiable, TokenUsageModel {
    let id: String
    let provider: ProviderInfo
    var totalInput: UInt64 = 0
    var totalOutput: UInt64 = 0
    var estimatedCost: Double? = nil
    var eventCount: Int = 0

    var displayName: String { provider.name }
    var totalTokens: UInt64 { totalInput + totalOutput }

    init(provider: ProviderInfo) {
        self.id = provider.id
        self.provider = provider
    }

    mutating func add(event: TokenEvent) {
        totalInput += event.inputTokens
        totalOutput += event.outputTokens
        eventCount += 1
        if let cost = event.costUSD {
            estimatedCost = (estimatedCost ?? 0) + cost
        }
    }
}

/// Total summary across all providers.
struct TotalSummary: TokenUsageModel {
    var totalInput: UInt64 = 0
    var totalOutput: UInt64 = 0
    var estimatedCost: Double? = nil
    var eventCount: Int = 0
    var providerCount: Int = 0

    var displayName: String { "Total" }
    var totalTokens: UInt64 { totalInput + totalOutput }

    init(from summaries: [ProviderSummary]) {
        providerCount = summaries.count
        for s in summaries {
            totalInput += s.totalInput
            totalOutput += s.totalOutput
            eventCount += s.eventCount
            if let cost = s.estimatedCost {
                estimatedCost = (estimatedCost ?? 0) + cost
            }
        }
    }
}
