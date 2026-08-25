import SwiftUI

/// Gauge panel render.
///
/// This used to be `Text(value)` at 24pt — a stat card with a different name in
/// the picker. A gauge earns its place by answering a question a number cannot:
/// how far along a known scale this value sits. That needs the two ends of the
/// scale and, when the panel has thresholds, the bands they cut it into
/// (contract R4).
///
/// The number itself comes from `StatPanelView` — the gauge is a second
/// presentation of one value, not a second way of computing it.
struct GaugePanelView: View {
    let panel: PanelConfig
    let data: TimeSeriesData?
    let frames: FrameSet?

    /// 270° of dial, opening at the bottom. A full circle gives the eye no
    /// anchor for where the scale starts, and a half circle wastes the height
    /// a dashboard panel is usually short of.
    private static let sweep: Double = 270
    private static let startAngle: Double = 135

    var body: some View {
        let stat = StatPanelView.statValue(panel: panel, data: data, frames: frames)
        let value = StatPanelView.numericValue(panel: panel, data: data, frames: frames)
        let scale = Self.scale(for: value, options: panel.options)

        GeometryReader { geo in
            // The scale labels sit under the dial, so the dial gets what is
            // left. Sizing off the width alone drew a dial taller than the
            // panel and cut the labels off the bottom.
            let labelRow = DS.fontTiny + DS.xs * 2
            let diameter = max(40, min(geo.size.width, geo.size.height - labelRow))
            let stroke = min(max(diameter * 0.1, 5), 16)
            let bandInset = stroke * 0.95

            VStack(spacing: DS.xs) {
                ZStack {
                    // Track
                    GaugeArc(from: 0, to: 1, lineWidth: stroke)
                        .stroke(Color.primary.opacity(0.12),
                                style: StrokeStyle(lineWidth: stroke, lineCap: .round))

                    // Threshold bands: a thin scale INSIDE the track, not under
                    // the value arc. Drawn under it they were invisible for
                    // exactly the values that matter — the high ones, where the
                    // arc covers the whole dial.
                    if panel.options.showThresholdMarkers {
                        ForEach(Self.bands(scale: scale, thresholds: panel.options.thresholds)) { band in
                            GaugeArc(from: band.start, to: band.end, lineWidth: stroke * 0.34)
                                .stroke(band.color.opacity(0.65),
                                        style: StrokeStyle(lineWidth: stroke * 0.34, lineCap: .butt))
                                .padding(bandInset)
                        }
                    }

                    // Value
                    if let fraction = scale.fraction {
                        GaugeArc(from: 0, to: fraction, lineWidth: stroke)
                            .stroke(Self.valueColor(value, options: panel.options),
                                    style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    }

                    Text(stat.value)
                        .font(.system(size: min(max(diameter * 0.2, 12), 32),
                                      weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .padding(.horizontal, stroke * 2.2)
                }
                .frame(width: diameter, height: diameter)

                // The ends of the scale. Without them the arc is decoration:
                // a needle two-thirds of the way round says nothing until the
                // reader knows two-thirds of what.
                HStack {
                    Text(Self.label(scale.min, panel: panel))
                    Spacer(minLength: DS.sm)
                    Text(Self.label(scale.max, panel: panel))
                }
                .font(.system(size: DS.fontTiny, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(width: diameter)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(panel.title)
        .accessibilityValue(
            L.tr("\(stat.value), \(Self.label(scale.min, panel: panel))에서 \(Self.label(scale.max, panel: panel)) 사이",
                 "\(stat.value), on a scale from \(Self.label(scale.min, panel: panel)) to \(Self.label(scale.max, panel: panel))")
        )
    }

    // MARK: - Scale

    struct Scale: Equatable {
        let min: Double
        let max: Double
        /// Where the value sits, 0...1. Nil when there is no number to place.
        let fraction: Double?
    }

    /// The two ends of the dial.
    ///
    /// The panel's own min/max win. Failing that the thresholds describe the
    /// range someone already cared about, and failing that the value picks a
    /// round ceiling above itself — never exactly the value, which would pin
    /// every gauge at full and say nothing.
    static func scale(for value: Double?, options: PanelDisplayOptions) -> Scale {
        let lower = options.gaugeMin ?? 0
        let thresholdTop = options.thresholds.map(\.value).max()
        let upper: Double
        if let explicit = options.gaugeMax {
            upper = explicit
        } else if let top = thresholdTop, top > lower {
            upper = top
        } else if let value, value > lower {
            upper = niceCeiling(value)
        } else {
            upper = lower + 100
        }
        let span = upper - lower
        guard let value, span > 0 else { return Scale(min: lower, max: upper, fraction: nil) }
        let fraction = (value - lower) / span
        return Scale(min: lower, max: upper, fraction: Swift.min(Swift.max(fraction, 0), 1))
    }

    /// The next 1/2/5 × 10ⁿ at or above `value`. Round ends are what make a
    /// dial readable without reading its labels.
    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let exponent = floor(log10(value))
        let magnitude = pow(10, exponent)
        let normalized = value / magnitude
        let step: Double = normalized <= 1 ? 1 : (normalized <= 2 ? 2 : (normalized <= 5 ? 5 : 10))
        return step * magnitude
    }

    // MARK: - Bands

    struct Band: Identifiable, Equatable {
        let id: Int
        let start: Double
        let end: Double
        let color: Color
    }

    /// One arc per threshold step, from that step's value to the next one's
    /// (or to the end of the scale). Steps outside the scale are clamped
    /// rather than dropped, so a threshold above the maximum still colours the
    /// top of the dial instead of vanishing.
    static func bands(scale: Scale, thresholds: [ThresholdStep]) -> [Band] {
        let span = scale.max - scale.min
        guard span > 0, !thresholds.isEmpty else { return [] }
        let sorted = thresholds.sorted { $0.value < $1.value }
        return sorted.enumerated().compactMap { index, step in
            let upper = index + 1 < sorted.count ? sorted[index + 1].value : scale.max
            let start = Swift.min(Swift.max((step.value - scale.min) / span, 0), 1)
            let end = Swift.min(Swift.max((upper - scale.min) / span, 0), 1)
            guard end > start else { return nil }
            return Band(id: index, start: start, end: end,
                        color: ProviderInfo.colorFromName(step.color))
        }
    }

    /// The colour of the value arc: the highest threshold the value has
    /// reached, or the accent colour when the panel has no thresholds.
    static func valueColor(_ value: Double?, options: PanelDisplayOptions) -> Color {
        guard options.showThresholdMarkers, let value else { return .accentColor }
        let reached = options.thresholds
            .filter { value >= $0.value }
            .max { $0.value < $1.value }
        guard let reached else { return .accentColor }
        return ProviderInfo.colorFromName(reached.color)
    }

    // MARK: - Labels

    /// Scale ends read in the panel's own unit, so a dial marked 0…1M is not
    /// sitting under a value marked "1.2M" in a different notation.
    static func label(_ value: Double, panel: PanelConfig) -> String {
        if let display = StatPanelView.panelDisplayConfig(panel) {
            return FieldFormatter.format(value, config: display)
        }
        return StatPanelView.format(value, metric: panel.effectiveMetric)
    }
}

/// A slice of the dial, expressed as two fractions of its 270° sweep.
private struct GaugeArc: Shape {
    let from: Double
    let to: Double
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = (min(rect.width, rect.height) - lineWidth) / 2
        guard radius > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(GaugePanelView.angle(for: from)),
            endAngle: .degrees(GaugePanelView.angle(for: to)),
            clockwise: false
        )
        return path
    }
}

extension GaugePanelView {
    /// Fraction of the sweep → angle in SwiftUI's coordinate space, where 0°
    /// points right and degrees increase clockwise.
    static func angle(for fraction: Double) -> Double {
        startAngle + sweep * Swift.min(Swift.max(fraction, 0), 1)
    }
}
