import SwiftUI

// MARK: - The verdict (T053 / contract V1, V3, V7, V8)
//
// The page reaches at most one conclusion per limit and it has up to eight
// limits, so this section has two jobs that pull in opposite directions: lead
// with ONE sentence at 24pt, and still let the reader see that limit five says
// something different from limit one.
//
// It resolves that by rank rather than by repetition. The elected verdict is
// the lede — the only thing on the page drawn at `PlanFitType.lede` — and the
// rest are compact rows underneath, each carrying its own scope, its own
// sentence and its own basis. Nothing is summarised away: a withheld verdict
// beside a `considerUpgrade` verdict is a real difference between two limits,
// and collapsing them into "mixed" would hide the one the reader came for.
//
// Three contract rules are visible in what this file does NOT do:
//
// - **No tier names, no prices (V7).** Every string here comes from
//   `PlanFitVerdict.statement()`, which speaks only about "the current plan".
//   There is no catalogue of tiers and no price feed for subscriptions, so a
//   sentence like "move to 20x for $200/mo" could only ever be invented.
// - **No "you're safe" (V8).** Slack arrives as `HeadroomNote`, which cannot be
//   constructed without the sentence saying it is not a guarantee against
//   being cut off, and the two are rendered by the same branch.
// - **Withholding is not styled as an error.** It gets the same card, the same
//   size and the same weight as a verdict; the difference is the badge word
//   and the extra line saying when a verdict becomes possible. With 21 window
//   rows in the real database this is the state nearly every reader meets, and
//   a screen that greys itself out reads as a broken feature.

struct VerdictSection: View {
    let lede: PlanFitLede
    /// Every other limit's verdict. Empty on a one-limit account.
    let others: [SegmentVerdictModel]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            ledeCard
            if !others.isEmpty { otherVerdicts }
        }
    }

    // MARK: The conclusion

    /// The one sentence the page exists to produce, at 24pt. Everything below
    /// it on the page is the evidence for it.
    private var ledeCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                Image(systemName: lede.kind.symbolName)
                    .font(.system(size: PlanFitType.caption, weight: .semibold))
                Text(lede.kind.badge)
                    .font(.system(size: PlanFitType.caption, weight: .semibold))
                if let scope = lede.scope {
                    Text("· \(scope)")
                        .font(.system(size: PlanFitType.caption))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(PlanFitInk.support)

            Text(lede.headline)
                .font(.system(size: PlanFitType.lede, weight: .semibold))
                .foregroundStyle(PlanFitInk.strong)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let availability = lede.availability {
                Text(availability)
                    .font(.system(size: PlanFitType.body, weight: .medium))
                    .foregroundStyle(PlanFitInk.support)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let headroom = lede.headroom {
                Text(headroom.sensitivity)
                    .font(.system(size: PlanFitType.body))
                    .foregroundStyle(PlanFitInk.support)
                    .fixedSize(horizontal: false, vertical: true)
                // Contract V8. Bound to the sentence above by the type that
                // carries them both — there is no render path with one and not
                // the other.
                Text(headroom.caveat)
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.support)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = lede.detail {
                Text(detail)
                    .font(.system(size: PlanFitType.body))
                    .foregroundStyle(PlanFitInk.support)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let basis = lede.basis {
                HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                    Text(basis)
                        .font(.system(size: PlanFitType.caption))
                        .foregroundStyle(PlanFitInk.faint)
                        .fixedSize(horizontal: false, vertical: true)
                    ProvenanceTag(provenance: .derived)
                }
            }
        }
        .planFitCard(.lede)
    }

    // MARK: The rest

    /// The verdicts the lede did not speak for. One row each — never merged,
    /// because "four limits fit and one interrupts you" is not the same account
    /// as "five limits fit".
    private var otherVerdicts: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            PlanFitSectionHeader(
                title: L.tr("다른 한도의 판정", "The other limits' verdicts"),
                subtitle: L.tr(
                    "한도마다 따로 판정합니다. 하나가 보류라고 나머지가 보류인 것도, 하나가 맞는다고 나머지가 맞는 것도 아닙니다.",
                    "Each limit is judged on its own. One withheld verdict does not withhold the rest, and one that fits does not vouch for the others."
                )
            )
            ForEach(others) { verdict in
                SegmentVerdictRow(verdict: verdict)
            }
        }
        .planFitCard(.section)
    }
}

// MARK: - One limit's verdict

struct SegmentVerdictRow: View {
    let verdict: SegmentVerdictModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                // Symbol AND word. The colour is the third carrier, never the
                // first (FR-058).
                Image(systemName: verdict.kind.symbolName)
                    .font(.system(size: PlanFitType.caption, weight: .semibold))
                Text(verdict.kind.badge)
                    .font(.system(size: PlanFitType.caption, weight: .semibold))
                Text("· \(verdict.scope)")
                    .font(.system(size: PlanFitType.caption))
                Spacer(minLength: 0)
            }
            .foregroundStyle(PlanFitInk.support)

            Text(verdict.headline)
                .font(.system(size: PlanFitType.body, weight: .medium))
                .foregroundStyle(PlanFitInk.strong)
                .fixedSize(horizontal: false, vertical: true)

            if let availability = verdict.availability {
                Text(availability)
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.support)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let headroom = verdict.headroom {
                Text(headroom.sensitivity)
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.support)
                    .fixedSize(horizontal: false, vertical: true)
                Text(headroom.caveat)
                    .font(.system(size: PlanFitType.tiny))
                    .foregroundStyle(PlanFitInk.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                Text(verdict.basis)
                    .font(.system(size: PlanFitType.tiny))
                    .foregroundStyle(PlanFitInk.faint)
                    .fixedSize(horizontal: false, vertical: true)
                ProvenanceTag(provenance: .derived)
            }
        }
        .planFitCard(.inner)
        .accessibilityElement(children: .combine)
    }
}
