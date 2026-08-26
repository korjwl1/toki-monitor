import AppKit
import Foundation
import UniformTypeIdentifiers

/// The file-picker half of `DashboardConfigStore`.
///
/// It lives in Presentation because `NSSavePanel` and `NSOpenPanel` are
/// AppKit, and the constitution has Domain depending on neither AppKit nor
/// SwiftUI (principle IV, and §5 of the app's own constitution). The store
/// itself decides what a dashboard is and how it round-trips; asking the user
/// where to put a file is a presentation concern that happens to have been
/// written next to it.
///
/// Behaviour is unchanged — this is a move.
@MainActor
extension DashboardConfigStore {
    // MARK: - JSON File Import/Export

    /// Write a dashboard to a file the user picks.
    ///
    /// The save panel carries the disclosure: the export holds no results and
    /// no usage figures, but query strings are the user's own words and often
    /// name their projects and models (계약 C3).
    @discardableResult
    func exportToFile(_ config: DashboardConfig) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(config.title).json"
        panel.title = L.tr("대시보드 내보내기", "Export Dashboard")
        panel.message = DashboardExchange.exportDisclosure

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            let data = try config.exportJSON()
            try data.write(to: url)
            lastExportError = nil
            return true
        } catch {
            // Writing nothing and saying nothing is how a user comes back next
            // week to a file that was never there.
            lastExportError = L.tr(
                "'\(url.lastPathComponent)'에 내보내지 못했습니다: \(error.localizedDescription)",
                "Could not export to '\(url.lastPathComponent)': \(error.localizedDescription)"
            )
            return false
        }
    }

    /// Ask for a file and return its bytes. Decoding is the caller's, because
    /// the caller is the one that shows the reader what is in it before adding
    /// it (계약 C4).
    ///
    /// `nil` with `lastImportError` set means the file could not be read; `nil`
    /// with it cleared means the user pressed Cancel. Those are different, and
    /// a bare `nil` could not tell them apart.
    func chooseImportFile() -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = L.tr("대시보드 가져오기", "Import Dashboard")

        lastImportError = nil
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            return try Data(contentsOf: url)
        } catch {
            lastImportError = L.tr(
                "\(url.lastPathComponent): \(error.localizedDescription)",
                "\(url.lastPathComponent): \(error.localizedDescription)"
            )
            return nil
        }
    }

    // MARK: - Default Layout (24-column grid)

    /// Default dashboard with 24-column grid layout (v4 schema).
    static var defaultConfig: DashboardConfig {
        let config = DashboardConfig(
            title: "Default",
            time: TimeConfig(from: "now-24h", to: "now"),
            refresh: .off,
            panels: [
                // Row 0: 4 stat cards (6 cols each)
                PanelConfig(
                    title: L.dash.totalTokens,
                    panelType: .stat,
                    metric: .totalTokens,
                    gridPosition: GridPosition(column: 0, row: 0, width: 6, height: 1),
                    targets: [PanelTarget(refId: "A", metric: .totalTokens)]
                ),
                PanelConfig(
                    title: L.dash.totalCost,
                    panelType: .stat,
                    metric: .totalCost,
                    gridPosition: GridPosition(column: 6, row: 0, width: 6, height: 1),
                    targets: [PanelTarget(refId: "A", metric: .totalCost)]
                ),
                PanelConfig(
                    title: L.dash.apiCalls,
                    panelType: .stat,
                    metric: .apiCalls,
                    gridPosition: GridPosition(column: 12, row: 0, width: 6, height: 1),
                    targets: [PanelTarget(refId: "A", metric: .apiCalls)]
                ),
                PanelConfig(
                    title: L.dash.topModel,
                    panelType: .stat,
                    metric: .topModel,
                    gridPosition: GridPosition(column: 18, row: 0, width: 6, height: 1),
                    targets: [PanelTarget(refId: "A", metric: .topModel)]
                ),
                // Row 1-3: token trend (full width)
                PanelConfig(
                    title: L.dash.tokenTrend,
                    panelType: .timeSeries,
                    metric: .tokensByModel,
                    gridPosition: GridPosition(column: 0, row: 1, width: 24, height: 3),
                    targets: [PanelTarget(refId: "A", metric: .tokensByModel)]
                ),
                // Row 4-6: project distribution pie (left half) + API trend (right half)
                PanelConfig(
                    title: L.tr("프로젝트별 사용량", "Usage by Project"),
                    panelType: .pieChart,
                    metric: .tokensByProject,
                    gridPosition: GridPosition(column: 0, row: 4, width: 12, height: 3),
                    targets: [PanelTarget(refId: "A", metric: .tokensByProject)]
                ),
                PanelConfig(
                    title: L.dash.apiTrend,
                    panelType: .barChart,
                    metric: .eventsByModel,
                    gridPosition: GridPosition(column: 12, row: 4, width: 12, height: 3),
                    targets: [PanelTarget(refId: "A", metric: .eventsByModel)]
                ),
            ],
            templating: DashboardConfig.defaultTemplating
        )
        // Run through the migration chain so plugin/queries envelopes and
        // layouts are populated consistently with persisted dashboards.
        return DashboardMigrator.migrate(config)
    }
}
