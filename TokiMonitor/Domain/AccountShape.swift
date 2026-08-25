import Foundation

// MARK: - Account type (contract W4, FR-037…FR-041)
//
// The daemon passes the provider's own account vocabulary through
// UNCLASSIFIED — `organization_type: "claude_max"`, `billing_type:
// "stripe_subscription"` — because the provider owns that vocabulary and keeps
// adding to it. The rules that turn those strings into a type live here, in
// one file, so that adding a provider value is a one-line change in a domain
// rule rather than an archaeology expedition through the view layer.
//
// Three properties this file is built to guarantee:
//
// 1. **Positive confirmation only.** Every branch below fires on the PRESENCE
//    of a value. Nothing concludes a type from a field being missing — the
//    absent field is the normal case (the daemon omits rather than defaults),
//    and "no billing_type" is evidence of nothing at all.
// 2. **There is no `.api` case.** An API-key user has no OAuth credentials, so
//    the profile call that produces every field here never happens. API usage
//    is not positively identifiable in principle, and giving it a case would
//    invite exactly the inference FR-040 forbids: "events but zero windows"
//    is equally the shape of a logged-out user, a user with polling switched
//    off, and any daemon older than this feature.
// 3. **`unknown` is a normal outcome, not a failure.** It adapts nothing and
//    the page shows the observed facts instead. There is deliberately no UI
//    anywhere that asks the user their account type and no setting that
//    overrides this classification (FR-041) — if it cannot be determined, the
//    honest screen is the undecorated one.

// MARK: - Why no shape is available

/// Why the page has no `account_shape` to classify.
///
/// Only one of these is a failure. The rest are states a correctly-working
/// system reaches, and rendering them as errors is what contract W4 and
/// FR-054 forbid.
enum AccountShapeAbsence: Equatable, Hashable, Sendable {
    /// The daemon predates the `WINDOWS` command entirely. A capability gap:
    /// the feature is not there yet, nothing is broken.
    case windowsMetricUnsupported
    /// The daemon answered, but its response carried no `account_shape` — a
    /// build before the profile fields, a logged-out account, or a provider
    /// that has no such object (only Claude does). Also a capability gap.
    case accountShapeNotSent
    /// The daemon answered but could not serve window state (tracking off, or
    /// a daemon-side error). Neither a capability gap nor a classification
    /// failure: there is simply nothing to classify yet.
    case windowStateUnavailable
    /// No daemon answered. The one genuine failure in this enum.
    case daemonUnreachable

    /// The feature is absent rather than broken — guidance, never an error
    /// badge (contract W4).
    var isCapabilityGap: Bool {
        self == .windowsMetricUnsupported || self == .accountShapeNotSent
    }

    /// Only a dead daemon is a failure. Everything else here is a normal state.
    var isFailure: Bool { self == .daemonUnreachable }

    var explanation: String {
        switch self {
        case .windowsMetricUnsupported:
            return L.tr(
                "설치된 toki 데몬이 윈도우 지표를 아직 제공하지 않습니다 — 오류가 아니라 기능 부재입니다",
                "The installed toki daemon does not serve the windows metric yet — a missing feature, not an error"
            )
        case .accountShapeNotSent:
            return L.tr(
                "데몬이 계정 정보를 보내지 않았습니다 (로그인 상태나 데몬 버전에 따라 정상입니다)",
                "The daemon sent no account information (normal depending on login state and daemon version)"
            )
        case .windowStateUnavailable:
            return L.tr(
                "데몬이 윈도우 상태를 제공하지 못했습니다 (윈도우 추적이 꺼져 있을 수 있습니다)",
                "The daemon could not serve window state (window tracking may be switched off)"
            )
        case .daemonUnreachable:
            return L.tr("toki 데몬에 연결할 수 없습니다", "Cannot reach the toki daemon")
        }
    }
}

/// Either the daemon reported an account shape, or it did not — and why.
///
/// A plain optional would have collapsed "old daemon" and "daemon is down"
/// into the same `nil`, and those two want opposite screens.
enum AccountShapeAvailability: Equatable, Sendable {
    case reported(AccountShape)
    case absent(AccountShapeAbsence)

    var shape: AccountShape? {
        if case .reported(let shape) = self { return shape }
        return nil
    }

    /// Translate a windows fetch into shape availability (contract W4 / T005).
    ///
    /// `provider` is Claude by default because the account shape is derived
    /// from the Claude profile endpoint; Codex has no equivalent object, and
    /// asking for it must read as "not sent", never as a fault.
    static func from(
        _ result: WindowsFetchResult,
        provider: String = "claude_code"
    ) -> AccountShapeAvailability {
        switch result {
        case .success(let response):
            guard let entry = response.providers?[provider] else {
                return .absent(.accountShapeNotSent)
            }
            // A storage-read failure on the provider entry says nothing about
            // the account object, which is response-only — but it does mean
            // the daemon is in a degraded state, and the page should say so
            // rather than quietly classify.
            if entry.error != nil, entry.accountShape == nil {
                return .absent(.windowStateUnavailable)
            }
            guard let shape = entry.accountShape else { return .absent(.accountShapeNotSent) }
            return .reported(shape)
        case .unsupported:
            return .absent(.windowsMetricUnsupported)
        case .unavailable:
            return .absent(.windowStateUnavailable)
        case .daemonDown:
            return .absent(.daemonUnreachable)
        }
    }
}

// MARK: - Evidence

/// One provider-reported fact that confirmed a type, kept so the page can show
/// what it concluded from — the same rule the verdict layer follows: no claim
/// without its basis.
enum AccountSignal: Equatable, Hashable, Sendable {
    case billingType(String)
    case organizationType(String)
    case hasClaudeMax
    case hasClaudePro
    case seatTier(String)
    case memberDashboardAvailable

    /// Provider vocabulary is quoted verbatim, not translated: it is an
    /// observed value (Provenance `.observed`), and paraphrasing it would make
    /// a provider string look like our judgement.
    var description: String {
        switch self {
        case .billingType(let value):
            return L.tr("결제 유형 \(value)", "billing type \(value)")
        case .organizationType(let value):
            return L.tr("조직 유형 \(value)", "organization type \(value)")
        case .hasClaudeMax:
            return L.tr("Claude Max 보유", "has Claude Max")
        case .hasClaudePro:
            return L.tr("Claude Pro 보유", "has Claude Pro")
        case .seatTier(let value):
            return L.tr("좌석 등급 \(value)", "seat tier \(value)")
        case .memberDashboardAvailable:
            return L.tr("구성원 대시보드 사용 가능", "member dashboard available")
        }
    }
}

/// What confirmed the type, and the subscription status that came with it.
struct AccountEvidence: Equatable, Hashable, Sendable {
    /// Never empty on a confirmed type — a type without a signal cannot be
    /// constructed through `AccountType.classify`.
    let signals: [AccountSignal]
    /// `subscription_status` verbatim ("active", …). Carried as context, and
    /// deliberately NOT used to confirm a type on its own: FR-038 names
    /// `billing_type`, `organization_type` and `has_claude_*` as the
    /// confirming fields, and a lapsed subscription is still a subscription
    /// account rather than a different kind of account.
    let subscriptionStatus: String?

    var summary: String { signals.map(\.description).joined(separator: ", ") }
}

// MARK: - The type

/// What kind of account this is, when that can be established at all.
enum AccountType: Equatable, Hashable, Sendable {
    /// An individual subscription, positively confirmed. "Individual" is the
    /// residual of FR-039: a subscription with no seat signal is one person's.
    case subscription(AccountEvidence)
    /// A seat-based organization (team / enterprise), positively confirmed.
    case seatBased(AccountEvidence)
    /// Not determinable. **A normal state**, and the one an API-key account
    /// necessarily lands in.
    case unknown

    var evidence: AccountEvidence? {
        switch self {
        case .subscription(let e), .seatBased(let e): return e
        case .unknown: return nil
        }
    }

    /// Values that name a subscription in the provider's `billing_type`.
    /// Matched as a substring so a new payment processor ("paddle_subscription")
    /// still reads as one; a value that does not say so is left unclassified
    /// rather than guessed at.
    private static let subscriptionBillingMarker = "subscription"
    /// Consumer product tokens inside `organization_type` ("claude_max").
    private static let individualProductTokens: Set<String> = ["max", "pro"]
    /// Seat-based organisation tokens inside `organization_type`.
    private static let seatOrganizationTokens: Set<String> = ["team", "enterprise"]

    /// Provider values are compound and lowercase-ish ("claude_max"), so
    /// matching splits them into parts instead of comparing whole strings — an
    /// exhaustive list of every value the provider might ever mint is the
    /// hardcoding constitution principle II rules out.
    private static func tokens(_ value: String?) -> Set<String> {
        guard let value else { return [] }
        let parts = value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return Set(parts.map(String.init))
    }

    /// Classify one observation.
    ///
    /// Reads the `account_shape` and nothing else. The window and event counts
    /// on the observation are there because the page displays them, and they
    /// are pointedly not consulted here — "events but zero windows" is the
    /// exact inference FR-040 rules out, and `AccountShapeTests` locks that in.
    static func classify(_ observation: AccountObservation) -> AccountType {
        guard let shape = observation.availability.shape else { return .unknown }

        let organizationTokens = tokens(shape.organizationType)

        // Seat-based first: a team subscription carries both kinds of signal,
        // and the seat facts are the more specific answer. FR-039 names seat
        // tier, member-dashboard availability and organisation type.
        var seatSignals: [AccountSignal] = []
        if let tier = shape.seatTier, !tier.isEmpty {
            seatSignals.append(.seatTier(tier))
        }
        if shape.memberDashboardAvailable == true {
            seatSignals.append(.memberDashboardAvailable)
        }
        if let type = shape.organizationType, !organizationTokens.isDisjoint(with: seatOrganizationTokens) {
            seatSignals.append(.organizationType(type))
        }
        if !seatSignals.isEmpty {
            return .seatBased(AccountEvidence(
                signals: seatSignals, subscriptionStatus: shape.subscriptionStatus
            ))
        }

        // FR-038: confirmed from what is present. There is no `else` branch
        // reading a missing field as evidence of anything.
        var subscriptionSignals: [AccountSignal] = []
        if let billing = shape.billingType,
           billing.lowercased().contains(subscriptionBillingMarker) {
            subscriptionSignals.append(.billingType(billing))
        }
        if let type = shape.organizationType, !organizationTokens.isDisjoint(with: individualProductTokens) {
            subscriptionSignals.append(.organizationType(type))
        }
        if shape.hasClaudeMax == true { subscriptionSignals.append(.hasClaudeMax) }
        if shape.hasClaudePro == true { subscriptionSignals.append(.hasClaudePro) }
        if !subscriptionSignals.isEmpty {
            return .subscription(AccountEvidence(
                signals: subscriptionSignals, subscriptionStatus: shape.subscriptionStatus
            ))
        }

        // A shape arrived, but nothing in it confirms a type. Unknown, and the
        // page carries on with the facts it does have.
        return .unknown
    }

    var label: String {
        switch self {
        case .subscription: return L.tr("구독 계정", "Subscription account")
        case .seatBased: return L.tr("좌석 기반 조직 계정", "Seat-based organization account")
        case .unknown: return L.tr("계정 유형 미확인", "Account type not determined")
        }
    }

    /// Shown wherever `unknown` appears, so the state reads as a deliberate
    /// outcome rather than a blank the page failed to fill.
    static var unknownExplanation: String {
        L.tr(
            "공급자가 계정 유형을 확인해 주는 정보를 보내지 않았습니다. 유형에 따른 화면 조정 없이 관측된 사실만 표시합니다.",
            "The provider sent nothing that confirms an account type. The page adapts nothing and shows the observed facts."
        )
    }
}

// MARK: - Adaptation

/// What a confirmed type is allowed to change about the page.
///
/// Every flag defaults to off, and `unknown` maps to `.none`: adaptation is
/// something a type has to earn, not something switched off by an exception.
struct AccountAdaptation: Equatable, Hashable, Sendable {
    /// Seat/organisation framing may be shown (per-seat context, org limits).
    let showsSeatContext: Bool
    /// Spend may be framed as a fixed subscription — which is also what makes
    /// it a SECONDARY metric on this page (FR-046).
    let showsSubscriptionFraming: Bool

    /// Nothing about the page changes.
    static let none = AccountAdaptation(showsSeatContext: false, showsSubscriptionFraming: false)

    var adaptsAnything: Bool { showsSeatContext || showsSubscriptionFraming }
}

extension AccountType {
    /// FR-037 / FR-040: only a confirmed type changes the page, and `unknown`
    /// changes nothing.
    var adaptation: AccountAdaptation {
        switch self {
        case .subscription:
            return AccountAdaptation(showsSeatContext: false, showsSubscriptionFraming: true)
        case .seatBased:
            return AccountAdaptation(showsSeatContext: true, showsSubscriptionFraming: true)
        case .unknown:
            return .none
        }
    }

    var adaptsPresentation: Bool { adaptation.adaptsAnything }
}

// MARK: - Observation

/// Everything the page has observed about the account.
///
/// The counts live beside the shape because the page shows them — "3 windows,
/// events present" is the honest content of the unknown state. They are inputs
/// to the DISPLAY, never to `AccountType.classify`.
struct AccountObservation: Equatable, Sendable {
    let availability: AccountShapeAvailability
    /// Windows recorded for this account in the lookback.
    let windowCount: Int
    /// Token events exist for this account.
    let hasTokenEvents: Bool

    init(availability: AccountShapeAvailability, windowCount: Int = 0, hasTokenEvents: Bool = false) {
        self.availability = availability
        self.windowCount = windowCount
        self.hasTokenEvents = hasTokenEvents
    }

    var accountType: AccountType { AccountType.classify(self) }

    /// The state FR-040 calls out by name: usage is being recorded, but no
    /// window ever was. It is worth SHOWING — it usually means polling is off
    /// or the login expired — and it is worth naming so nobody is tempted to
    /// read it as an account type.
    var hasEventsWithoutWindows: Bool { hasTokenEvents && windowCount == 0 }

    /// Why that state is not a conclusion about the account.
    static var eventsWithoutWindowsExplanation: String {
        L.tr(
            "사용 기록은 있으나 윈도우가 없습니다. 로그아웃, 윈도우 폴링 비활성, 구버전 데몬에서도 같은 상태가 나타나므로 계정 유형을 단정하지 않습니다.",
            "Usage is recorded but no window is. The same state occurs when logged out, when window polling is off, and on any older daemon — so no account type is concluded from it."
        )
    }
}
