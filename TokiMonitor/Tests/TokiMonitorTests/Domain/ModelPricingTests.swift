import Testing
import Foundation
@testable import TokiMonitor

/// The fallback table exists for one window: a model so new that the daemon's
/// LiteLLM snapshot has no price for it, so the daemon omits `cost_usd`
/// entirely. Everything here is about being right — or silent — in exactly
/// that window.
@Suite("ModelPricing")
struct ModelPricingTests {

    private func perMillionInput(_ model: String) -> Double? {
        ModelPricing.estimateCost(model: model, inputTokens: 1_000_000, outputTokens: 0)
    }

    private func perMillionOutput(_ model: String) -> Double? {
        ModelPricing.estimateCost(model: model, inputTokens: 0, outputTokens: 1_000_000)
    }

    // MARK: - Current prices

    /// `claude-opus-4` is a live prefix for the retired model, and it used to
    /// swallow every 4.x — pricing Opus 4.5 through 4.8 at the retired 4.1
    /// rate, three times over.
    @Test("a current Opus is not priced at the retired Opus rate")
    func longestPrefixWins() throws {
        for model in ["claude-opus-5", "claude-opus-4-8", "claude-opus-4-7",
                      "claude-opus-4-6", "claude-opus-4-5"] {
            #expect(abs(try #require(perMillionInput(model)) - 5.0) < 1e-9, "\(model) input")
            #expect(abs(try #require(perMillionOutput(model)) - 25.0) < 1e-9, "\(model) output")
        }
        // The retired ones really were $15/$75, and old events carry the name.
        #expect(abs(try #require(perMillionInput("claude-opus-4-1")) - 15.0) < 1e-9)
        #expect(abs(try #require(perMillionInput("claude-opus-4")) - 15.0) < 1e-9)
    }

    @Test("the rest of the published table")
    func publishedPrices() throws {
        #expect(abs(try #require(perMillionInput("claude-fable-5")) - 10.0) < 1e-9)
        #expect(abs(try #require(perMillionOutput("claude-fable-5")) - 50.0) < 1e-9)
        #expect(abs(try #require(perMillionInput("claude-sonnet-4-6")) - 3.0) < 1e-9)
        #expect(abs(try #require(perMillionInput("claude-haiku-4-5")) - 1.0) < 1e-9)
        #expect(abs(try #require(perMillionOutput("claude-haiku-4-5")) - 5.0) < 1e-9)
    }

    /// Cache tiers are fixed multiples of base input: a 5-minute write is
    /// 1.25x and a cache hit is 0.1x. Getting these wrong matters more than
    /// the base rate — a Claude Code session is mostly cache reads.
    @Test("cache tiers follow the published multipliers")
    func cacheTiers() throws {
        let readOnly = try #require(ModelPricing.estimateCost(
            model: "claude-opus-5", inputTokens: 0, outputTokens: 0,
            cacheReadInputTokens: 1_000_000))
        #expect(abs(readOnly - 0.50) < 1e-9, "10% of $5")

        let writeOnly = try #require(ModelPricing.estimateCost(
            model: "claude-opus-5", inputTokens: 0, outputTokens: 0,
            cacheCreationInputTokens: 1_000_000))
        #expect(abs(writeOnly - 6.25) < 1e-9, "125% of $5")
    }

    // MARK: - Silence beats a guess

    /// The table used to end in a `claude-` entry that caught everything else
    /// at Sonnet prices. That made the fallback confidently wrong in exactly
    /// the window it exists for — a model too new to be priced anywhere.
    @Test("an unrecognised Claude model has no price rather than a guessed one")
    func noFamilyCatchAll() {
        #expect(ModelPricing.estimateCost(model: "claude-something-7",
                                          inputTokens: 1_000_000, outputTokens: 0) == nil)
        #expect(ModelPricing.estimateCost(model: "claude-",
                                          inputTokens: 1_000_000, outputTokens: 0) == nil)
    }

    @Test("an unknown vendor's model has no price either")
    func unknownModelIsNil() {
        #expect(ModelPricing.estimateCost(model: "totally-unknown-model",
                                          inputTokens: 1_000, outputTokens: 1_000) == nil)
        #expect(ModelPricing.estimateCost(model: "gpt-5.6-sol",
                                          inputTokens: 1_000, outputTokens: 1_000) == nil,
                "not published in this table; absent is honest")
    }

    // MARK: - Fast mode

    /// Fast mode is $10/$50 against a $5/$25 base — a flat 2x, which the
    /// cache tiers inherit because they are multiples of base input.
    @Test("fast mode doubles the whole bill on the models that offer it")
    func fastMode() throws {
        for model in ["claude-opus-5", "claude-opus-4-8"] {
            let base = try #require(ModelPricing.estimateCost(
                model: model, inputTokens: 100, outputTokens: 200,
                cacheCreationInputTokens: 1_000, cacheReadInputTokens: 10_000))
            let fast = try #require(ModelPricing.estimateCost(
                model: "\(model)-fast", inputTokens: 100, outputTokens: 200,
                cacheCreationInputTokens: 1_000, cacheReadInputTokens: 10_000))
            #expect(abs(fast - base * 2.0) < 1e-9, "\(model) fast")
        }
        #expect(abs(try #require(perMillionInput("claude-opus-5-fast")) - 10.0) < 1e-9)
    }

    /// 4.7 rejects a fast request and 4.6 runs at standard speed and standard
    /// rates, so neither takes a multiplier.
    @Test("models that do not offer fast mode are not marked up")
    func noFastMarkupWhereUnsupported() throws {
        for model in ["claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4"] {
            let base = try #require(perMillionInput(model))
            let fast = try #require(perMillionInput("\(model)-fast"))
            #expect(abs(fast - base) < 1e-9, "\(model) must not be marked up")
        }
    }

    // MARK: - Staleness

    /// A hand-maintained price table with no expiry is one nobody can tell is
    /// stale. Sonnet 5's introductory pricing ends on a known date, so this
    /// fails from that date with instructions rather than quietly overcharging.
    @Test("Sonnet 5's scheduled price change has not silently passed")
    func sonnetFiveIntroductoryPricing() throws {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let ends = try #require(fmt.date(from: ModelPricing.sonnetFiveIntroductoryPricingEnds))

        if Date() < ends {
            #expect(abs(try #require(perMillionInput("claude-sonnet-5")) - 2.0) < 1e-9,
                    "introductory $2/$10 is still in effect")
        } else {
            #expect(abs(try #require(perMillionInput("claude-sonnet-5")) - 3.0) < 1e-9,
                    """
                    Sonnet 5 introductory pricing ended on \
                    \(ModelPricing.sonnetFiveIntroductoryPricingEnds). Set the table entry to \
                    $3/$15 and move `sonnetFiveIntroductoryPricingEnds` to the next known \
                    scheduled change (or remove it if there is none).
                    """)
        }
    }

    @Test("the table records when it was last checked")
    func reviewedOnIsADate() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        #expect(fmt.date(from: ModelPricing.reviewedOn) != nil)
    }
}
