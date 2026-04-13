import Foundation
import Testing
@testable import TokiMonitor

@Suite("TokiReportClient")
struct TokiReportClientTests {

    @Test("Parse TokiModelSummary with Claude fields")
    func parseClaudeSummary() throws {
        let json = """
        {"model":"claude-opus-4-6","input_tokens":5000,"output_tokens":2000,"cache_creation_input_tokens":1000,"cache_read_input_tokens":3000,"total_tokens":11000,"events":25,"cost_usd":0.15}
        """
        let summary = try JSONDecoder().decode(TokiModelSummary.self, from: json.data(using: .utf8)!)
        #expect(summary.model == "claude-opus-4-6")
        #expect(summary.totalTokens == 11000)
        #expect(summary.cacheCreationInputTokens == 1000)
        #expect(summary.costUsd == 0.15)
    }

    @Test("Parse TokiModelSummary with Codex fields")
    func parseCodexSummary() throws {
        let json = """
        {"model":"gpt-5.4","input_tokens":500,"output_tokens":250,"cached_input_tokens":50,"reasoning_output_tokens":25,"total_tokens":825,"events":3,"cost_usd":0.05}
        """
        let summary = try JSONDecoder().decode(TokiModelSummary.self, from: json.data(using: .utf8)!)
        #expect(summary.model == "gpt-5.4")
        #expect(summary.cachedInputTokens == 50)
        #expect(summary.reasoningOutputTokens == 25)
    }

    @Test("ProviderRegistry resolves schema names")
    func resolveSchema() {
        #expect(ProviderRegistry.resolveSchema("claude_code").id == "anthropic")
        #expect(ProviderRegistry.resolveSchema("codex").id == "openai")
        #expect(ProviderRegistry.resolveSchema("unknown_provider").id == "unknown")
    }

}
