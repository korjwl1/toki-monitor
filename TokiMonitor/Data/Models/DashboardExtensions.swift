import Foundation

// MARK: - Row Panel Type Extension

extension PanelType {
    /// The row type is a special collapsible section header
    static var row: PanelType { .rowPanel }
}

// Add row panel to PanelType
extension PanelType {
    // Row panel is handled via the existing enum — we add a new case
}

// MARK: - Annotation Model

struct DashboardAnnotation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var dashboardUID: String
    var timestamp: Date
    var text: String
    var tags: [String] = []
    var colorHex: String = "#FF6600"

    var color: String { colorHex }
}

// MARK: - Alert Rule Model

enum AlertCondition: String, Codable, CaseIterable, Equatable {
    case above
    case below
    case outsideRange

    var displayName: String {
        switch self {
        case .above: L.tr("초과", "Above")
        case .below: L.tr("미만", "Below")
        case .outsideRange: L.tr("범위 밖", "Outside Range")
        }
    }
}

enum AlertState: String, Codable, CaseIterable, Equatable {
    case ok
    case alerting
    case noData

    var displayName: String {
        switch self {
        case .ok: "OK"
        case .alerting: L.tr("경고 중", "Alerting")
        case .noData: L.tr("데이터 없음", "No Data")
        }
    }

    var iconName: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .alerting: "exclamationmark.triangle.fill"
        case .noData: "questionmark.circle"
        }
    }
}

struct AlertRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var panelID: UUID
    var name: String
    var condition: AlertCondition
    var threshold: Double
    var thresholdUpper: Double?  // for outsideRange
    var evaluateEvery: TimeInterval = 60
    var forDuration: TimeInterval = 300
    var state: AlertState = .noData
    var enabled: Bool = true
    var notifyViaSystem: Bool = true
    var lastEvaluated: Date?
    var lastTriggered: Date?
}

// MARK: - Dashboard Version Model

struct DashboardVersion: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var dashboardUID: String
    var version: Int
    var timestamp: Date = Date()
    var config: DashboardConfig
    var message: String = ""

    static func == (lhs: DashboardVersion, rhs: DashboardVersion) -> Bool {
        lhs.id == rhs.id && lhs.version == rhs.version
    }
}

// MARK: - Data Link Model

struct DataLink: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var url: String  // URL template with ${variable} interpolation
    var targetDashboardUID: String?
    var openInExplore: Bool = false
}

// MARK: - Playlist Model

struct DashboardPlaylist: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var dashboardUIDs: [String] = []
    var interval: TimeInterval = 30  // seconds per dashboard
}

// MARK: - Explore Query History

struct ExploreQueryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var query: String
    var timestamp: Date = Date()
}
