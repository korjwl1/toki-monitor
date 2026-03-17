import Foundation
import Testing
@testable import TokiMonitor

@Suite("TokiReportClient Response Parsing")
struct TokiReportClientTests {

    @Test("Parse summary response with multiple models")
    func parseSummaryMultiModel() throws {
        let json = """
        {"ok":true,"data":[{"type":"summary","data":[{"model":"claude-opus-4-6","input_tokens":5000,"output_tokens":2000,"cache_creation_input_tokens":1000,"cache_read_input_tokens":3000,"total_tokens":11000,"events":25,"cost_usd":0.15},{"model":"gemini-1.5-pro","input_tokens":3000,"output_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"total_tokens":4000,"events":10,"cost_usd":0.02}]}]}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokiReportResponse.self, from: data)

        #expect(response.ok == true)
        let summaries = response.data?.compactMap(\.data).flatMap { $0 } ?? []
        #expect(summaries.count == 2)
        #expect(summaries[0].model == "claude-opus-4-6")
        #expect(summaries[0].totalTokens == 11000)
        #expect(summaries[1].model == "gemini-1.5-pro")
        #expect(summaries[1].costUsd == 0.02)
    }

    @Test("Parse empty summary response")
    func parseEmptySummary() throws {
        let json = """
        {"ok":true,"data":[{"type":"summary","data":[]}]}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokiReportResponse.self, from: data)

        #expect(response.ok == true)
        let summaries = response.data?.compactMap(\.data).flatMap { $0 } ?? []
        #expect(summaries.isEmpty)
    }

    @Test("Parse grouped response (hourly)")
    func parseGroupedResponse() throws {
        let json = """
        {"ok":true,"data":[{"type":"hourly","data":[{"model":"claude-opus-4-6","input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"total_tokens":1500,"events":5,"cost_usd":0.05}]}]}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokiReportResponse.self, from: data)

        #expect(response.ok == true)
        #expect(response.data?.first?.type == "hourly")
    }

    @Test("ReportPeriod query bucket values")
    func reportPeriodBuckets() {
        #expect(ReportPeriod.daily.queryBucket == "1d")
        #expect(ReportPeriod.weekly.queryBucket == "1w")
        #expect(ReportPeriod.monthly.queryBucket == "1M")
    }
}
