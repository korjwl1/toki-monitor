import SwiftUI

/// Stat panel render.
///
/// Moved here verbatim from `CustomDashboardView.statContent` so that a panel
/// type has exactly one render implementation in the app (contract R2). What
/// this file used to contain never rendered — it read `viewModel.totalTokens`
/// and friends directly and was never instantiated.
///
/// Field-driven when frames are available, with the legacy extractor as a
/// fallback for sources that do not produce them yet.
struct StatPanelView: View {
    let panel: PanelConfig
    let data: TimeSeriesData?
    let frames: FrameSet?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let stat = Self.statValue(panel: panel, data: data, frames: frames)
        let number = Self.numericValue(panel: panel, data: data, frames: frames)
        let band = Self.band(panel: panel, value: number)
        let mapped = Self.mappedColor(panel: panel, value: number)
        VStack(alignment: .leading, spacing: 4) {
            Text(stat.value)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(Self.valueStyle(panel: panel, band: band, mapped: mapped))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                // The digits roll to the new number. Under Reduce Motion the
                // number simply changes (FR-064).
                .animation(Motion.data(reduceMotion), value: stat.value)
            // Which band, in words. A tinted number is a claim about the value
            // and colour must never be the only thing making it (계약 R6) —
            // this is what a reader who cannot separate the hues, and what
            // VoiceOver, get instead.
            if let band {
                Text(band.label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.72))
            }
            if let subtitle = stat.subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.backgroundTint(panel: panel, band: band, mapped: mapped))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(panel.title)
        .accessibilityValue(band.map {
            L.tr("\(stat.value), 임계값 \($0.label)", "\(stat.value), threshold \($0.label)")
        } ?? stat.value)
    }

    // MARK: - Thresholds

    /// The band this card's number is in, or nil when the panel has no
    /// thresholds to place it against.
    ///
    /// Absolute only. A percentage step needs a scale to be a percentage OF,
    /// and a stat card has none — so `Thresholds` returns nothing rather than
    /// reading 80% as 80, and the editor does not offer the mode here (계약 R1).
    static func band(panel: PanelConfig, value: Double?)
        -> (color: ThresholdColor, label: String)? {
        guard panel.options.showThresholdMarkers, value != nil,
              !panel.options.thresholds.isEmpty,
              let label = Thresholds.label(for: value, steps: panel.options.thresholds,
                                           mode: panel.options.thresholdMode)
        else { return nil }
        let color = Thresholds.color(for: value, base: panel.options.thresholdBase,
                                     steps: panel.options.thresholds,
                                     mode: panel.options.thresholdMode)
        return (color, label)
    }

    /// The number's own colour under `.value`, and the ordinary text colour
    /// otherwise — under `.background` the tint carries the band and the digits
    /// stay maximally legible on it.
    static func valueStyle(panel: PanelConfig,
                           band: (color: ThresholdColor, label: String)?,
                           mapped: ThresholdColor? = nil) -> Color {
        guard panel.options.colorMode == .value else { return Color.primary }
        if let mapped { return DS.threshold(mapped) }
        guard let band else { return Color.primary }
        return DS.threshold(band.color)
    }

    /// A wash of the band's colour behind the card under `.background`.
    ///
    /// A wash rather than a fill: the token is chosen to clear 4.5:1 against
    /// the panel, and painting the card with it at full strength would put the
    /// value text on a ground nothing was measured against.
    @ViewBuilder
    static func backgroundTint(panel: PanelConfig,
                               band: (color: ThresholdColor, label: String)?,
                               mapped: ThresholdColor? = nil) -> some View {
        if let token = mapped ?? band?.color, panel.options.colorMode == .background {
            DS.threshold(token)
                .opacity(0.14)
                .clipShape(RoundedRectangle(cornerRadius: DS.btnRadius, style: .continuous))
        }
    }

    /// What this card shows, after the panel's value mappings.
    ///
    /// Mappings come first and the unit second (FR-025): the values a mapping
    /// is for are the ones the formatter renders wrongly — `0` printed as "0"
    /// when it means "nothing yet", an absent sample printed as `-` when the
    /// reader wanted "not measured".
    static func statValue(panel: PanelConfig, data: TimeSeriesData?,
                          frames: FrameSet?) -> PanelDataExtractor.StatValue {
        let base = unmappedStatValue(panel: panel, data: data, frames: frames)
        let mappings = panel.options.valueMappings
        guard !mappings.isEmpty else { return base }
        // `topModel` names a series rather than reducing a column, so its
        // "value" is a string and the numeric rules must not see it — a
        // no-value rule would otherwise catch every top-model card.
        if panel.effectiveMetric == .topModel {
            guard let mapped = ValueMappings.result(forText: base.value, mappings: mappings)
            else { return base }
            return PanelDataExtractor.StatValue(value: mapped.text, subtitle: base.subtitle)
        }
        let number = numericValue(panel: panel, data: data, frames: frames)
        guard let mapped = ValueMappings.result(for: number, mappings: mappings)
        else { return base }
        return PanelDataExtractor.StatValue(value: mapped.text, subtitle: base.subtitle)
    }

    /// The colour a mapping asked for, when one caught this card's value.
    ///
    /// It wins over the threshold band: a rule written for exactly this value
    /// is a more specific statement than the band it happens to fall in.
    static func mappedColor(panel: PanelConfig, value: Double?) -> ThresholdColor? {
        ValueMappings.result(for: value, mappings: panel.options.valueMappings)?.color
    }

    /// Resolve a stat card's number. Frames first; the legacy extractor only
    /// when a datasource has not been migrated.
    ///
    /// The value no longer comes from a switch on the metric: the preset says
    /// which FIELD to read and how to reduce it, so a panel pointed at a column
    /// no enum case knows about renders through this same path.
    ///
    /// `GaugePanelView` reads the same number — the gauge is a second
    /// presentation of one value, not a second way of computing it.
    private static func unmappedStatValue(panel: PanelConfig, data: TimeSeriesData?,
                                          frames: FrameSet?) -> PanelDataExtractor.StatValue {
        let metric = panel.effectiveMetric
        guard let frames, !frames.frames.isEmpty else {
            return PanelDataExtractor.statValue(for: metric, data: data)
        }
        // `topModel` names a series rather than reducing a column.
        if metric == .topModel {
            let name = FrameReader.topSeries(
                frames, selection: PanelPreset.selection(for: metric), labelKey: "model"
            )
            return PanelDataExtractor.StatValue(value: name ?? "-", subtitle: nil)
        }
        let prepared = PanelPreset.prepared(frames, panel: panel, metric: metric)
        // The panel's own selection wins; the preset is the starting point a
        // panel keeps until someone changes it.
        let selection = panel.fieldSelection ?? PanelPreset.selection(for: metric)
        guard let value = FrameReader.singleValue(prepared, selection: selection) else {
            // Absent stays "-", never 0 — see FrameReader.singleValue.
            return PanelDataExtractor.StatValue(value: "-", subtitle: nil)
        }
        // The panel's own unit and decimals, then its defaults, then any
        // override matching the field actually read — resolved in one place,
        // shared with every other panel type.
        let field = prepared.frames.compactMap { selection.resolve(in: $0) }.first
        let resolved = panel.displayConfig(for: field)
        if !resolved.isEmpty {
            return PanelDataExtractor.StatValue(
                value: FieldFormatter.format(value, config: resolved), subtitle: nil
            )
        }
        return PanelDataExtractor.StatValue(
            value: Self.format(value, metric: metric),
            subtitle: Self.costSubtitle(for: metric)
        )
    }

    /// The unit and decimals set on the panel itself, or nil when it said
    /// nothing and the metric's own default formatting should stand.
    ///
    /// Kept for callers that have no field to resolve against — the gauge's
    /// scale labels, which are ends of an axis rather than values of a column.
    static func panelDisplayConfig(_ panel: PanelConfig) -> FieldDisplayConfig? {
        let resolved = panel.displayConfig(for: nil)
        return resolved.isEmpty ? nil : resolved
    }

    /// The number behind `statValue`, unformatted.
    ///
    /// `GaugePanelView` needs it to place the value on a scale. Returns nil
    /// where there is no number to place — including `topModel`, which names a
    /// series rather than reducing a column.
    static func numericValue(panel: PanelConfig, data: TimeSeriesData?,
                             frames: FrameSet?) -> Double? {
        let metric = panel.effectiveMetric
        guard metric != .topModel else { return nil }
        guard let frames, !frames.frames.isEmpty else {
            return PanelDataExtractor.statNumber(for: metric, data: data)
        }
        let prepared = PanelPreset.prepared(frames, panel: panel, metric: metric)
        let selection = panel.fieldSelection ?? PanelPreset.selection(for: metric)
        return FrameReader.singleValue(prepared, selection: selection)
    }

    /// A cost figure here is "valued at the prices we currently know", not
    /// "what was billed at the time" — nothing in the pipeline stores a price
    /// history, so a chart of last month's spend moves when a price does.
    /// That is the useful reading on a flat-rate plan ("what would this cost
    /// me on the API today?"), but only if it says so.
    static func costSubtitle(for metric: PanelMetric) -> String? {
        switch metric {
        case .totalCost, .costByModel:
            return L.tr("현재 가격 기준", "at current prices")
        default:
            return nil
        }
    }

    static func format(_ value: Double, metric: PanelMetric) -> String {
        switch metric {
        case .totalCost, .costByModel:
            return TokenFormatter.formatCost(value)
        case .apiCalls, .eventsByModel:
            return String(Int(value))
        case .cacheHitRate:
            return String(format: "%.1f%%", value * 100)
        default:
            return TokenFormatter.formatTokens(UInt64(max(0, value)))
        }
    }
}
