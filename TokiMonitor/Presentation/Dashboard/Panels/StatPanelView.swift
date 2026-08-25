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

    var body: some View {
        let stat = Self.statValue(panel: panel, data: data, frames: frames)
        VStack(alignment: .leading, spacing: 4) {
            Text(stat.value)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.5), value: stat.value)
            if let subtitle = stat.subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    static func statValue(panel: PanelConfig, data: TimeSeriesData?,
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
        let prepared = TransformationPipeline.apply(
            PanelPreset.transformations(for: metric), to: frames
        )
        // The panel's own selection wins; the preset is the starting point a
        // panel keeps until someone changes it.
        let selection = panel.fieldSelection ?? PanelPreset.selection(for: metric)
        guard let value = FrameReader.singleValue(prepared, selection: selection) else {
            // Absent stays "-", never 0 — see FrameReader.singleValue.
            return PanelDataExtractor.StatValue(value: "-", subtitle: nil)
        }
        // Formatting comes from the field's resolved config when the panel has
        // one, so a card can read "$" while its neighbour reads tokens.
        if let config = panel.fieldConfig,
           let field = prepared.frames.compactMap({ selection.resolve(in: $0) }).first {
            let resolved = config.resolve(for: field)
            if !resolved.isEmpty {
                return PanelDataExtractor.StatValue(
                    value: FieldFormatter.format(value, config: resolved), subtitle: nil
                )
            }
        }
        return PanelDataExtractor.StatValue(
            value: Self.format(value, metric: metric),
            subtitle: Self.costSubtitle(for: metric)
        )
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
