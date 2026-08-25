import SwiftUI

// MARK: - Money, in the position it is required to keep (T058 / FR-045, FR-046)
//
// Two rules, and both of them are about placement rather than wording.
//
// **Money is a supporting figure here, never the headline.** The default reader
// of this page is a flat-rate subscriber: the invoice does not move with any of
// this, and research §B-11 (Lambrecht & Skiera) found that putting spend in
// front of flat-rate users suppresses their usage. So the figure is drawn at
// caption size in the last block before the legend — after the verdict, after
// the trend, after every limit and every headroom statement. `T059` pins that
// in pixels rather than in a review comment.
//
// **Every figure carries "at current prices".** There is no price history in
// this product; a cost is always computed against today's table. A bare figure
// would be a claim about what the past cost, which was never measured. The
// qualifier is set by `MoneyNote`'s initialiser, so there is no way to render
// an amount without it.

struct MoneyFootnote: View {
    let model: MoneySummaryModel

    /// The type sizes this block is allowed to use. Named so the hierarchy
    /// claim is something a test can read rather than something a reviewer has
    /// to eyeball: money must not reach the size of a limit's metric, let
    /// alone the page's conclusion.
    static let amountSize: CGFloat = PlanFitType.caption
    static let labelSize: CGFloat = PlanFitType.caption
    static let qualifierSize: CGFloat = PlanFitType.tiny

    var body: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            Text(L.tr("추정 비용", "Estimated spend"))
                .font(.system(size: PlanFitType.caption, weight: .semibold))
                .foregroundStyle(PlanFitInk.support)

            ForEach(model.notes) { note in
                MoneyRow(note: note)
            }

            Text(model.placementNote)
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .planFitCard(.inner)
    }
}

private struct MoneyRow: View {
    let note: MoneyNote

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                Text(note.label)
                    .font(.system(size: MoneyFootnote.labelSize))
                    .foregroundStyle(PlanFitInk.support)
                Text(note.amount)
                    .font(.system(size: MoneyFootnote.amountSize, weight: .medium))
                    .foregroundStyle(PlanFitInk.support)
                // FR-045, bound to the figure by the type that carries them
                // both — there is no render path with one and not the other.
                Text(note.qualifier)
                    .font(.system(size: MoneyFootnote.qualifierSize))
                    .foregroundStyle(PlanFitInk.faint)
                Spacer(minLength: 0)
                ProvenanceTag(provenance: .derived)
            }
            if let coverage = note.coverage {
                Text(coverage)
                    .font(.system(size: PlanFitType.tiny))
                    .foregroundStyle(PlanFitInk.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.label) \(note.amount), \(note.qualifier)")
    }
}
