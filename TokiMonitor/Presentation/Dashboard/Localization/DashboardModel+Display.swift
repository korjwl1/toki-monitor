import Foundation

// View-bound presentation hooks for Data layer enums.
//
// Was previously embedded in `Data/Models/DashboardConfig.swift`, where
// `displayName` / `icon` getters reached into the Domain `Localization`
// helper. That's a layer violation — Data should not depend on Domain.
// Moving the SF-Symbol / localized-text vocabulary to a Presentation
// extension keeps Data declarative and lets the strings live next to the
// views that consume them.

extension PanelDisplayOptions.ColorMode {
    var displayName: String {
        switch self {
        case .value:      L.tr("값", "Value")
        case .background: L.tr("배경", "Background")
        case .none:       L.tr("없음", "None")
        }
    }
}

extension PanelDisplayOptions.GraphMode {
    var displayName: String {
        switch self {
        case .none: L.tr("없음", "None")
        case .area: L.tr("영역", "Area")
        case .line: L.tr("선", "Line")
        }
    }
}

extension PanelDisplayOptions.LegendPosition {
    var displayName: String {
        switch self {
        case .bottom: L.tr("아래", "Bottom")
        case .right:  L.tr("오른쪽", "Right")
        case .hidden: L.tr("숨김", "Hidden")
        }
    }
}

extension PanelDisplayOptions.TooltipMode {
    var displayName: String {
        switch self {
        case .single: L.tr("단일", "Single")
        case .all:    L.tr("전체", "All")
        case .hidden: L.tr("숨김", "Hidden")
        }
    }
}

extension RefreshInterval {
    var displayName: String {
        switch self {
        case .off: L.tr("끄기", "Off")
        case .fiveSeconds: "5s"
        case .tenSeconds: "10s"
        case .thirtySeconds: "30s"
        case .oneMinute: "1m"
        case .fiveMinutes: "5m"
        case .fifteenMinutes: "15m"
        case .thirtyMinutes: "30m"
        }
    }
}

extension TimeRangePreset {
    static var presets: [TimeRangePreset] { [
        TimeRangePreset(id: "5m", label: L.tr("최근 5분", "Last 5 minutes"), from: "now-5m"),
        TimeRangePreset(id: "15m", label: L.tr("최근 15분", "Last 15 minutes"), from: "now-15m"),
        TimeRangePreset(id: "30m", label: L.tr("최근 30분", "Last 30 minutes"), from: "now-30m"),
        TimeRangePreset(id: "1h", label: L.tr("최근 1시간", "Last 1 hour"), from: "now-1h"),
        TimeRangePreset(id: "3h", label: L.tr("최근 3시간", "Last 3 hours"), from: "now-3h"),
        TimeRangePreset(id: "6h", label: L.tr("최근 6시간", "Last 6 hours"), from: "now-6h"),
        TimeRangePreset(id: "12h", label: L.tr("최근 12시간", "Last 12 hours"), from: "now-12h"),
        TimeRangePreset(id: "24h", label: L.tr("최근 24시간", "Last 24 hours"), from: "now-24h"),
        TimeRangePreset(id: "2d", label: L.tr("최근 2일", "Last 2 days"), from: "now-2d"),
        TimeRangePreset(id: "7d", label: L.tr("최근 7일", "Last 7 days"), from: "now-7d"),
        TimeRangePreset(id: "14d", label: L.tr("최근 14일", "Last 14 days"), from: "now-14d"),
        TimeRangePreset(id: "30d", label: L.tr("최근 30일", "Last 30 days"), from: "now-30d"),
    ] }
}

extension PanelType {
    var displayName: String {
        switch self {
        case .stat: L.dash.statPanel
        case .timeSeries: L.dash.timeSeriesPanel
        case .barChart: L.dash.barChartPanel
        case .pieChart: L.tr("파이 차트", "Pie Chart")
        case .table: L.dash.tablePanel
        case .gauge: L.dash.gaugePanel
        case .stateTimeline: L.tr("상태 타임라인", "State Timeline")
        case .rowPanel: L.tr("행", "Row")
        case .unknown: L.tr("알 수 없는 종류", "Unknown type")
        }
    }

    var icon: String {
        switch self {
        case .stat: "number.square"
        case .timeSeries: "chart.xyaxis.line"
        case .barChart: "chart.bar"
        case .pieChart: "chart.pie"
        case .table: "tablecells"
        case .gauge: "gauge.open.with.lines.needle.33percent"
        case .stateTimeline: "chart.bar.doc.horizontal"
        case .rowPanel: "rectangle.split.1x2"
        case .unknown: "questionmark.square.dashed"
        }
    }
}

extension PanelMetric {
    var displayName: String {
        switch self {
        case .totalTokens: L.dash.metricTotalTokens
        case .totalCost: L.dash.metricTotalCost
        case .apiCalls: L.dash.metricApiCalls
        case .topModel: L.dash.metricTopModel
        case .tokensByModel: L.dash.metricTokensByModel
        case .costByModel: L.dash.metricCostByModel
        case .eventsByModel: L.dash.metricEventsByModel
        case .inputVsOutput: L.dash.metricInputVsOutput
        case .cacheHitRate: L.dash.metricCacheHitRate
        case .reasoningTokens: L.dash.metricReasoningTokens
        case .modelBreakdown: L.dash.metricModelBreakdown
        case .tokensByProject: L.tr("프로젝트별 토큰", "Tokens by Project")
        case .rateLimitWindows: L.tr("한도 윈도우", "Rate-limit Windows")
        }
    }

    var icon: String {
        switch self {
        case .totalTokens: "number"
        case .totalCost: "dollarsign.circle"
        case .apiCalls: "arrow.up.arrow.down"
        case .topModel: "star.fill"
        case .tokensByModel: "chart.xyaxis.line"
        case .costByModel: "chart.xyaxis.line"
        case .eventsByModel: "chart.bar"
        case .inputVsOutput: "arrow.left.arrow.right"
        case .cacheHitRate: "memorychip"
        case .reasoningTokens: "brain"
        case .modelBreakdown: "tablecells"
        case .tokensByProject: "chart.pie"
        case .rateLimitWindows: "chart.bar.doc.horizontal"
        }
    }
}

extension DashboardImportError {
    var errorDescription: String? {
        switch self {
        case .invalidJSON: L.tr("잘못된 JSON 형식입니다", "Invalid JSON format")
        case .incompatibleVersion: L.tr("호환되지 않는 대시보드 버전입니다", "Incompatible dashboard version")
        }
    }
}

/// Display name for a built-in datasource kind. Used by views that need
/// a human label without reaching into the plugin instance (whose
/// `displayName` field was the original layer-violating leak).
enum DatasourceKindDisplay {
    static func name(for kind: String) -> String {
        switch kind {
        case BuiltinDatasourceKind.localCLI:    return L.sync.local
        case BuiltinDatasourceKind.promQLProxy: return L.sync.server
        default:                                 return kind
        }
    }
}
