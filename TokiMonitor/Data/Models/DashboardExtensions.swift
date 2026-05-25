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

// MARK: - Explore Query History

struct ExploreQueryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var query: String
    var timestamp: Date = Date()
}
