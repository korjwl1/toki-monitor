import Foundation
import Testing
@testable import TokiMonitor

@Suite("TokiReportClient Response Parsing")
struct TokiReportClientTests {

    @Test("Parse per-provider tagged summary response")
    func parsePerProviderSummary() throws {
        let json = """
        {"ok":true,"data":[{"type":"summary","schema":"claude_code","data":[{"model":"claude-opus-4-6","input_tokens":5000,"output_tokens":2000,"cache_creation_input_tokens":1000,"cache_read_input_tokens":3000,"total_tokens":11000,"events":25,"cost_usd":0.15}]},{"type":"summary","schema":"codex","data":[{"model":"gpt-5.4","input_tokens":500,"output_tokens":250,"cached_input_tokens":50,"reasoning_output_tokens":25,"total_tokens":825,"events":3,"cost_usd":0.05}]}]}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokiReportResponse.self, from: data)

        #expect(response.ok == true)
        #expect(response.data?.count == 2)

        // Claude Code item
        let claude = response.data![0]
        #expect(claude.schema == "claude_code")
        #expect(claude.data?.first?.model == "claude-opus-4-6")
        #expect(claude.data?.first?.cacheCreationInputTokens == 1000)
        #expect(claude.data?.first?.cacheReadInputTokens == 3000)

        // Codex item
        let codex = response.data![1]
        #expect(codex.schema == "codex")
        #expect(codex.data?.first?.model == "gpt-5.4")
        #expect(codex.data?.first?.cachedInputTokens == 50)
        #expect(codex.data?.first?.reasoningOutputTokens == 25)
    }

    @Test("Parse response without schema (backward compat)")
    func parseWithoutSchema() throws {
        let json = """
        {"ok":true,"data":[{"type":"summary","data":[{"model":"claude-opus-4-6","input_tokens":1000,"output_tokens":500,"total_tokens":1500,"events":5}]}]}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokiReportResponse.self, from: data)

        #expect(response.ok == true)
        #expect(response.data?.first?.schema == nil)
        let summary = response.data?.first?.data?.first
        #expect(summary?.model == "claude-opus-4-6")
        #expect(summary?.cacheCreationInputTokens == nil)
        #expect(summary?.cachedInputTokens == nil)
    }

    @Test("Parse empty summary response")
    func parseEmptySummary() throws {
        let json = """
        {"ok":true,"data":[{"type":"summary","schema":"claude_code","data":[]}]}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokiReportResponse.self, from: data)

        #expect(response.ok == true)
        let summaries = response.data?.compactMap(\.data).flatMap { $0 } ?? []
        #expect(summaries.isEmpty)
    }

    @Test("ProviderRegistry resolves schema names")
    func resolveSchema() {
        let claude = ProviderRegistry.resolveSchema("claude_code")
        #expect(claude.id == "anthropic")

        let codex = ProviderRegistry.resolveSchema("codex")
        #expect(codex.id == "openai")

        let unknown = ProviderRegistry.resolveSchema("unknown_provider")
        #expect(unknown.id == "unknown")
    }

    @Test("ReportPeriod query bucket values")
    func reportPeriodBuckets() {
        #expect(ReportPeriod.daily.queryBucket == "1d")
        #expect(ReportPeriod.weekly.queryBucket == "1w")
        #expect(ReportPeriod.monthly.queryBucket == "30d")
    }
}
