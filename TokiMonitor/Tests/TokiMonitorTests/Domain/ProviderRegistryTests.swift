import Testing
@testable import TokiMonitor

@Suite("ProviderRegistry")
struct ProviderRegistryTests {

    @Test("Claude models resolve to Anthropic")
    func claudeModels() {
        let result = ProviderRegistry.resolve(model: "claude-opus-4-6")
        #expect(result.id == "anthropic")
        #expect(result.name == "Claude")

        let result2 = ProviderRegistry.resolve(model: "claude-3-5-sonnet-20241022")
        #expect(result2.id == "anthropic")
    }

    @Test("Gemini models resolve to Google")
    func geminiModels() {
        let result = ProviderRegistry.resolve(model: "gemini-1.5-pro")
        #expect(result.id == "google")
        #expect(result.name == "Gemini")
    }

    @Test("GPT models resolve to OpenAI")
    func gptModels() {
        let result = ProviderRegistry.resolve(model: "gpt-4o")
        #expect(result.id == "openai")

        let result2 = ProviderRegistry.resolve(model: "o1-preview")
        #expect(result2.id == "openai")

        let result3 = ProviderRegistry.resolve(model: "o3-mini")
        #expect(result3.id == "openai")
    }

    @Test("Unknown model resolves to unknown")
    func unknownModel() {
        let result = ProviderRegistry.resolve(model: "llama-3.1-70b")
        #expect(result.id == "unknown")
        #expect(result.name == "Other")
    }

    @Test("Case insensitive matching")
    func caseInsensitive() {
        let result = ProviderRegistry.resolve(model: "Claude-opus-4-6")
        #expect(result.id == "anthropic")
    }
}

@Suite("ProviderSummary")
struct ProviderSummaryTests {
    @Test("Add events accumulates tokens and cost")
    func addEvents() {
        let provider = ProviderRegistry.resolve(model: "claude-opus-4-6")
        var summary = ProviderSummary(provider: provider)

        let event1 = TokenEvent(from: TokiEventData(
            model: "claude-opus-4-6", source: "test",
            inputTokens: 100, outputTokens: 50,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
            costUsd: 0.01
        ))
        let event2 = TokenEvent(from: TokiEventData(
            model: "claude-opus-4-6", source: "test",
            inputTokens: 200, outputTokens: 100,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
            costUsd: 0.02
        ))

        summary.add(event: event1)
        summary.add(event: event2)

        #expect(summary.totalInput == 300)
        #expect(summary.totalOutput == 150)
        #expect(summary.estimatedCost == 0.03)
        #expect(summary.eventCount == 2)
    }

    @Test("TotalSummary aggregates across providers")
    func totalSummary() {
        let claude = ProviderRegistry.resolve(model: "claude-opus-4-6")
        var s1 = ProviderSummary(provider: claude)
        s1.add(event: TokenEvent(from: TokiEventData(
            model: "claude-opus-4-6", source: "t",
            inputTokens: 100, outputTokens: 50,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
            costUsd: 0.01
        )))

        let gemini = ProviderRegistry.resolve(model: "gemini-1.5-pro")
        var s2 = ProviderSummary(provider: gemini)
        s2.add(event: TokenEvent(from: TokiEventData(
            model: "gemini-1.5-pro", source: "t",
            inputTokens: 200, outputTokens: 100,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
            costUsd: 0.005
        )))

        let total = TotalSummary(from: [s1, s2])
        #expect(total.totalInput == 300)
        #expect(total.totalOutput == 150)
        #expect(total.estimatedCost == 0.015)
        #expect(total.providerCount == 2)
        #expect(total.eventCount == 2)
    }
}
