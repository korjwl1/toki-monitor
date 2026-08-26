import SwiftUI

// MARK: - "If this had been a subscription" (T066…T070 / contract V9)
//
// The block that exists to refuse.
//
// The question is a real one — the same shape as a cloud Savings Plan
// recommendation: take what the past cost per unit, re-price it under a
// commitment. The difference is the whole reason this block does not answer
// it. **A Savings Plan changes only the price. A subscription imposes limits
// at the same time**, and an account that paid per token has never met a
// 5-hour or a weekly limit, so pricing the future on the past's unlimited
// terms is optimistic by construction — the mistake Ofgem's personalised
// saving projections were withdrawn for (research §B-4).
//
// Three rules are visible in what this file does:
//
// - **It is always drawn** (T067). A block that vanishes when it cannot
//   compute reads as a feature that forgot; one that says "cannot be
//   determined for this account" and names each reason reads as a decision.
// - **It cannot render money alone.** There is one optional to unwrap —
//   `model.result` — and it holds the figure AND the interruptions. There is
//   no branch in this file that draws one without the other, because there is
//   no value that carries one without the other.
// - **It says why, not just that.** `structuralNote` is on screen in every
//   state, including the states where nothing is computed, because a reader
//   who is not told why the money is missing supplies the optimistic answer
//   themselves.

struct SubscriptionComparisonSection: View {
    let model: SubscriptionComparisonModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            PlanFitSectionHeader(title: model.title, subtitle: model.purpose)

            // Symbol and word, never colour alone (FR-058). A refusal is a
            // normal outcome, so it takes the neutral tone — the same rule the
            // withheld verdict follows.
            PlanFitMark(
                tone: .neutral,
                text: model.headline,
                size: PlanFitType.metric
            )
            .accessibilityLabel(accessibilityHeadline)

            if !model.reasons.isEmpty { reasons }

            if let result = model.result { resultBlock(result) }

            if let possible = model.whatWouldMakeItPossible {
                Text(possible)
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.support)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(model.structuralNote)
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.faint)
                .fixedSize(horizontal: false, vertical: true)

            if let basis = model.basis {
                HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                    Text(basis)
                        .font(.system(size: PlanFitType.tiny))
                        .foregroundStyle(PlanFitInk.faint)
                    ProvenanceTag(provenance: .derived)
                }
            }
        }
        .planFitCard(.section)
    }

    /// VoiceOver reads the refusal as a conclusion about this account rather
    /// than as a stray phrase (T072).
    private var accessibilityHeadline: String {
        "\(model.title): \(model.headline)"
    }

    // MARK: Why not

    /// Every reason, one per line. Collapsing them into "not enough data"
    /// would make the gap look like something more history closes, and two of
    /// the three are not about history at all.
    private var reasons: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            ForEach(Array(model.reasons.enumerated()), id: \.offset) { _, reason in
                HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                    Image(systemName: "minus")
                        .font(.system(size: PlanFitType.tiny, weight: .semibold))
                        .foregroundStyle(PlanFitInk.faint)
                    Text(reason)
                        .font(.system(size: PlanFitType.caption))
                        .foregroundStyle(PlanFitInk.support)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L.tr("판단할 수 없는 이유", "Why it cannot be determined"))
    }

    // MARK: The answer, when there is one

    /// Money and interruptions, in that order of appearance and the reverse
    /// order of prominence: the interruption sentence is the larger type,
    /// because it is the half a reader is inclined to skip.
    private func resultBlock(_ result: SubscriptionComparisonModel.Result) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                Text(result.money.label)
                    .font(.system(size: MoneyFootnote.labelSize))
                    .foregroundStyle(PlanFitInk.support)
                Text(result.money.amount)
                    .font(.system(size: MoneyFootnote.amountSize, weight: .medium))
                    .foregroundStyle(PlanFitInk.support)
                // FR-045, carried by `MoneyNote` itself.
                Text(result.money.qualifier)
                    .font(.system(size: MoneyFootnote.qualifierSize))
                    .foregroundStyle(PlanFitInk.faint)
                Spacer(minLength: 0)
                ProvenanceTag(provenance: .derived)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(result.money.label) \(result.money.amount), \(result.money.qualifier)")

            PlanFitMark(tone: .attention, text: result.exposure, size: PlanFitType.body)
            Text(result.rate)
                .font(.system(size: PlanFitType.caption))
                .foregroundStyle(PlanFitInk.support)
        }
        .planFitCard(.inner)
    }
}
