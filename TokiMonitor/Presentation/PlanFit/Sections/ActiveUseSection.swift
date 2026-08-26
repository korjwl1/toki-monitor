import SwiftUI

// MARK: - Active use and exhaustion timing (T048)
//
// This is the section the feature exists for. The user's own point:
//
//   "10x 쓰는데 전체적으론 윈도우를 많이 남기는 편이지만, 그게 잘 때 못 써서
//    그런 거고 윈도우 맨날 꽉꽉 채워 써서 작업이 자주 중단되는 사람"
//
// Two readings of the same account, and only one of them is true. So the three
// sets — worked in, confirmed unused, cannot tell — are drawn side by side and
// labelled with which one a verdict is allowed to read headroom from. The idle
// set is shown rather than hidden: it is the honest answer to "how much of the
// plan goes unused", and it is precisely what must not be counted as slack.
//
// And the exhaustions carry their timing. Running out ten minutes before a
// reset and being cut off with three hours left are different events; the strip
// below places every exhaustion by how much of the cycle was still to run, so
// an account whose max-outs all cluster at the reset end reads differently at a
// glance from one whose max-outs sit at the start.

struct ActiveUseSection: View {
    let limits: [ActiveUseLimitModel]
    let quietLimitsNote: String?

    static let columns = [GridItem(.adaptive(minimum: 340), spacing: DS.md, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            PlanFitSectionHeader(
                title: L.tr("일하고 있을 때의 한도", "The limit while you were working"),
                subtitle: L.tr(
                    "전체 평균은 자느라 못 쓴 창까지 여유로 셉니다. 실사용이 확인된 창만 따로 보고, 소진한 창은 리셋까지 남은 시간과 함께 봅니다.",
                    "An average over every window counts the ones you slept through as spare capacity. These are the windows with confirmed work, and every exhaustion with the time it left on the clock."
                )
            )
            if limits.isEmpty {
                Text(L.tr(
                    "실사용이 확인된 창도 소진도 아직 없습니다. 실사용 시간은 하한값이라, 값이 작다는 것만으로 '사용 없음'이라고 하지 않습니다.",
                    "No confirmed worked windows and no exhaustions yet. Recorded work time is a floor, so a small value is not by itself a claim that nothing happened."
                ))
                .font(.system(size: PlanFitType.body))
                .foregroundStyle(PlanFitInk.support)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: Self.columns, spacing: DS.md) {
                    ForEach(limits) { limit in
                        ActiveUseCard(limit: limit)
                    }
                }
            }
            if let quietLimitsNote {
                Text(quietLimitsNote)
                    .font(.system(size: PlanFitType.tiny))
                    .foregroundStyle(PlanFitInk.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .planFitCard(.section)
    }
}

// MARK: - One limit

struct ActiveUseCard: View {
    let limit: ActiveUseLimitModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text(limit.title)
                .font(.system(size: PlanFitType.body, weight: .semibold))
                .foregroundStyle(PlanFitInk.strong)

            ForEach(limit.splits) { split in
                splitRow(split)
            }

            Divider().opacity(0.4)

            PlanFitMark(
                tone: limit.ticks.isEmpty ? .neutral : .attention,
                text: limit.exhaustionBreakdown,
                size: PlanFitType.body
            )

            if let median = limit.medianTimeLeftText, let speech = limit.medianTimeLeftSpeech {
                HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                    Text(median)
                        .font(.system(size: PlanFitType.metric, weight: .semibold))
                        .foregroundStyle(PlanFitInk.strong)
                        .fixedSize(horizontal: false, vertical: true)
                    ProvenanceTag(provenance: .derived)
                }
                .planFitFigure(speech)
            }
            if let rate = limit.interruptionRateText, let speech = limit.interruptionRateSpeech {
                HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                    Text(rate)
                        .font(.system(size: PlanFitType.caption))
                        .foregroundStyle(PlanFitInk.support)
                    ProvenanceTag(provenance: .derived)
                }
                .planFitFigure(speech)
            }

            if !limit.ticks.isEmpty {
                ExhaustionTimingStrip(ticks: limit.ticks)
            }

            ForEach(limit.recentEvents) { event in
                eventRow(event)
            }

            Text(limit.thresholdNote)
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .planFitCard(.inner)
    }

    private func splitRow(_ split: ActiveUseLimitModel.Split) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                // The set a verdict reads from is marked, so "which numbers
                // became the recommendation" is on screen rather than in a
                // contract document.
                Image(systemName: split.isHeadroomSource ? "arrow.right.circle.fill" : "circle")
                    .font(.system(size: PlanFitType.caption, weight: .semibold))
                    .foregroundStyle(split.isHeadroomSource ? PlanFitInk.strong : PlanFitInk.faint)
                Text(split.title)
                    .font(.system(size: PlanFitType.caption, weight: split.isHeadroomSource ? .semibold : .regular))
                    .foregroundStyle(PlanFitInk.support)
                Text(L.tr("창 \(split.count)개", "\(split.count) windows"))
                    .font(.system(size: PlanFitType.metric, weight: .semibold))
                    .foregroundStyle(PlanFitInk.strong)
                Text(split.distribution)
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.support)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                ProvenanceTag(provenance: split.provenance)
            }
            if let note = split.note {
                Text(note)
                    .font(.system(size: PlanFitType.tiny))
                    .foregroundStyle(PlanFitInk.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, PlanFitType.caption + DS.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .planFitFigure(split.speech)
    }

    private func eventRow(_ event: ActiveUseLimitModel.Event) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
            Text(event.day)
                .font(.system(size: PlanFitType.caption, design: .monospaced))
                .foregroundStyle(PlanFitInk.faint)
            PlanFitMark(
                tone: ActiveUseCard.tone(for: event.severity),
                text: event.text,
                size: PlanFitType.caption
            )
            Text("· \(event.severity.label)")
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.faint)
            if event.hitCredits {
                Text(L.tr("· 크레딧으로 계속", "· continued on credits"))
                    .font(.system(size: PlanFitType.tiny))
                    .foregroundStyle(PlanFitInk.faint)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Severity to mark tone. Kept in the view: the domain decides how much an
    /// exhaustion counts, and nothing about that decision is a colour.
    static func tone(for severity: ActiveUseLimitModel.Severity) -> PlanFitMark.Tone {
        switch severity {
        case .interrupting: return .blocked
        case .partial: return .attention
        case .harmless, .unknownTiming: return .neutral
        }
    }
}

// MARK: - Timing strip

/// Every exhaustion placed by how much of the cycle was still to run.
///
/// The left edge is the start of the cycle and the right edge is the reset, so
/// a tick near the right ran out with minutes to go and one near the left was
/// blocked for most of the cycle. The band at the right end is the share below
/// which the domain stops counting an exhaustion as an interruption at all;
/// it is drawn AND labelled, so the threshold is visible where its consequences
/// are (FR-021).
///
/// Tick height encodes severity as well as colour: a full interruption is a
/// tall mark, a harmless one is a short one.
struct ExhaustionTimingStrip: View {
    let ticks: [ActiveUseLimitModel.Tick]

    static let height: CGFloat = 30

    private var unknownCount: Int {
        ticks.filter { $0.fractionLeft == nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.05))

                    // The "reset was imminent" band, at the right edge.
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: width * WindowStats.harmlessExhaustionFractionLeft)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    ForEach(ticks) { tick in
                        if let fraction = tick.fractionLeft {
                            let position = min(1, max(0, 1 - fraction))
                            RoundedRectangle(cornerRadius: 1)
                                .fill(ActiveUseCard.tone(for: tick.severity).color)
                                .frame(width: 2, height: Self.tickHeight(tick.severity))
                                .offset(x: max(0, min(width - 2, width * position - 1)))
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                    }
                }
            }
            .frame(height: Self.height)
            .accessibilityHidden(true)

            HStack {
                Text(L.tr("창 시작 (남은 시간 최대)", "cycle start (most time left)"))
                Spacer(minLength: DS.sm)
                Text(L.tr(
                    "리셋 직전 \(Int(WindowStats.harmlessExhaustionFractionLeft * 100))% 구간",
                    "last \(Int(WindowStats.harmlessExhaustionFractionLeft * 100))% before reset"
                ))
            }
            .font(.system(size: PlanFitType.tiny))
            .foregroundStyle(PlanFitInk.faint)

            if unknownCount > 0 {
                Text(L.tr(
                    "\(unknownCount)회는 소진 시점이 기록되지 않아 이 축에 놓지 못했습니다 — 남은 시간 0이 아니라 미상이며, 방해로는 온전히 셉니다.",
                    "\(unknownCount) could not be placed on this axis because the moment they ran out was never sampled — that is unknown, not zero time left, and it still counts as a full interruption."
                ))
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.faint)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func tickHeight(_ severity: ActiveUseLimitModel.Severity) -> CGFloat {
        switch severity {
        case .interrupting: return height * 0.85
        case .partial: return height * 0.6
        case .harmless: return height * 0.35
        case .unknownTiming: return height * 0.35
        }
    }
}
