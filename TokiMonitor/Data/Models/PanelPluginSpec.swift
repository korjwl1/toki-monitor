import Foundation

// MARK: - Per-visualization typed plugin specs (Perses-style)
//
// `PanelPluginRef.spec` is a JSON-encoded blob. These typed structs are the
// shape that blob takes for each built-in panel plugin kind. Mirrors Perses'
// `TimeSeriesChart`, `StatChart`, `BarChart`, `PieChart`, `Table`, `Gauge`
// plugin spec definitions.
//
// During migration `panel.options` (the legacy unified `PanelDisplayOptions`)
// is projected onto these typed specs and stored in `panel.plugin.spec`.
// The renderer still drives off `panel.options`; typed specs exist so the
// on-disk JSON is Perses-shaped and so a future View pass can switch over
// to plugin-spec-driven rendering without changing storage again.

struct LegendOptions: Codable, Equatable, Sendable {
    var position: String  // "bottom" | "right" | "hidden"
    var show: Bool
}

struct TooltipOptions: Codable, Equatable, Sendable {
    var mode: String  // "single" | "all" | "hidden"
}

struct ThresholdSpec: Codable, Equatable, Sendable {
    var value: Double
    var color: String
}

// MARK: - TimeSeriesChart

struct TimeSeriesChartSpec: Codable, Equatable, Sendable {
    var legend: LegendOptions
    var tooltip: TooltipOptions
    var lineWidth: Double
    var fillOpacity: Double
    var unit: String?
    var decimals: Int?
    var thresholds: [ThresholdSpec]
}

// MARK: - StatChart

struct StatChartSpec: Codable, Equatable, Sendable {
    var colorMode: String   // "value" | "background" | "none"
    var graphMode: String   // "none" | "area" | "line"
    var unit: String?
    var decimals: Int?
    var thresholds: [ThresholdSpec]
}

// MARK: - BarChart

struct BarChartSpec: Codable, Equatable, Sendable {
    var legend: LegendOptions
    var tooltip: TooltipOptions
    var unit: String?
    var decimals: Int?
}

// MARK: - PieChart

struct PieChartSpec: Codable, Equatable, Sendable {
    var legend: LegendOptions
    var unit: String?
    var decimals: Int?
}

// MARK: - TableChart

struct TableChartSpec: Codable, Equatable, Sendable {
    var showHeader: Bool
    var unit: String?
    var decimals: Int?
}

// MARK: - GaugeChart

struct GaugeChartSpec: Codable, Equatable, Sendable {
    var showThresholdMarkers: Bool
    var unit: String?
    var decimals: Int?
    var thresholds: [ThresholdSpec]
}

// MARK: - Bridge from legacy PanelDisplayOptions

extension PanelDisplayOptions {

    private var legend: LegendOptions {
        LegendOptions(position: legendPosition.rawValue, show: showLegend)
    }

    private var tooltip: TooltipOptions {
        TooltipOptions(mode: tooltipMode.rawValue)
    }

    private var thresholdSpecs: [ThresholdSpec] {
        thresholds.map { ThresholdSpec(value: $0.value, color: $0.color) }
    }

    /// Encode this options bag into the typed spec for `kind`. Returns the
    /// JSON data ready to live inside `PanelPluginRef.spec`. `nil` if the
    /// kind has no associated typed spec (e.g. row).
    func encodedSpec(forPanelPluginKind kind: String) -> Data? {
        let encoder = JSONEncoder()
        switch kind {
        case BuiltinPanelPluginKind.timeSeriesChart:
            return try? encoder.encode(TimeSeriesChartSpec(
                legend: legend, tooltip: tooltip,
                lineWidth: lineWidth, fillOpacity: fillOpacity,
                unit: unit, decimals: decimals, thresholds: thresholdSpecs
            ))
        case BuiltinPanelPluginKind.statChart:
            return try? encoder.encode(StatChartSpec(
                colorMode: colorMode.rawValue,
                graphMode: graphMode.rawValue,
                unit: unit, decimals: decimals, thresholds: thresholdSpecs
            ))
        case BuiltinPanelPluginKind.barChart:
            return try? encoder.encode(BarChartSpec(
                legend: legend, tooltip: tooltip,
                unit: unit, decimals: decimals
            ))
        case BuiltinPanelPluginKind.pieChart:
            return try? encoder.encode(PieChartSpec(
                legend: legend, unit: unit, decimals: decimals
            ))
        case BuiltinPanelPluginKind.tableChart:
            return try? encoder.encode(TableChartSpec(
                showHeader: showHeader, unit: unit, decimals: decimals
            ))
        case BuiltinPanelPluginKind.gaugeChart:
            return try? encoder.encode(GaugeChartSpec(
                showThresholdMarkers: showThresholdMarkers,
                unit: unit, decimals: decimals, thresholds: thresholdSpecs
            ))
        default:
            return nil
        }
    }
}
