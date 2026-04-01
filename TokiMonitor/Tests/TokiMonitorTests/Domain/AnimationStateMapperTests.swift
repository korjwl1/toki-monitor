import Testing
@testable import TokiMonitor

@Suite("AnimationStateMapper")
struct AnimationStateMapperTests {
    let mapper = AnimationStateMapper()

    @Test("Zero rate is idle")
    func zeroRate() {
        #expect(mapper.isIdle(tokensPerMinute: 0))
    }

    @Test("Sub-threshold rate is idle")
    func subThreshold() {
        #expect(mapper.isIdle(tokensPerMinute: 0.5))
    }

    @Test("Above threshold is not idle")
    func aboveThreshold() {
        #expect(!mapper.isIdle(tokensPerMinute: 100000))
        #expect(!mapper.isIdle(tokensPerMinute: 5000000))
    }

    @Test("Idle rate returns zero interval")
    func idleInterval() {
        #expect(mapper.interval(for: 0) == 0)
        #expect(mapper.interval(for: 50000) == 0)
    }

    @Test("Higher rate produces shorter interval (faster animation)")
    func intervalDecreasesWithRate() {
        let slow = mapper.interval(for: 200000)
        let fast = mapper.interval(for: 5000000)
        let sprint = mapper.interval(for: 40000000)
        #expect(slow > fast)
        #expect(fast > sprint)
    }

    @Test("Interval is clamped at max rate")
    func intervalClamped() {
        let atMax = mapper.interval(for: 50000000)
        let beyondMax = mapper.interval(for: 500000000)
        #expect(atMax == beyondMax)
    }

    @Test("Interval is positive for non-idle rates")
    func intervalPositive() {
        #expect(mapper.interval(for: 100000) > 0)
        #expect(mapper.interval(for: 5000000) > 0)
        #expect(mapper.interval(for: 40000000) > 0)
    }
}

@Suite("TokenFormatter.formatRate")
struct TokenAggregatorFormatTests {
    @Test("Zero formats as 0/m")
    func zero() {
        #expect(TokenFormatter.formatRate(0) == "0/m")
    }

    @Test("Small number formats without K")
    func small() {
        #expect(TokenFormatter.formatRate(42) == "42/m")
        #expect(TokenFormatter.formatRate(999) == "999/m")
    }

    @Test("Thousands format with K")
    func thousands() {
        #expect(TokenFormatter.formatRate(1200) == "1.2K/m")
        #expect(TokenFormatter.formatRate(15000) == "15.0K/m")
    }

    @Test("Millions format with M")
    func millions() {
        #expect(TokenFormatter.formatRate(1_500_000) == "1.5M/m")
    }
}
