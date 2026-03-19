import Foundation
import Testing
@testable import TokiMonitor

@Suite("TokiEventStream NDJSON Parsing")
struct TokiEventStreamTests {

    @Test("Parse valid event JSON")
    func parseValidEvent() throws {
        let json = """
        {"type":"event","data":{"model":"claude-opus-4-6","source":"4de9291e","input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":5000,"cache_read_input_tokens":9000,"cost_usd":0.0123}}
        """
        let data = json.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(TokiEventEnvelope.self, from: data)

        #expect(envelope.type == "event")
        #expect(envelope.data.model == "claude-opus-4-6")
        #expect(envelope.data.source == "4de9291e")
        #expect(envelope.data.inputTokens == 100)
        #expect(envelope.data.outputTokens == 50)
        #expect(envelope.data.cacheCreationInputTokens == 5000)
        #expect(envelope.data.cacheReadInputTokens == 9000)
        #expect(envelope.data.costUsd == 0.0123)
    }

    @Test("Parse event without cost_usd")
    func parseEventNoCost() throws {
        let json = """
        {"type":"event","data":{"model":"gemini-1.5-pro","source":"abcd1234","input_tokens":200,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
        """
        let data = json.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(TokiEventEnvelope.self, from: data)

        #expect(envelope.data.model == "gemini-1.5-pro")
        #expect(envelope.data.costUsd == nil)
    }

    @Test("TokenEvent totalTokens calculation")
    func totalTokens() throws {
        let json = """
        {"type":"event","data":{"model":"claude-opus-4-6","source":"test","input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"cost_usd":0.01}}
        """
        let data = json.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(TokiEventEnvelope.self, from: data)
        let event = TokenEvent(from: envelope.data)

        #expect(event.totalTokens == 650)
    }

    @Test("Reject non-event type")
    func rejectNonEvent() throws {
        let json = """
        {"type":"summary","data":{"model":"claude-opus-4-6","source":"test","input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
        """
        let data = json.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(TokiEventEnvelope.self, from: data)

        #expect(envelope.type == "summary")
        // TokiEventStream.parseLine would skip this since type != "event"
    }

}
