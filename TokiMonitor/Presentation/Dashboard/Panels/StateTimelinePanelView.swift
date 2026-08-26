import SwiftUI
import Charts

/// Spans on a row per series.
///
/// The other panels answer "how much, over time"; this one answers "what state
/// was this in, and for how long". A rate-limit window, a session, a period
/// spent above 80% — all of them are intervals, and drawing an interval as a
/// line means reading a step function and guessing where it changed.
struct StateTimelinePanelView: View {
    let panel: PanelConfig
    let frames: FrameSet?
    let dateFormat: Date.FormatStyle

    @State private var hovered: TimelineSpan?

    private var spans: [TimelineSpan] {
        guard let frames, !frames.frames.isEmpty else { return [] }
        let metric = panel.effectiveMetric
        let prepared = PanelPreset.prepared(frames, panel: panel, metric: metric)
        let panel = panel
        return StateTimelineBuilder.spans(
            prepared,
            selection: panel.fieldSelection ?? PanelPreset.selection(for: metric),
            thresholds: panel.options.thresholds,
            // A row's name is the one thing a field override can change here:
            // the colour comes from the thresholds and the values are band
            // names rather than numbers (계약 R1).
            name: panel.hasFieldConfig
                ? { frame, field in panel.seriesName(frame.displayName, field: field) }
                : nil
        )
    }

    /// Rows in a stable order, so a refresh does not reshuffle the chart.
    private var seriesOrder: [String] {
        var seen: [String] = []
        for span in spans where !seen.contains(span.series) { seen.append(span.series) }
        return seen
    }

    var body: some View {
        let spans = spans
        if spans.isEmpty {
            Text("-")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(spans) { span in
                BarMark(
                    xStart: .value(L.dash.axisTime, span.start),
                    xEnd: .value(L.dash.axisTime, span.end),
                    y: .value("", span.series)
                )
                .foregroundStyle(by: .value(L.tr("상태", "State"), span.label))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale(range: palette(for: spans))
            .chartYAxis {
                AxisMarks(preset: .aligned, position: .leading) { _ in
                    AxisValueLabel().font(.system(size: 9))
                }
            }
            .chartXAxis {
                AxisMarks(preset: .aligned, values: .automatic) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: dateFormat).font(.system(size: 9))
                }
            }
            .chartLegend(position: .bottom, spacing: 6)
        }
    }

    /// Threshold colours when the panel has them, the shared model palette
    /// otherwise. Ordered to match the state names the chart derived, so a
    /// state keeps its colour between refreshes.
    private func palette(for spans: [TimelineSpan]) -> [Color] {
        var states: [String] = []
        var valueForState: [String: Double] = [:]
        for span in spans where !states.contains(span.label) {
            states.append(span.label)
            if let v = span.value { valueForState[span.label] = v }
        }
        return states.map { state in
            if let v = valueForState[state],
               let token = StateTimelineBuilder.color(for: v, thresholds: panel.options.thresholds) {
                // One measured palette for every threshold in the app, so a
                // band reads the same here as it does on a gauge.
                return DS.threshold(token)
            }
            return Self.defaultPalette[abs(state.hashValue) % Self.defaultPalette.count]
        }
    }

    private static let defaultPalette: [Color] = [
        .blue, .green, .orange, .purple, .red, .teal, .indigo, .mint,
    ]
}
