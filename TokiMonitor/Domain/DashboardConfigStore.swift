import Foundation
import AppKit

/// Persists dashboard configurations. Supports multiple dashboards,
/// JSON import/export, and schema migration.
@MainActor
final class DashboardConfigStore {
    private static let userDefaultsKey = "dashboardConfig"
    private static let dashboardListKey = "dashboardList"
    private static let activeDashboardKey = "activeDashboardUID"

    /// One-shot cleanup of UserDefaults keys from features that have been
    /// removed (alerts, playlists). Lazily fires the first time this
    /// type is touched per process. Skips the work if the keys are
    /// already gone, so the cost is one Defaults read per app launch.
    private static let purgeRemovedFeatureKeysOnce: Void = {
        let removed = ["dashboardAlertRules", "dashboardPlaylists"]
        for key in removed where UserDefaults.standard.object(forKey: key) != nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }()

    init() {
        // Touch the static so the cleanup runs once per app launch.
        _ = Self.purgeRemovedFeatureKeysOnce
    }

    // MARK: - Single Dashboard (backward compatible)

    func load() -> DashboardConfig {
        // Prefer the single-dashboard key (legacy / "active" surface).
        if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let stored = try? JSONDecoder().decode(DashboardConfig.self, from: data) {
            return migrateAndPersist(stored)
        }
        // No single-config blob, but the user may already have a
        // dashboard list from a newer build. Reading the list as the
        // source of truth here avoids the "active dashboard suddenly
        // becomes Default" drift where the two keys disagreed.
        if let data = UserDefaults.standard.data(forKey: Self.dashboardListKey),
           let list = try? JSONDecoder().decode([DashboardConfig].self, from: data),
           !list.isEmpty {
            let activeUID = UserDefaults.standard.string(forKey: Self.activeDashboardKey)
            let chosen = list.first(where: { $0.uid == activeUID }) ?? list[0]
            return migrateAndPersist(chosen)
        }
        return Self.defaultConfig
    }

    /// Run the migrator + datasource backfill on a stored config, persisting
    /// the result if anything changed. Shared by `load()`'s two source paths.
    private func migrateAndPersist(_ stored: DashboardConfig) -> DashboardConfig {
        let original = stored
        var config = DashboardMigrator.migrate(stored)
        // Seed activeDatasource from the legacy global enum so the dashboard
        // remembers which backend the user was last using. (The migrator
        // backfills to localCLI; this overrides with the user's last choice
        // if known.)
        if config.activeDatasource?.kind == BuiltinDatasourceKind.localCLI,
           original.activeDatasource == nil,
           let raw = UserDefaults.standard.string(forKey: "dashboardDataSource"),
           let legacy = DashboardDataSource(rawValue: raw) {
            let kind = legacy == .server
                ? BuiltinDatasourceKind.promQLProxy
                : BuiltinDatasourceKind.localCLI
            config.activeDatasource = DatasourceSelector(kind: kind)
        }
        if config.schemaVersion != original.schemaVersion
            || config.activeDatasource != original.activeDatasource {
            save(config)
        }
        return config
    }

    func save(_ config: DashboardConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    func resetToDefault() {
        save(Self.defaultConfig)
    }

    // MARK: - Dashboard List (multiple dashboards)

    func loadDashboardList() -> [DashboardConfig] {
        guard let data = UserDefaults.standard.data(forKey: Self.dashboardListKey),
              let raw = try? JSONDecoder().decode([DashboardConfig].self, from: data)
        else {
            return [load()]
        }
        // Apply migrations to each entry so the in-memory list always
        // carries the latest schema, even for entries written before this
        // version. Persist back only if anything changed.
        var anyMigrated = false
        let list = raw.map { entry -> DashboardConfig in
            let migrated = DashboardMigrator.migrate(entry)
            if migrated.schemaVersion != entry.schemaVersion { anyMigrated = true }
            return migrated
        }
        if anyMigrated { saveDashboardList(list) }
        return list
    }

    func saveDashboardList(_ list: [DashboardConfig]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: Self.dashboardListKey)
    }

    var activeDashboardUID: String? {
        get { UserDefaults.standard.string(forKey: Self.activeDashboardKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.activeDashboardKey) }
    }

    // MARK: - Multi-Dashboard Operations

    func addDashboard(_ config: DashboardConfig) {
        var list = loadDashboardList()
        var newConfig = config
        newConfig.title = uniqueTitle(config.title, in: list)
        list.append(newConfig)
        saveDashboardList(list)
    }

    func deleteDashboard(uid: String) {
        var list = loadDashboardList()
        list.removeAll { $0.uid == uid }
        saveDashboardList(list)
    }

    func duplicateDashboard(uid: String) -> DashboardConfig? {
        let list = loadDashboardList()
        guard var original = list.first(where: { $0.uid == uid }) else { return nil }
        original.id = UUID()
        original.uid = DashboardConfig.generateUID()
        original.title = uniqueTitle(original.title, in: list)
        original.version = 1
        addDashboard(original)
        return original
    }

    func updateDashboardInList(_ config: DashboardConfig) {
        var list = loadDashboardList()
        // Identity is the UID, and ONLY the UID. Matching on title first meant
        // that two dashboards sharing a title — which a rename or an import
        // can produce, since neither enforces uniqueness after creation —
        // caused an edit to overwrite whichever one happened to come first in
        // the list. Silent loss of the wrong document.
        if let idx = list.firstIndex(where: { $0.uid == config.uid }) {
            list[idx] = config
        }
        // Don't append if not found — prevents duplication
        saveDashboardList(list)
    }

    func dashboard(for uid: String) -> DashboardConfig? {
        loadDashboardList().first { $0.uid == uid }
    }

    /// Generate unique title by appending number if needed
    private func uniqueTitle(_ base: String, in list: [DashboardConfig]) -> String {
        let existingTitles = Set(list.map(\.title))
        if !existingTitles.contains(base) { return base }
        // Explicit upper bound. In practice the user would never have
        // 1000 dashboards named the same thing, but `for i in 1...`
        // (infinite range) is an audit smell — bound it so a future
        // bug that fills `list` can't hang the app.
        for i in 1...1000 {
            let candidate = "\(base) \(i)"
            if !existingTitles.contains(candidate) { return candidate }
        }
        // Fallback: timestamp suffix.
        return "\(base) \(Int(Date().timeIntervalSince1970))"
    }

    // MARK: - JSON File Import/Export

    func exportToFile(_ config: DashboardConfig) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(config.title).json"
        panel.title = L.tr("대시보드 내보내기", "Export Dashboard")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try config.exportJSON()
            try data.write(to: url)
        } catch {
            // Error handled silently — could add alert later
        }
    }

    func importFromFile() -> DashboardConfig? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = L.tr("대시보드 가져오기", "Import Dashboard")

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let data = try Data(contentsOf: url)
            return try DashboardConfig.importJSON(data)
        } catch {
            // A malformed file must not look like "user pressed Cancel". The
            // caller cannot tell those apart from a bare nil, so the reason
            // surfaces here.
            lastImportError = Self.describeImportFailure(error, url: url)
            return nil
        }
    }

    /// Set when `importFromFile` fails; nil after a success or a cancel.
    private(set) var lastImportError: String?

    private static func describeImportFailure(_ error: Error, url: URL) -> String {
        let name = url.lastPathComponent
        if let decoding = error as? DecodingError {
            switch decoding {
            case let .keyNotFound(key, ctx):
                return L.tr("\(name): 필수 항목 '\(key.stringValue)'이 없습니다 (\(Self.path(ctx)))",
                            "\(name): missing required field '\(key.stringValue)' at \(Self.path(ctx))")
            case let .typeMismatch(_, ctx):
                return L.tr("\(name): 형식이 맞지 않습니다 (\(Self.path(ctx)))",
                            "\(name): type mismatch at \(Self.path(ctx))")
            case let .valueNotFound(_, ctx):
                return L.tr("\(name): 값이 비어 있습니다 (\(Self.path(ctx)))",
                            "\(name): null where a value is required at \(Self.path(ctx))")
            case .dataCorrupted:
                return L.tr("\(name): JSON을 읽을 수 없습니다", "\(name): not valid JSON")
            @unknown default:
                return L.tr("\(name): 불러오기 실패", "\(name): import failed")
            }
        }
        return L.tr("\(name): \(error.localizedDescription)", "\(name): \(error.localizedDescription)")
    }

    /// "panels[2].targets[0].metric" — a path the user can act on, rather than
    /// Swift's default coding-key dump.
    private static func path(_ ctx: DecodingError.Context) -> String {
        ctx.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
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
