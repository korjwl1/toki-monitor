import Testing
@testable import TokiMonitor

@Suite("AnimationStateMapper")
struct AnimationStateMapperTests {
    let mapper = AnimationStateMapper()

    @Test("Zero rate maps to idle")
    func zeroRate() {
        #expect(mapper.map(tokensPerMinute: 0) == .idle)
    }

    @Test("Sub-threshold rate maps to idle")
    func subThreshold() {
        #expect(mapper.map(tokensPerMinute: 0.5) == .idle)
    }

    @Test("Low range maps to low")
    func lowRange() {
        #expect(mapper.map(tokensPerMinute: 1) == .low)
        #expect(mapper.map(tokensPerMinute: 50) == .low)
        #expect(mapper.map(tokensPerMinute: 99) == .low)
    }

    @Test("Medium range maps to medium")
    func mediumRange() {
        #expect(mapper.map(tokensPerMinute: 100) == .medium)
        #expect(mapper.map(tokensPerMinute: 500) == .medium)
        #expect(mapper.map(tokensPerMinute: 999) == .medium)
    }

    @Test("High range maps to high")
    func highRange() {
        #expect(mapper.map(tokensPerMinute: 1000) == .high)
        #expect(mapper.map(tokensPerMinute: 50000) == .high)
    }

    @Test("AnimationState is comparable")
    func comparable() {
        #expect(AnimationState.idle < AnimationState.low)
        #expect(AnimationState.low < AnimationState.medium)
        #expect(AnimationState.medium < AnimationState.high)
    }

    @Test("Character FPS increases with state")
    func characterFPS() {
        #expect(AnimationState.idle.characterFPS == 0)
        #expect(AnimationState.low.characterFPS == 2)
        #expect(AnimationState.medium.characterFPS == 6)
        #expect(AnimationState.high.characterFPS == 12)
    }
}

@Suite("TokenAggregator.formatRate")
struct TokenAggregatorFormatTests {
    @Test("Zero formats as 0/m")
    func zero() {
        #expect(TokenAggregator.formatRate(0) == "0/m")
    }

    @Test("Small number formats without K")
    func small() {
        #expect(TokenAggregator.formatRate(42) == "42/m")
        #expect(TokenAggregator.formatRate(999) == "999/m")
    }

    @Test("Thousands format with K")
    func thousands() {
        #expect(TokenAggregator.formatRate(1200) == "1.2K/m")
        #expect(TokenAggregator.formatRate(15000) == "15.0K/m")
    }

    @Test("Millions format with M")
    func millions() {
        #expect(TokenAggregator.formatRate(1_500_000) == "1.5M/m")
    }
}
