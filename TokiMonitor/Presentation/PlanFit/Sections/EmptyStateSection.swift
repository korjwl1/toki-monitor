import SwiftUI

// MARK: - What the page cannot yet say (T060…T064 / contract W3, W4)
//
// **This is not an edge case.** Window history first shipped in v0.3.0 and a
// new database has no rows, so "not much data" is the day-one
// state of every existing account and this is the screen most readers will
// spend the most time on. If it renders as a stub, the feature reads as broken
// no matter how good the fully-populated page looks.
//
// Three things it therefore refuses to do:
//
// - **No chart of zeroes.** An account with no windows gets a sentence saying
//   collection has not started and the concrete conditions that start it — one
//   per line, so a reader can find which of them is missing rather than parsing
//   a paragraph.
// - **No page-wide blanking.** Sufficiency is judged per metric (T063). A plan
//   verdict needs four times the longest limit cycle; a limit's exhaustion
//   count needs one finished window. Only the metrics that cannot be read yet
//   are listed here — the rest are already on screen as themselves.
// - **No error badge on a missing feature.** A daemon that does not serve
//   windows is a capability gap, a daemon that is not answering is a fault, and
//   `AccountShapeAbsence` keeps the four causes apart rather than collapsing
//   them into one red triangle (contract W4).

struct EmptyStateSection: View {
    let model: DataReadinessModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            if let gap = model.gap { CapabilityGapCard(gap: gap) }

            if model.collectionNotStarted {
                collectionNotStarted
            }

            if !model.unreadyMetrics.isEmpty {
                metricReadiness
            }

            // T062. Named where the trend is, not folded into it: a period
            // still running is a fact about the calendar, not about usage.
            if let incomplete = model.incompletePeriodNote {
                PlanFitMark(tone: .neutral, text: incomplete, size: PlanFitType.caption)
            }
        }
        .planFitCard(.section)
    }

    // MARK: Day one (T060)

    private var collectionNotStarted: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            if let headline = model.headline {
                Text(headline)
                    .font(.system(size: PlanFitType.metric, weight: .semibold))
                    .foregroundStyle(PlanFitInk.strong)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L.tr(
                "이것은 오류가 아니라 수집이 아직 시작되지 않은 상태입니다. 아래 세 가지가 갖춰지면 채워지기 시작합니다.",
                "This is not a failure — collection has not started. It begins filling once the three conditions below hold."
            ))
            .font(.system(size: PlanFitType.body))
            .foregroundStyle(PlanFitInk.support)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DS.xs) {
                ForEach(Array(model.requirements.enumerated()), id: \.offset) { index, requirement in
                    HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                        Text("\(index + 1).")
                            .font(.system(size: PlanFitType.caption, weight: .semibold))
                            .foregroundStyle(PlanFitInk.faint)
                        Text(requirement)
                            .font(.system(size: PlanFitType.caption))
                            .foregroundStyle(PlanFitInk.support)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Per metric (T061, T063)

    private var metricReadiness: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            PlanFitSectionHeader(
                title: L.tr("아직 읽을 수 없는 지표", "What cannot be read yet"),
                subtitle: L.tr(
                    "충분한지는 지표마다 따로 판단합니다. 하나가 부족하다고 나머지가 비지 않습니다 — 아래에 없는 지표는 이 페이지에 그대로 있습니다.",
                    "Sufficiency is judged per metric. One thin metric does not blank the rest — anything not listed here is on the page as itself."
                )
            )
            ForEach(model.unreadyMetrics) { metric in
                MetricReadinessRow(metric: metric)
            }
        }
    }
}

// MARK: - One metric

struct MetricReadinessRow: View {
    let metric: MetricReadiness

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                // Symbol and word: "shown but not interpreted" and "not shown"
                // are different states and must not depend on colour to be
                // told apart (FR-058).
                Image(systemName: symbolName)
                    .font(.system(size: PlanFitType.caption, weight: .semibold))
                Text(metric.metric)
                    .font(.system(size: PlanFitType.body, weight: .medium))
                Text("· \(statusWord)")
                    .font(.system(size: PlanFitType.caption))
                Spacer(minLength: 0)
            }
            .foregroundStyle(PlanFitInk.support)

            if !metric.reason.isEmpty {
                Text(metric.reason)
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.support)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Contract V1: a withholding says when it stops being one.
            if let availability = metric.availability {
                Text(availability)
                    .font(.system(size: PlanFitType.tiny))
                    .foregroundStyle(PlanFitInk.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .planFitCard(.inner)
        .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        switch metric.status {
        case .ready: return "checkmark.circle"
        case .observedOnly: return "eye"
        case .withheld: return "hourglass"
        }
    }

    private var statusWord: String {
        switch metric.status {
        case .ready: return L.tr("표시 가능", "readable")
        case .observedOnly: return L.tr("값만 표시, 해석 보류", "values shown, reading withheld")
        case .withheld: return L.tr("보류", "withheld")
        }
    }
}

// MARK: - The daemon cannot serve windows (T064)

/// A missing feature drawn as a missing feature.
///
/// Three of `AccountShapeAbsence`'s four cases are states a correctly working
/// system reaches; only an unreachable daemon is a fault. The tone follows that
/// distinction rather than the fact that something is absent.
struct CapabilityGapCard: View {
    let gap: CapabilityGapModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            PlanFitMark(
                tone: gap.isFailure ? .attention : .neutral,
                text: gap.headline,
                size: PlanFitType.metric
            )
            Text(gap.explanation)
                .font(.system(size: PlanFitType.body))
                .foregroundStyle(PlanFitInk.support)
                .fixedSize(horizontal: false, vertical: true)
            if let remedy = gap.remedy {
                Text(remedy)
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.support)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if gap.isCapabilityGap {
                Text(L.tr(
                    "기능 부재이지 고장이 아닙니다.",
                    "The feature is not there yet; nothing is broken."
                ))
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.faint)
            }
        }
        .planFitCard(.inner)
    }
}
