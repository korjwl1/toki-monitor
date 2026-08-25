import SwiftUI

// MARK: - Period trend (T045, T046)
//
// A pure projection of `PeriodTrendModel`. No bindings, no closures, no state:
// the period unit is chosen once, at the top of the page, and everything here
// follows from the value it produced. That is what makes "the toggle is the
// only control" a property of the code rather than a promise.
//
// The unfinished period is the thing this section most has to get right. A
// month three days in is not a quiet month, and a bar that merely renders
// shorter says exactly that it was. So the in-progress bar is drawn hollow
// with a dashed outline, labelled "진행 중 · n/31일", and its comparison
// against the previous period is the length-neutral one — three carriers, none
// of them colour.

struct PeriodTrendSection: View {
    let model: PeriodTrendModel

    /// Enough buckets to read a trend without the bars becoming hairlines at
    /// 800pt. Weekly over a 28-day lookback produces five.
    static let maxBars = 12

    private var bars: [PeriodTrendModel.Bar] {
        Array(model.bars.suffix(Self.maxBars))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            header
            if model.isEmpty {
                Text(L.tr(
                    "완료된 윈도우가 아직 없어 기간 추이를 그리지 않았습니다. 0으로 채운 차트는 사실이 아닙니다.",
                    "No finished windows yet, so there is no trend to draw. A chart of zeroes would not be a fact."
                ))
                .font(.system(size: PlanFitType.body))
                .foregroundStyle(PlanFitInk.support)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                chart
                if let latest = bars.last {
                    latestReadout(latest)
                }
            }
        }
        .planFitCard(.section)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                PlanFitSectionHeader(
                    title: model.unit == .monthly
                        ? L.tr("월별 사용 추이", "Monthly trend")
                        : L.tr("주별 사용 추이", "Weekly trend"),
                    subtitle: L.tr(
                        "기간마다 기록된 실사용 시간. 데몬이 재시작하면 누적이 초기화되므로 실제 사용은 이보다 많습니다.",
                        "Recorded work time per period. The daemon's accumulation restarts with the daemon, so real usage is at or above this."
                    )
                )
                ProvenanceTag(provenance: model.provenance)
            }
            Text(model.spanNote)
                .font(.system(size: PlanFitType.caption))
                .foregroundStyle(PlanFitInk.faint)
        }
    }

    private var chart: some View {
        HStack(alignment: .bottom, spacing: DS.sm) {
            ForEach(bars) { bar in
                barColumn(bar)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func barColumn(_ bar: PeriodTrendModel.Bar) -> some View {
        VStack(spacing: DS.xs) {
            // The number above the bar, so the reading never depends on
            // measuring a height against a scale that is not drawn.
            Text(PlanFitFormat.hours(bar.hours))
                .font(.system(size: PlanFitType.caption, weight: .medium))
                .foregroundStyle(PlanFitInk.strong)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // FR-007. Months are 28 to 31 days long, so an absolute total is
            // not comparable with the one beside it — every monthly bucket
            // carries its own daily rate, not just the latest one.
            if model.unit == .monthly {
                Text(bar.dailyAverageHours.map {
                    L.tr("일 \(PlanFitFormat.hours($0))", "\(PlanFitFormat.hours($0))/day")
                } ?? L.tr("하루 미만", "under a day"))
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.support)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: Self.chartHeight)
                barShape(bar)
            }
            .frame(height: Self.chartHeight)

            if bar.exhaustions > 0 {
                PlanFitMark(
                    tone: .attention,
                    text: L.tr("소진 \(bar.exhaustions)", "\(bar.exhaustions) out"),
                    size: PlanFitType.tiny
                )
                .lineLimit(1)
            }

            Text(bar.label)
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.support)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if !bar.isComplete, let note = bar.incompleteNote {
                Text(note)
                    .font(.system(size: PlanFitType.tiny, weight: .medium))
                    .foregroundStyle(PlanFitInk.support)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.accessibilityLabel)
    }

    /// A finished period is a solid bar; an unfinished one is hollow with a
    /// dashed outline. Shape first, then the label under it — colour carries
    /// nothing here.
    @ViewBuilder
    private func barShape(_ bar: PeriodTrendModel.Bar) -> some View {
        let height = max(2, Self.chartHeight * bar.heightFraction)
        if bar.isComplete {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(0.75))
                .frame(height: height)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    Color.accentColor.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                )
                .background(
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.12))
                )
                .frame(height: height)
        }
    }

    static let chartHeight: CGFloat = 88

    /// The most recent period spelled out: total, daily average, and the rate
    /// of change — never an absolute difference (FR-008).
    private func latestReadout(_ bar: PeriodTrendModel.Bar) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                Text(bar.label)
                    .font(.system(size: PlanFitType.body, weight: .medium))
                    .foregroundStyle(PlanFitInk.strong)
                if !bar.isComplete, let note = bar.incompleteNote {
                    PlanFitMark(tone: .neutral, text: note, size: PlanFitType.caption)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: DS.lg) {
                metric(
                    L.tr("총량", "Total"),
                    L.tr("\(PlanFitFormat.hours(bar.hours)) 이상", "\(PlanFitFormat.hours(bar.hours))+")
                )
                // FR-007: months are not the same length, so the absolute
                // total never stands alone in monthly mode.
                if let average = bar.dailyAverageHours {
                    metric(
                        L.tr("일평균", "Per day"),
                        L.tr("\(PlanFitFormat.hours(average)) 이상", "\(PlanFitFormat.hours(average))+")
                    )
                } else {
                    metric(
                        L.tr("일평균", "Per day"),
                        L.tr("하루가 차지 않았습니다", "not a full day yet")
                    )
                }
                if let change = PlanFitFormat.changeRate(bar.changeRatePct) {
                    metric(
                        bar.changeIsDailyAverage
                            ? L.tr("직전 기간 대비 일평균", "vs previous, per day")
                            : L.tr("직전 기간 대비", "vs previous"),
                        change
                    )
                }
            }

            if bar.dailyAverageHours != nil, bar.changeRatePct == nil {
                Text(L.tr(
                    "직전 기간이 없거나 사용이 0이어서 변동률을 내지 않았습니다 — 0에서의 증가는 퍼센트가 아닙니다.",
                    "No rate of change: there is no previous period, or it had no usage — growth from zero is not a percentage."
                ))
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.faint)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, DS.xs)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: PlanFitType.caption))
                .foregroundStyle(PlanFitInk.support)
            Text(value)
                .font(.system(size: PlanFitType.metric, weight: .semibold))
                .foregroundStyle(PlanFitInk.strong)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
