import SwiftUI

// MARK: - Limit status (T047, T050, T051, T052)
//
// The old page put four statistics side by side in an evenly-split `HStack`,
// each carrying up to three lines of caption. At the 800pt minimum with four
// or more segments the columns stretched and the captions collapsed, and with
// eight segments the reader met 32 numbers in a flat list.
//
// Two changes fix that. Limits are grouped under their provider and laid out
// in an adaptive grid, so eight of them wrap into rows instead of squeezing
// into columns; and each card is one chunk of four facts — distribution,
// sample, exhaustions, in-flight window — with the caveats attached to the
// fact they qualify rather than stacked underneath everything.
//
// The card never says "you have headroom" on its own. `HeadroomNote` carries
// the V8 caveat with it and cannot be built without one, so slack and the
// sentence that stops it being read as a guarantee arrive together or not at
// all.

struct LimitStatusSection: View {
    let groups: [LimitProviderGroup]

    /// Two columns at 800pt, three on a wide window, one when the window is
    /// narrower than a readable card. Nothing here can push the page wider
    /// than its container.
    static let columns = [GridItem(.adaptive(minimum: 300), spacing: DS.md, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            PlanFitSectionHeader(
                title: L.tr("한도별 소진 현황", "How each limit is running"),
                subtitle: L.tr(
                    "완료된 창만 셉니다. 퍼센트는 그 창이 속한 요금제의 한도 기준이라 티어가 다르면 같은 수치가 아닙니다.",
                    "Finished windows only. A percentage is relative to the tier's own limit, so figures from different tiers are not the same measurement."
                )
            )
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: DS.sm) {
                    Text(group.providerTitle)
                        .font(.system(size: PlanFitType.body, weight: .semibold))
                        .foregroundStyle(PlanFitInk.strong)
                    LazyVGrid(columns: Self.columns, spacing: DS.md) {
                        ForEach(group.limits) { limit in
                            LimitStatusCard(limit: limit)
                        }
                    }
                }
            }
        }
        .planFitCard(.section)
    }
}

// MARK: - One limit

struct LimitStatusCard: View {
    let limit: LimitStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            title
            distribution
            Divider().opacity(0.4)
            exhaustion
            if let open = limit.openWindowText {
                fact(text: open, tone: .neutral)
            }
            if let excluded = limit.excludedText {
                caveat(excluded)
            }
            if let headroom = limit.headroom {
                headroomBlock(headroom)
            } else if let withheld = limit.withheldText {
                caveat(withheld)
            }
        }
        .planFitCard(.inner)
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
            Text(limit.title)
                .font(.system(size: PlanFitType.body, weight: .semibold))
                .foregroundStyle(PlanFitInk.strong)
            if let plan = limit.planLabel {
                Text(plan)
                    .font(.system(size: PlanFitType.tiny, design: .monospaced))
                    .foregroundStyle(PlanFitInk.faint)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            Spacer(minLength: 0)
            if limit.isHistorical {
                Text(L.tr("이전 요금제", "previous plan"))
                    .font(.system(size: PlanFitType.tiny, weight: .medium))
                    .foregroundStyle(PlanFitInk.faint)
            }
        }
    }

    private var distribution: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                Text(L.tr("완료 창의 peak 분포", "Peak distribution"))
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.support)
                Spacer(minLength: 0)
                ProvenanceTag(provenance: limit.distributionProvenance)
            }
            Text(limit.distribution)
                .font(.system(size: PlanFitType.metric, weight: .semibold))
                .foregroundStyle(PlanFitInk.strong)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            UtilisationMeter(
                p50: limit.meterP50,
                p95: limit.meterP95,
                isCensored: limit.meterIsCensored
            )
            Text(limit.sampleText)
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.faint)
        }
        .accessibilityElement(children: .combine)
    }

    private var exhaustion: some View {
        fact(
            text: limit.exhaustionText,
            tone: limit.hasExhaustions ? (limit.paidOverflowCredits ? .blocked : .attention) : .neutral
        )
    }

    private func fact(text: String, tone: PlanFitMark.Tone) -> some View {
        PlanFitMark(tone: tone, text: text, size: PlanFitType.body)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sensitivity and caveat, always together (T051 / contract V8).
    private func headroomBlock(_ note: HeadroomNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.sensitivity)
                .font(.system(size: PlanFitType.caption))
                .foregroundStyle(PlanFitInk.support)
                .fixedSize(horizontal: false, vertical: true)
            caveat(note.caveat)
        }
    }

    private func caveat(_ text: String) -> some View {
        Text(text)
            .font(.system(size: PlanFitType.tiny))
            .foregroundStyle(PlanFitInk.faint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Meter

/// Where the typical and the heaviest finished window sat against the limit.
///
/// The two markers are different shapes and both are labelled, so the pair is
/// legible without colour. A censored p95 is drawn as an arrow running off the
/// right edge rather than as a marker at 100 — the sample was clipped there,
/// and a marker would claim the demand stopped where the recording did.
struct UtilisationMeter: View {
    let p50: Double?
    let p95: Double?
    let isCensored: Bool

    static let height: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 4)
                    .frame(maxHeight: .infinity, alignment: .center)

                if let p95 {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(2, width * fraction(p95)), height: 4)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                if let p50 {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .offset(x: max(0, min(width - 7, width * fraction(p50) - 3.5)))
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                if let p95 {
                    Group {
                        if isCensored {
                            Image(systemName: "arrow.right.to.line")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(PlanFitInk.strong)
                        } else {
                            Rectangle()
                                .fill(PlanFitInk.strong)
                                .frame(width: 2, height: Self.height * 0.8)
                        }
                    }
                    .offset(x: max(0, min(width - 10, width * fraction(p95) - 5)))
                    .frame(maxHeight: .infinity, alignment: .center)
                }
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }

    private func fraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value / 100))
    }
}
