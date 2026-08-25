import SwiftUI

// MARK: - Claude against Codex (T054, T055 / contract W2, FR-022…FR-025)
//
// The naive version of this section is two columns of percentages and an arrow
// pointing at the bigger one. Both halves of that are wrong here.
//
// **The spans differ.** Codex windows are recovered retroactively from rollout
// files and reach back as far as the files do; Claude windows exist only from
// the moment polling started. A comparison over each provider's own history
// would credit Codex with weeks Claude was never watched for — so the figures
// are computed on the overlap, and the overlap is printed at the top of the
// section rather than left implicit. What each provider has outside it is named
// too, so the reader can see what was set aside.
//
// **The limits differ.** Claude splits its weekly limit by model; every Codex
// window carries `limit_id="codex"`. Neither provider publishes the absolute
// size of a limit, so one side's 40% is not the other side's 40%. The two
// utilisation figures therefore never share an axis, a bar or a scale: what is
// put side by side is time and counts, and the limit systems sit below the rule
// as descriptions rather than as measurements.
//
// With one provider (T055) the section becomes a single readout that says what
// is missing and why an absence of records is not evidence of an absence of
// use — a provider with polling switched off looks exactly like one that is not
// being used.

struct ProviderComparisonSection: View {
    let model: ProviderComparisonModel

    /// Side by side at 800pt; stacked when the window cannot give each column
    /// a readable width.
    static let columns = [GridItem(.adaptive(minimum: 320), spacing: DS.md, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            PlanFitSectionHeader(title: title, subtitle: subtitle)

            // FR-024. Named before any number is read, because it is the
            // qualifier on all of them.
            if let period = model.commonPeriodNote {
                PlanFitMark(tone: .neutral, text: period, size: PlanFitType.body)
            }
            if let unavailable = model.unavailableNote {
                Text(unavailable)
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.support)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: Self.columns, spacing: DS.md) {
                ForEach(model.sides) { side in
                    ProviderComparisonColumn(side: side, showsMetrics: model.state != .noOverlap)
                }
            }

            // FR-023, at the foot: the sentence that stops the columns above
            // being read as one scale.
            Divider().opacity(0.4)
            Text(model.incomparableNote)
                .font(.system(size: PlanFitType.caption))
                .foregroundStyle(PlanFitInk.support)
                .fixedSize(horizontal: false, vertical: true)
        }
        .planFitCard(.section)
    }

    private var title: String {
        model.state == .singleProvider
            ? L.tr("공급자 현황", "Provider readout")
            : L.tr("공급자 비교", "Claude against Codex")
    }

    private var subtitle: String {
        switch model.state {
        case .singleProvider:
            return L.tr(
                "한 공급자에만 기록이 있어 비교가 성립하지 않습니다.",
                "Only one provider has history, so there is no comparison to draw."
            )
        case .noOverlap:
            return L.tr(
                "두 공급자를 같은 기간에 관측한 적이 없습니다.",
                "The two providers were never observed over the same period."
            )
        case .comparable, .none:
            return L.tr(
                "두 공급자의 히스토리는 시작 시점이 다릅니다. 아래 수치는 양쪽이 모두 관측된 기간에서만 셌습니다.",
                "The two histories start at different times. Everything below is counted inside the period both were observed in."
            )
        }
    }
}

// MARK: - One provider's column

struct ProviderComparisonColumn: View {
    let side: ProviderComparisonModel.Side
    /// False when there is no common period to count over — the column then
    /// shows what it has and no figures, rather than figures over nothing.
    let showsMetrics: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text(side.title)
                .font(.system(size: PlanFitType.body, weight: .semibold))
                .foregroundStyle(PlanFitInk.strong)

            VStack(alignment: .leading, spacing: 1) {
                Text(side.historySpan)
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.support)
                Text(side.collectionNote)
                    .font(.system(size: PlanFitType.tiny))
                    .foregroundStyle(PlanFitInk.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsMetrics {
                VStack(alignment: .leading, spacing: DS.xs) {
                    ForEach(side.metrics) { metric in
                        MetricRow(metric: metric)
                    }
                }
            }

            if let excluded = side.excludedNote {
                Text(excluded)
                    .font(.system(size: PlanFitType.tiny))
                    .foregroundStyle(PlanFitInk.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Below the rule on purpose: the limit system is what makes the
            // utilisation figures incomparable, so it is described rather than
            // measured.
            Divider().opacity(0.3)
            Text(side.limitSystem)
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .planFitCard(.inner)
    }
}

// MARK: - One comparable figure

private struct MetricRow: View {
    let metric: ProviderComparisonModel.Metric

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
            Text(metric.label)
                .font(.system(size: PlanFitType.caption))
                .foregroundStyle(PlanFitInk.support)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.xs)
            Text(metric.value)
                .font(.system(size: PlanFitType.metric, weight: .semibold))
                .foregroundStyle(PlanFitInk.strong)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ProvenanceTag(provenance: metric.provenance)
        }
        .accessibilityElement(children: .combine)
    }
}
