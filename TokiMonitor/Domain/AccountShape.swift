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

// The account-type classification that used to live below this line —
// AccountSignal, AccountEvidence, AccountType, AccountAdaptation and
// AccountObservation, about 230 lines with eight tests — has been removed.
//
// It implemented FR-037…FR-041 (adapt the page to subscription / API /
// enterprise) and nothing ever consumed it: the screen read only
// AccountShapeAvailability above, and the classifier was reachable from the
// test suite alone. Wiring it would have meant building seat-based UI for an
// account type this project has never observed and therefore cannot check,
// which is the kind of guessing the constitution's "don't estimate what you
// cannot know" rule exists to stop.
//
// The scope is now the one account type we can actually verify: a confirmed
// subscription. `AccountShapeAvailability` keeps the part that earns its
// place — telling a capability gap apart from a failure — and the raw
// provider fields still arrive on `account_shape`, so reinstating a
// classifier later is a matter of reading them again, not of recovering them.
