import Testing
import Foundation
@testable import TokiMonitor

/// The plan string is the only tier identity that exists. It arrives from the
/// provider as `default_claude_max_5x` and used to reach the screen exactly
/// like that.
///
/// There is deliberately no price anywhere here. Token prices have a public
/// feed the daemon already tracks; subscription tiers have none, so a monthly
/// figure written into this app would be a number nobody updates sitting next
/// to numbers that are current.
@Suite("A plan string a reader can read")
@MainActor
struct PlanTitleTests {

    @Test("the observed Claude tier reads as a tier")
    func observedClaudeTier() {
        #expect(PlanFitFormat.planTitle("default_claude_max_5x") == "Claude Max 5x")
        #expect(PlanFitFormat.planTitle("default_claude_max_20x") == "Claude Max 20x")
        #expect(PlanFitFormat.planTitle("claude_pro") == "Claude Pro")
    }

    @Test("the observed Codex tier reads as a tier")
    func observedCodexTier() {
        #expect(PlanFitFormat.planTitle("prolite") == "Pro Lite")
        #expect(PlanFitFormat.planTitle("free") == "Free")
    }

    /// A tier this build has never seen is still the reader's tier. Passing the
    /// raw name through tells them more than "Unknown" would, and more than
    /// guessing at a shape we have not observed.
    @Test("an unseen tier passes through rather than being guessed at or dropped")
    func unknownTierSurvives() {
        #expect(PlanFitFormat.planTitle("some_future_tier_99x") == "Some Future Tier 99x")
        #expect(PlanFitFormat.planTitle("weird-vendor-string") == "Weird Vendor String")
    }

    @Test("no plan is nil, not an empty label")
    func absentPlan() {
        #expect(PlanFitFormat.planTitle("") == nil)
        #expect(PlanFitFormat.planTitle("   ") == nil)
    }

    /// The multiplier is the part a reader recognises; it must not be
    /// title-cased into "5X" or split off into its own word wrongly.
    @Test("the multiplier keeps its own casing")
    func multiplierCasing() {
        #expect(PlanFitFormat.planTitle("default_claude_max_5x")?.hasSuffix("5x") == true)
        #expect(PlanFitFormat.planTitle("max_100x")?.hasSuffix("100x") == true)
        // Not a multiplier: a trailing word that merely ends in x.
        #expect(PlanFitFormat.planTitle("claude_flux") == "Claude Flux")
    }

    /// The guard against the thing this deliberately does not do.
    @Test("no monetary figure is produced from a plan string")
    func noPriceInvented() {
        for raw in ["default_claude_max_5x", "claude_pro", "prolite", "free"] {
            let title = PlanFitFormat.planTitle(raw) ?? ""
            #expect(!title.contains("$"), "\(raw) must not carry a price")
            #expect(!title.contains("₩"), "\(raw) must not carry a price")
            #expect(!title.contains("/mo"), "\(raw) must not carry a period rate")
        }
    }
}
