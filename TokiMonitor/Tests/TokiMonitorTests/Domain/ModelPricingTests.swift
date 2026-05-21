import Testing
@testable import TokiMonitor

@Suite("ModelPricing")
struct ModelPricingTests {

    // MARK: - Base prefix matching

    @Test("Known model prefix matches base pricing")
    func baseModelMatch() {
        // 1M input * ($15/1M) = $15
        let cost = ModelPricing.estimateCost(
            model: "claude-opus-4-7",
            inputTokens: 1_000_000,
            outputTokens: 0
        )
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - 15.0) < 1e-9)
    }

    @Test("Unknown model returns nil")
    func unknownModelIsNil() {
        let cost = ModelPricing.estimateCost(
            model: "totally-unknown-model",
            inputTokens: 1_000,
            outputTokens: 1_000
        )
        #expect(cost == nil)
    }

    // MARK: - Fast mode multiplier

    @Test("-fast suffix applies 6x multiplier for opus-4-7")
    func fastSuffixOpus47() {
        let base = ModelPricing.estimateCost(
            model: "claude-opus-4-7",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000
        ) ?? 0
        let fast = ModelPricing.estimateCost(
            model: "claude-opus-4-7-fast",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000
        ) ?? 0
        #expect(abs(fast - base * 6.0) < 1e-9)
    }

    @Test("-fast suffix applies 6x multiplier for opus-4-6")
    func fastSuffixOpus46() {
        let base = ModelPricing.estimateCost(
            model: "claude-opus-4-6",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000
        ) ?? 0
        let fast = ModelPricing.estimateCost(
            model: "claude-opus-4-6-fast",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000
        ) ?? 0
        #expect(abs(fast - base * 6.0) < 1e-9)
    }

    @Test("-fast on unsupported base falls back to prefix match (no multiplier)")
    func fastSuffixUnsupportedBase() {
        // claude-sonnet-4 is not in the fast multiplier table — the suffix
        // strip is skipped and the full "claude-sonnet-4-fast" string flows
        // into the prefix matcher (matches "claude-sonnet-4" base, no 6x).
        let base = ModelPricing.estimateCost(
            model: "claude-sonnet-4",
            inputTokens: 1_000_000,
            outputTokens: 0
        ) ?? 0
        let fast = ModelPricing.estimateCost(
            model: "claude-sonnet-4-fast",
            inputTokens: 1_000_000,
            outputTokens: 0
        ) ?? 0
        #expect(abs(fast - base) < 1e-9)
    }

    @Test("Cache tokens are also scaled by fast multiplier")
    func fastScalesCacheTokens() {
        let base = ModelPricing.estimateCost(
            model: "claude-opus-4-7",
            inputTokens: 100,
            outputTokens: 200,
            cacheCreationInputTokens: 1_000,
            cacheReadInputTokens: 10_000
        ) ?? 0
        let fast = ModelPricing.estimateCost(
            model: "claude-opus-4-7-fast",
            inputTokens: 100,
            outputTokens: 200,
            cacheCreationInputTokens: 1_000,
            cacheReadInputTokens: 10_000
        ) ?? 0
        #expect(abs(fast - base * 6.0) < 1e-9)
    }
}
