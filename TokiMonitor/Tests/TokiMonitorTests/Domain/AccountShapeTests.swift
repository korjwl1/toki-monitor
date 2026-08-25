import Testing
import Foundation
@testable import TokiMonitor

/// The classification rules are worth testing mostly for what they REFUSE to
/// conclude. Every field here can be absent, and the daemon omits rather than
/// defaults precisely so that absence stays distinguishable from `false` — so
/// the tests that matter are the ones proving nothing is inferred from a
/// missing field, and that "events but no windows" never becomes a type.
///
/// `@MainActor` because the labels reach `L.tr`.
@Suite("Account shape")
@MainActor
struct AccountShapeTests {

    /// Everything defaults to absent, matching the wire: a caller names only
    /// the fields the daemon actually sent.
    private func shape(
        organizationType: String? = nil,
        billingType: String? = nil,
        seatTier: String? = nil,
        subscriptionStatus: String? = nil,
        hasClaudeMax: Bool? = nil,
        hasClaudePro: Bool? = nil,
        memberDashboardAvailable: Bool? = nil
    ) -> AccountShape {
        AccountShape(
            organizationType: organizationType,
            billingType: billingType,
            seatTier: seatTier,
            subscriptionStatus: subscriptionStatus,
            hasClaudeMax: hasClaudeMax,
            hasClaudePro: hasClaudePro,
            memberDashboardAvailable: memberDashboardAvailable
        )
    }

    private func observation(
        _ shape: AccountShape?,
        windowCount: Int = 12,
        hasTokenEvents: Bool = true
    ) -> AccountObservation {
        AccountObservation(
            availability: shape.map { .reported($0) } ?? .absent(.accountShapeNotSent),
            windowCount: windowCount,
            hasTokenEvents: hasTokenEvents
        )
    }

    // MARK: - T004: absent is not false

    @Test("an omitted field decodes as absent, not as false")
    func absentFieldStaysAbsent() throws {
        // The live payload, minus the booleans: the daemon omits what the
        // provider did not send.
        let json = """
        {"organization_type": "claude_max", "billing_type": "stripe_subscription"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AccountShape.self, from: json)

        #expect(decoded.organizationType == "claude_max")
        #expect(decoded.hasClaudeMax == nil)
        #expect(decoded.hasClaudePro == nil)
        #expect(decoded.memberDashboardAvailable == nil)
        #expect(decoded.seatTier == nil)
        // The distinction the whole model rests on.
        #expect(decoded.hasClaudeMax != false)
    }

    @Test("a field sent as false decodes as false, and is not the same as absent")
    func falseIsNotAbsent() throws {
        let json = """
        {"has_claude_pro": false, "member_dashboard_available": false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AccountShape.self, from: json)

        #expect(decoded.hasClaudePro == false)
        #expect(decoded.hasClaudePro != nil)
        #expect(decoded.memberDashboardAvailable == false)
        #expect(decoded.hasClaudeMax == nil)
    }

    @Test("the live payload decodes whole, inside its provider entry")
    func livePayloadDecodes() throws {
        // Observed 2026-08-26 from the daemon (toki 699c388).
        let json = """
        {"ok": true, "schema": 1, "now_ms": 1786000000000, "providers": {
          "claude_code": {
            "windows": [], "auth_status": "ok",
            "account_shape": {
              "organization_type": "claude_max",
              "billing_type": "stripe_subscription",
              "subscription_status": "active",
              "has_claude_max": true,
              "has_claude_pro": false,
              "member_dashboard_available": false
            }
          },
          "codex": {"windows": [], "auth_status": "ok"}
        }}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(WindowsResponse.self, from: json)

        let claude = try #require(response.providers?["claude_code"]?.accountShape)
        #expect(claude.organizationType == "claude_max")
        #expect(claude.billingType == "stripe_subscription")
        #expect(claude.subscriptionStatus == "active")
        #expect(claude.hasClaudeMax == true)
        #expect(claude.hasClaudePro == false)
        #expect(claude.memberDashboardAvailable == false)
        // `seat_tier: null` on the provider means the daemon omits it, and an
        // individual account therefore has no seat tier to read.
        #expect(claude.seatTier == nil)

        // Codex carries no account object at all, and that is not a fault.
        #expect(response.providers?["codex"]?.accountShape == nil)
        #expect(AccountShapeAvailability.from(.success(response), provider: "codex")
            == .absent(.accountShapeNotSent))
    }

    // MARK: - T005: a capability gap is not an error

    @Test("an old daemon is a capability gap, distinguishable from a dead one")
    func capabilityGapIsNotAFailure() {
        let old = AccountShapeAvailability.from(.unsupported)
        #expect(old == .absent(.windowsMetricUnsupported))

        let dead = AccountShapeAvailability.from(.daemonDown)
        #expect(dead == .absent(.daemonUnreachable))

        // The two land in different buckets, which is the entire point.
        #expect(AccountShapeAbsence.windowsMetricUnsupported.isCapabilityGap)
        #expect(!AccountShapeAbsence.windowsMetricUnsupported.isFailure)
        #expect(AccountShapeAbsence.daemonUnreachable.isFailure)
        #expect(!AccountShapeAbsence.daemonUnreachable.isCapabilityGap)
        #expect(AccountShapeAbsence.accountShapeNotSent.isCapabilityGap)

        // And every one of them can say why, so nothing renders as a blank.
        for absence in [AccountShapeAbsence.windowsMetricUnsupported, .accountShapeNotSent,
                        .windowStateUnavailable, .daemonUnreachable] {
            #expect(!absence.explanation.isEmpty)
        }
    }

    @Test("a current daemon that sent no account object is a gap, not a failure")
    func missingShapeOnACurrentDaemon() throws {
        let json = """
        {"ok": true, "schema": 1, "providers": {"claude_code": {"windows": [], "auth_status": "ok"}}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(WindowsResponse.self, from: json)
        let availability = AccountShapeAvailability.from(.success(response))
        #expect(availability == .absent(.accountShapeNotSent))
        if case .absent(let reason) = availability {
            #expect(reason.isCapabilityGap)
            #expect(!reason.isFailure)
        }
    }

    @Test("a broken window store is neither a gap nor a classification")
    func storageErrorIsItsOwnState() throws {
        let json = """
        {"ok": true, "schema": 1, "providers":
          {"claude_code": {"windows": [], "auth_status": "ok", "error": "fjall read failed"}}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(WindowsResponse.self, from: json)
        #expect(AccountShapeAvailability.from(.success(response)) == .absent(.windowStateUnavailable))
        #expect(AccountShapeAvailability.from(.unavailable) == .absent(.windowStateUnavailable))
    }

    // MARK: - T038: subscription is positively confirmed

    @Test("the observed live account confirms a subscription")
    func liveAccountIsASubscription() {
        let type = AccountType.classify(observation(shape(
            organizationType: "claude_max",
            billingType: "stripe_subscription",
            subscriptionStatus: "active",
            hasClaudeMax: true,
            hasClaudePro: false,
            memberDashboardAvailable: false
        )))

        guard case .subscription(let evidence) = type else {
            Issue.record("expected a subscription, got \(type)")
            return
        }
        #expect(evidence.signals.contains(.billingType("stripe_subscription")))
        #expect(evidence.signals.contains(.organizationType("claude_max")))
        #expect(evidence.signals.contains(.hasClaudeMax))
        // `has_claude_pro: false` is a negative fact and never a signal.
        #expect(!evidence.signals.contains(.hasClaudePro))
        #expect(evidence.subscriptionStatus == "active")
        #expect(type.adaptation.showsSubscriptionFraming)
        #expect(!type.adaptation.showsSeatContext)
    }

    @Test("each confirming field stands on its own")
    func eachSignalConfirms() {
        #expect(AccountType.classify(observation(shape(billingType: "stripe_subscription")))
            != AccountType.unknown)
        #expect(AccountType.classify(observation(shape(organizationType: "claude_pro")))
            != AccountType.unknown)
        #expect(AccountType.classify(observation(shape(hasClaudeMax: true))) != AccountType.unknown)
        #expect(AccountType.classify(observation(shape(hasClaudePro: true))) != AccountType.unknown)

        // A new payment processor still reads as a subscription: the match is
        // on the provider's word, not on an allowlist of whole values.
        #expect(AccountType.classify(observation(shape(billingType: "paddle_subscription")))
            != AccountType.unknown)
    }

    @Test("a false boolean confirms nothing")
    func falseConfirmsNothing() {
        let type = AccountType.classify(observation(shape(
            hasClaudeMax: false, hasClaudePro: false, memberDashboardAvailable: false
        )))
        #expect(type == .unknown)
        #expect(!type.adaptsPresentation)
    }

    @Test("an unfamiliar billing vocabulary is left unclassified, never called API")
    func unfamiliarVocabularyIsUnknown() {
        let type = AccountType.classify(observation(shape(billingType: "invoice_net30")))
        #expect(type == .unknown)
    }

    // MARK: - T039: seat-based is confirmed, and its absence means individual

    @Test("a seat tier confirms a seat-based organization")
    func seatTierConfirmsSeatBased() {
        let type = AccountType.classify(observation(shape(
            organizationType: "claude_enterprise",
            billingType: "stripe_subscription",
            seatTier: "enterprise",
            memberDashboardAvailable: true
        )))
        guard case .seatBased(let evidence) = type else {
            Issue.record("expected seat-based, got \(type)")
            return
        }
        #expect(evidence.signals.contains(.seatTier("enterprise")))
        #expect(evidence.signals.contains(.memberDashboardAvailable))
        #expect(type.adaptation.showsSeatContext)
    }

    @Test("the member dashboard alone confirms a seat-based organization")
    func memberDashboardConfirmsSeatBased() {
        let type = AccountType.classify(observation(shape(memberDashboardAvailable: true)))
        if case .seatBased = type {} else {
            Issue.record("expected seat-based, got \(type)")
        }
    }

    @Test("a subscription with no seat signal is an individual account")
    func noSeatSignalMeansIndividual() {
        let type = AccountType.classify(observation(shape(
            organizationType: "claude_max",
            billingType: "stripe_subscription",
            seatTier: nil,
            memberDashboardAvailable: false
        )))
        if case .subscription = type {} else {
            Issue.record("expected an individual subscription, got \(type)")
        }
        #expect(!type.adaptation.showsSeatContext)
    }

    // MARK: - T040 / T042: unknown is normal and adapts nothing

    @Test("with no account_shape at all, nothing is adapted")
    func noShapeMeansNoAdaptation() {
        let type = AccountType.classify(observation(nil))
        #expect(type == .unknown)
        #expect(type.adaptation == .none)
        #expect(!type.adaptsPresentation)
        #expect(!type.adaptation.showsSeatContext)
        #expect(!type.adaptation.showsSubscriptionFraming)
        #expect(type.evidence == nil)
        // The state explains itself rather than rendering as an empty slot.
        #expect(!AccountType.unknownExplanation.isEmpty)
        #expect(!type.label.isEmpty)
    }

    @Test("no absence reason produces an adapted page")
    func noAbsenceReasonAdapts() {
        for absence in [AccountShapeAbsence.windowsMetricUnsupported, .accountShapeNotSent,
                        .windowStateUnavailable, .daemonUnreachable] {
            let type = AccountObservation(availability: .absent(absence)).accountType
            #expect(type == .unknown)
            #expect(!type.adaptsPresentation)
        }
    }

    @Test("an account object that confirms nothing is unknown, not a failure")
    func emptyShapeIsUnknown() {
        let type = AccountType.classify(observation(shape(subscriptionStatus: "active")))
        // `subscription_status` is context, not one of the confirming fields.
        #expect(type == .unknown)
    }

    // MARK: - T041: "events but zero windows" is not an account type

    @Test("events with zero windows is never concluded to be an API account")
    func eventsWithoutWindowsIsNotAType() {
        // The exact state FR-040 names: usage is recorded, no window ever was.
        let seen = AccountObservation(
            availability: .absent(.accountShapeNotSent),
            windowCount: 0,
            hasTokenEvents: true
        )
        #expect(seen.hasEventsWithoutWindows)
        #expect(seen.accountType == .unknown)
        #expect(!seen.accountType.adaptsPresentation)
        // It is worth SHOWING, with the reasons it is not a conclusion.
        #expect(!AccountObservation.eventsWithoutWindowsExplanation.isEmpty)

        // The same state occurs on an old daemon and on a dead one, and none
        // of them classify differently — which is why it cannot be a type.
        for absence in [AccountShapeAbsence.windowsMetricUnsupported, .windowStateUnavailable,
                        .daemonUnreachable] {
            let other = AccountObservation(
                availability: .absent(absence), windowCount: 0, hasTokenEvents: true
            )
            #expect(other.accountType == seen.accountType)
        }
    }

    @Test("window and event counts do not move the classification either way")
    func countsNeverInfluenceTheType() {
        let confirming = shape(billingType: "stripe_subscription", hasClaudeMax: true)

        // Zero windows does not downgrade a confirmed subscription…
        let starved = AccountObservation(
            availability: .reported(confirming), windowCount: 0, hasTokenEvents: true
        )
        if case .subscription = starved.accountType {} else {
            Issue.record("zero windows changed a confirmed type: \(starved.accountType)")
        }

        // …and a pile of windows does not confirm one that was never sent.
        let busy = AccountObservation(
            availability: .absent(.accountShapeNotSent), windowCount: 500, hasTokenEvents: true
        )
        #expect(busy.accountType == .unknown)

        // Same shape, every count combination, one answer.
        let types = [(0, false), (0, true), (99, false), (99, true)].map { count, events in
            AccountObservation(
                availability: .reported(confirming), windowCount: count, hasTokenEvents: events
            ).accountType
        }
        #expect(Set(types).count == 1)
    }
}
