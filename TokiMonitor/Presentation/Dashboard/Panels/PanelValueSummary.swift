import Foundation

/// The key value of a panel, in words.
///
/// One sentence per panel type answering "what does this panel currently say?"
/// — the third of the four things FR-063 asks a panel to give a screen reader,
/// and the one that cannot be composed generically because "the value" of a
/// gauge, a table and a pie are three different shapes.
///
/// It reuses the renders' own resolution — `StatPanelView.statValue`,
/// `PanelSeries.rows`, `StateTimelineBuilder.spans` — rather than reading the
/// frames again. A summary computed a second way is a summary that can disagree
/// with the screen, and a reader who cannot see the screen has no way to catch
/// it.
///
/// Chart types name at most `maxSeries` series. A VoiceOver reader hears the
/// label straight through with no way to skim it, so a nine-series chart
/// reading out nine names and nine numbers before the state is worse than one
/// that says how many there are and names the biggest few.
@MainActor
enum PanelValueSummary {

    /// How many series a chart names before it starts counting instead.
    static let maxSeries = 3

    /// What this panel currently says, or nil when it has nothing to say.
    static func text(panel: PanelConfig, data: TimeSeriesData?, frames: FrameSet?,
                     hidden: Set<String> = []) -> String? {
        switch panel.panelType {
        case .stat:
            return statText(panel: panel, data: data, frames: frames)
        case .gauge:
            // A gauge with no number still has a scale, and `spokenValue`
            // will happily read out "-, on a scale from 0 to 100". That is a
            // sentence about the dial, not about the data: the state is what
            // the reader needs here, and it is spoken separately.
            guard StatPanelView.numericValue(panel: panel, data: data,
                                             frames: frames) != nil
            else { return nil }
            return GaugePanelView.spokenValue(panel: panel, data: data, frames: frames)
        case .timeSeries, .barChart:
            return seriesText(panel: panel, data: data, frames: frames, hidden: hidden)
        case .pieChart:
            return breakdownText(panel: panel, data: data, frames: frames)
        case .table:
            return tableText(panel: panel, data: data, frames: frames)
        case .stateTimeline:
            return timelineText(panel: panel, frames: frames)
        case .rowPanel, .unknown:
            // A row is a heading and an unknown type has its own spoken
            // explanation in `UnknownPanelView`; neither has a value.
            return nil
        }
    }

    // MARK: - Per type

    private static func statText(panel: PanelConfig, data: TimeSeriesData?,
                                 frames: FrameSet?) -> String? {
        let stat = StatPanelView.statValue(panel: panel, data: data, frames: frames)
        guard stat.value != "-" else { return nil }
        let number = StatPanelView.numericValue(panel: panel, data: data, frames: frames)
        guard let band = StatPanelView.band(panel: panel, value: number) else {
            return stat.value
        }
        // The band, always in words beside the number. On screen the value is
        // tinted; colour is never the only carrier of meaning (계약 R6), and
        // for this reader it carries nothing at all.
        return L.tr("\(stat.value), 임계값 \(band.label)",
                    "\(stat.value), threshold \(band.label)")
    }

    private static func seriesText(panel: PanelConfig, data: TimeSeriesData?,
                                   frames: FrameSet?, hidden: Set<String>) -> String? {
        let series = PanelSeries.chartSeriesWithGaps(
            metric: panel.effectiveMetric, panel: panel, frames: frames,
            data: data, hidden: hidden
        )
        guard !series.isEmpty else { return nil }
        // Biggest last value first: on a chart the eye goes to the top line,
        // and this is the reader's equivalent.
        let ranked = series
            .map { (name: $0.model, last: $0.points.compactMap(\.value).last) }
            .sorted { ($0.last ?? 0) > ($1.last ?? 0) }
        let named = ranked.prefix(maxSeries).map { entry -> String in
            guard let last = entry.last else {
                return L.tr("\(entry.name), 값 없음", "\(entry.name), no value")
            }
            return L.tr("\(entry.name), 마지막 \(GaugePanelView.label(last, panel: panel))",
                        "\(entry.name), latest \(GaugePanelView.label(last, panel: panel))")
        }
        var parts = [L.tr("계열 \(series.count)개", "\(series.count) series")]
        parts.append(contentsOf: named)
        if series.count > maxSeries {
            let rest = series.count - maxSeries
            parts.append(L.tr("외 \(rest)개", "and \(rest) more"))
        }
        if !hidden.isEmpty {
            parts.append(L.tr("숨긴 계열 \(hidden.count)개", "\(hidden.count) hidden"))
        }
        return parts.joined(separator: ", ")
    }

    private static func breakdownText(panel: PanelConfig, data: TimeSeriesData?,
                                      frames: FrameSet?) -> String? {
        let slices = PanelSeries.breakdown(metric: panel.effectiveMetric, panel: panel,
                                           frames: frames, data: data)
        let total = slices.reduce(0) { $0 + $1.value }
        guard !slices.isEmpty, total > 0 else { return nil }
        let ranked = slices.sorted { $0.value > $1.value }
        // A pie's message is a proportion, so the share is what gets read —
        // the absolute figure is what the table beside it is for.
        let named = ranked.prefix(maxSeries).map { slice in
            "\(slice.label) \(percent(slice.value / total))"
        }
        var parts = [L.tr("항목 \(slices.count)개", "\(slices.count) slices")]
        parts.append(contentsOf: named)
        if slices.count > maxSeries {
            parts.append(L.tr("외 \(slices.count - maxSeries)개",
                              "and \(slices.count - maxSeries) more"))
        }
        return parts.joined(separator: ", ")
    }

    private static func tableText(panel: PanelConfig, data: TimeSeriesData?,
                                  frames: FrameSet?) -> String? {
        let rows = PanelSeries.rows(panel: panel, frames: frames, data: data)
        guard !rows.isEmpty else { return nil }
        let named = rows.prefix(maxSeries).map { row in
            "\(row.model), \(TokenFormatter.formatTokens(row.tokens)), \(TokenFormatter.formatCost(row.cost))"
        }
        var parts = [L.tr("행 \(rows.count)개", "\(rows.count) rows")]
        parts.append(contentsOf: named)
        if rows.count > maxSeries {
            parts.append(L.tr("외 \(rows.count - maxSeries)행",
                              "and \(rows.count - maxSeries) more"))
        }
        return parts.joined(separator: ", ")
    }

    private static func timelineText(panel: PanelConfig, frames: FrameSet?) -> String? {
        guard let frames, !frames.frames.isEmpty else { return nil }
        let metric = panel.effectiveMetric
        let prepared = PanelPreset.prepared(frames, panel: panel, metric: metric)
        let spans = StateTimelineBuilder.spans(
            prepared,
            selection: panel.fieldSelection ?? PanelPreset.selection(for: metric),
            thresholds: panel.options.thresholds
        )
        guard !spans.isEmpty else { return nil }
        let rows = Set(spans.map(\.series)).count
        // The last span of each row is the state the thing is in NOW, which is
        // the question a state timeline is usually being asked.
        let latest = spans
            .sorted { $0.end > $1.end }
            .prefix(maxSeries)
            .map { span in
                L.tr("\(span.series), 현재 \(span.label)",
                     "\(span.series), currently \(span.label)")
            }
        var parts = [L.tr("행 \(rows)개, 구간 \(spans.count)개",
                          "\(rows) rows, \(spans.count) spans")]
        parts.append(contentsOf: latest)
        return parts.joined(separator: ", ")
    }

    // MARK: - Shared

    private static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        return value >= 10 || value == value.rounded()
            ? "\(Int(value.rounded()))%"
            : String(format: "%.1f%%", value)
    }
}
