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
                        ForEach(Self.bands(scale: scale, options: panel.options)) { band in
                            // Full opacity. The band colours are chosen to
                            // clear 4.5:1 against the panel; drawing them at
                            // 0.65 threw that away and left a scale nobody
                            // could have measured.
                            GaugeArc(from: band.start, to: band.end, lineWidth: stroke * 0.34)
                                .stroke(band.color,
                                        style: StrokeStyle(lineWidth: stroke * 0.34, lineCap: .butt))
                                .padding(bandInset)
                        }
                    }

                    // Value
                    if let fraction = scale.fraction {
                        GaugeArc(from: 0, to: fraction, lineWidth: stroke)
                            .stroke(Self.valueColor(value, options: panel.options, scale: scale),
                                    style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    }

                    VStack(spacing: 2) {
                        Text(stat.value)
                            .font(.system(size: min(max(diameter * 0.2, 12), 32),
                                          weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                        // The band, in words. The arc's colour is otherwise the
                        // whole message, and colour must never carry meaning
                        // alone (계약 R6).
                        if let band = Self.bandLabel(value, options: panel.options,
                                                     scale: scale) {
                            Text(band)
                                .font(.system(size: DS.fontTiny, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(0.72))
                                .lineLimit(1)
                        }
                    }
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
        .accessibilityValue(Self.spokenValue(panel: panel, data: data, frames: frames))
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
        // Only absolute steps describe a range. A percentage step is measured
        // AGAINST the scale, so letting one set it would make a gauge whose
        // top is always 100 and whose thresholds always land in the same place.
        let thresholdTop = options.thresholdMode == .absolute
            ? options.thresholds.map(\.value).max()
            : nil
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

    /// One arc per band, starting with the BASE — the region below the lowest
    /// step, which had no colour of its own before and so said nothing about a
    /// value sitting in it (FR-026).
    ///
    /// Each band runs from its step to the next one, or to the end of the
    /// scale. Steps outside the scale are clamped rather than dropped, so a
    /// threshold above the maximum still colours the top of the dial instead of
    /// vanishing. In percentage mode the steps are placed on the scale first —
    /// 80 means 80% of the span, not 80 tokens.
    static func bands(scale: Scale, options: PanelDisplayOptions) -> [Band] {
        let span = scale.max - scale.min
        guard span > 0 else { return [] }
        let placed = Thresholds.placed(options.thresholds, mode: options.thresholdMode,
                                       scale: scale.min...scale.max)
        guard !placed.isEmpty else { return [] }

        func fraction(_ v: Double) -> Double {
            Swift.min(Swift.max((v - scale.min) / span, 0), 1)
        }

        var out: [Band] = []
        let base = Band(id: 0, start: 0, end: fraction(placed[0].at),
                        color: DS.threshold(options.thresholdBase))
        if base.end > base.start { out.append(base) }
        for (index, entry) in placed.enumerated() {
            let upper = index + 1 < placed.count ? placed[index + 1].at : scale.max
            let start = fraction(entry.at)
            let end = fraction(upper)
            guard end > start else { continue }
            out.append(Band(id: index + 1, start: start, end: end,
                            color: DS.threshold(entry.step.color)))
        }
        return out
    }

    /// The colour of the value arc: the highest threshold the value has
    /// reached, the base colour below all of them, or the accent colour when
    /// the panel has no thresholds at all.
    static func valueColor(_ value: Double?, options: PanelDisplayOptions,
                           scale: Scale? = nil) -> Color {
        guard options.showThresholdMarkers, value != nil,
              !options.thresholds.isEmpty else { return .accentColor }
        let range = scale.map { $0.min...$0.max }
        return DS.threshold(Thresholds.color(
            for: value, base: options.thresholdBase, steps: options.thresholds,
            mode: options.thresholdMode, scale: range
        ))
    }

    /// What band the value is in, in words. Colour is never the only carrier of
    /// meaning (계약 R6), and on a dial there is nothing else to carry it — the
    /// arc's colour is the whole message otherwise.
    static func bandLabel(_ value: Double?, options: PanelDisplayOptions,
                          scale: Scale) -> String? {
        guard options.showThresholdMarkers else { return nil }
        return Thresholds.label(for: value, steps: options.thresholds,
                                mode: options.thresholdMode,
                                scale: scale.min...scale.max)
    }

    /// What VoiceOver reads: the number, the ends of the scale, and the band —
    /// the same three things the sighted reader gets, none of them carried by
    /// colour.
    static func spokenValue(panel: PanelConfig, data: TimeSeriesData?,
                            frames: FrameSet?) -> String {
        let stat = StatPanelView.statValue(panel: panel, data: data, frames: frames)
        let value = StatPanelView.numericValue(panel: panel, data: data, frames: frames)
        let scale = Self.scale(for: value, options: panel.options)
        let low = label(scale.min, panel: panel)
        let high = label(scale.max, panel: panel)
        let range = L.tr("\(stat.value), \(low)에서 \(high) 사이",
                         "\(stat.value), on a scale from \(low) to \(high)")
        guard let band = bandLabel(value, options: panel.options, scale: scale) else {
            return range
        }
        return L.tr("\(range), 임계값 \(band)", "\(range), threshold \(band)")
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
