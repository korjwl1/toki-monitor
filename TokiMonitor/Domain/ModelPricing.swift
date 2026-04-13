import Foundation

/// Client-side cost estimation for models when the CLI PromQL query
/// path does not include `cost_usd` in its output.
///
/// Prices are per-token (not per-million-tokens) for direct multiplication.
/// Source: Official API pricing pages as of 2025-Q4. Updated periodically.
enum ModelPricing {
    struct Pricing {
        let inputPerToken: Double
        let outputPerToken: Double
        let cacheWritePerToken: Double?
        let cacheReadPerToken: Double?
    }

    // Per-million-token prices converted to per-token
    private static let pricingTable: [(prefix: String, pricing: Pricing)] = [
        // Anthropic Claude
        ("claude-opus-4", Pricing(
            inputPerToken: 15.0 / 1_000_000,
            outputPerToken: 75.0 / 1_000_000,
            cacheWritePerToken: 18.75 / 1_000_000,
            cacheReadPerToken: 1.50 / 1_000_000
        )),
        ("claude-sonnet-4", Pricing(
            inputPerToken: 3.0 / 1_000_000,
            outputPerToken: 15.0 / 1_000_000,
            cacheWritePerToken: 3.75 / 1_000_000,
            cacheReadPerToken: 0.30 / 1_000_000
        )),
        ("claude-3-7-sonnet", Pricing(
            inputPerToken: 3.0 / 1_000_000,
            outputPerToken: 15.0 / 1_000_000,
            cacheWritePerToken: 3.75 / 1_000_000,
            cacheReadPerToken: 0.30 / 1_000_000
        )),
        ("claude-3-5-sonnet", Pricing(
            inputPerToken: 3.0 / 1_000_000,
            outputPerToken: 15.0 / 1_000_000,
            cacheWritePerToken: 3.75 / 1_000_000,
            cacheReadPerToken: 0.30 / 1_000_000
        )),
        ("claude-3-5-haiku", Pricing(
            inputPerToken: 0.80 / 1_000_000,
            outputPerToken: 4.0 / 1_000_000,
            cacheWritePerToken: 1.0 / 1_000_000,
            cacheReadPerToken: 0.08 / 1_000_000
        )),
        ("claude-3-haiku", Pricing(
            inputPerToken: 0.25 / 1_000_000,
            outputPerToken: 1.25 / 1_000_000,
            cacheWritePerToken: 0.30 / 1_000_000,
            cacheReadPerToken: 0.03 / 1_000_000
        )),
        // Fallback Claude
        ("claude-", Pricing(
            inputPerToken: 3.0 / 1_000_000,
            outputPerToken: 15.0 / 1_000_000,
            cacheWritePerToken: 3.75 / 1_000_000,
            cacheReadPerToken: 0.30 / 1_000_000
        )),
        // OpenAI
        ("gpt-4o", Pricing(
            inputPerToken: 2.50 / 1_000_000,
            outputPerToken: 10.0 / 1_000_000,
            cacheWritePerToken: nil,
            cacheReadPerToken: 1.25 / 1_000_000
        )),
        ("gpt-4-turbo", Pricing(
            inputPerToken: 10.0 / 1_000_000,
            outputPerToken: 30.0 / 1_000_000,
            cacheWritePerToken: nil,
            cacheReadPerToken: nil
        )),
        ("o3", Pricing(
            inputPerToken: 10.0 / 1_000_000,
            outputPerToken: 40.0 / 1_000_000,
            cacheWritePerToken: nil,
            cacheReadPerToken: 2.50 / 1_000_000
        )),
        ("o1", Pricing(
            inputPerToken: 15.0 / 1_000_000,
            outputPerToken: 60.0 / 1_000_000,
            cacheWritePerToken: nil,
            cacheReadPerToken: 7.50 / 1_000_000
        )),
        // Google Gemini
        ("gemini-2.0-flash", Pricing(
            inputPerToken: 0.10 / 1_000_000,
            outputPerToken: 0.40 / 1_000_000,
            cacheWritePerToken: nil,
            cacheReadPerToken: nil
        )),
        ("gemini-1.5-pro", Pricing(
            inputPerToken: 1.25 / 1_000_000,
            outputPerToken: 5.0 / 1_000_000,
            cacheWritePerToken: nil,
            cacheReadPerToken: nil
        )),
    ]

    /// Estimate cost from token breakdown. Returns nil if model is unknown.
    static func estimateCost(
        model: String,
        inputTokens: UInt64,
        outputTokens: UInt64,
        cacheCreationInputTokens: UInt64? = nil,
        cacheReadInputTokens: UInt64? = nil,
        cachedInputTokens: UInt64? = nil
    ) -> Double? {
        let lower = model.lowercased()
        guard let pricing = pricingTable.first(where: { lower.hasPrefix($0.prefix) })?.pricing else {
            return nil
        }

        var cost = 0.0

        // Cache write tokens (billed at cache write rate, not input rate)
        if let cacheWrite = cacheCreationInputTokens, cacheWrite > 0,
           let cacheWritePrice = pricing.cacheWritePerToken {
            cost += Double(cacheWrite) * cacheWritePrice
        }

        // Cache read tokens (billed at discounted rate)
        let cacheRead = (cacheReadInputTokens ?? 0) + (cachedInputTokens ?? 0)
        if cacheRead > 0, let cacheReadPrice = pricing.cacheReadPerToken {
            cost += Double(cacheRead) * cacheReadPrice
        }

        // Regular input tokens (excluding cache tokens which are billed separately)
        cost += Double(inputTokens) * pricing.inputPerToken

        // Output tokens
        cost += Double(outputTokens) * pricing.outputPerToken

        return cost
    }
}
