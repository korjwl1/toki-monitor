import Foundation
import AppKit

/// What a save did.
///
/// A save that quietly does nothing is the worst of the three: the user sees an
/// edit on screen, the edit is not on disk, and nothing says so (계약 C6).
enum DashboardSaveOutcome: Equatable {
    /// Written.
    case saved
    /// 계약 C2: the document was written against a schema beyond this build, so
    /// the bytes it came in as went back down untouched rather than a re-encode
    /// of the parts this build happens to understand.
    case keptOriginalBytes
    /// Nothing was written and the previous state is intact. The string is for
    /// the user, not the log.
    case failed(String)
}

/// Persists dashboard configurations. Supports multiple dashboards,
/// JSON import/export, and schema migration.
@MainActor
final class DashboardConfigStore {
    private static let userDefaultsKey = "dashboardConfig"
    private static let dashboardListKey = "dashboardList"
    private static let activeDashboardKey = "activeDashboardUID"

    /// Retires the UserDefaults keys of features that have been removed
    /// (alerts, playlists) by renaming them, not by deleting them.
    ///
    /// Removing the feature was a product decision. Destroying the rules the
    /// user wrote for it is a separate one, and it is not ours to make on
    /// their behalf during a launch they did not ask for — there is no export,
    /// no warning and no undo, and the data cannot be reconstructed from
    /// anything else on disk. Constitution principle III.
    ///
    /// So the value moves to `<key>.removedFeatureArchive` and the live key is
    /// cleared. The app never reads the archive; it exists so that a user who
    /// asks "where did my alert rules go" has an answer other than "gone", and
    /// so that reinstating either feature is a rename rather than a rewrite.
    /// If an archive already exists the original is left alone rather than
    /// overwritten — a second launch must not clobber the first launch's copy.
    private static let retireRemovedFeatureKeysOnce: Void = {
        let removed = ["dashboardAlertRules", "dashboardPlaylists"]
        let defaults = UserDefaults.standard
        for key in removed {
            guard let value = defaults.object(forKey: key) else { continue }
            let archiveKey = key + ".removedFeatureArchive"
            if defaults.object(forKey: archiveKey) == nil {
                defaults.set(value, forKey: archiveKey)
            }
            defaults.removeObject(forKey: key)
        }
    }()

    /// Where this store reads and writes.
    ///
    /// Injectable for one reason: a test that exercised the save path against
    /// `.standard` would write into the real installation's dashboards. A
    /// previous session did exactly that and destroyed the user's work.
    private let defaults: UserDefaults

    /// The bytes a document came in as, for documents whose `schemaVersion` is
    /// beyond what this build writes. Keyed by `uid`, filled at decode time.
    ///
    /// Re-encoding one of these would let this build decide what a future
    /// schema looks like — it would write back only the fields it happens to
    /// have, plus whatever `unknownFields` caught, and silently normalise the
    /// rest. An unknown VALUE in a known key (a refresh interval this build has
    /// no case for, say) is not something `unknownFields` can carry. So the
    /// original goes back verbatim instead (계약 C2).
    private static var originalBytes: [String: Data] = [:]

    /// The reason the last save did not happen, or nil. The UI reads this
    /// rather than letting a failed save look like a successful one.
    private(set) var lastSaveError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Touch the static so the cleanup runs once per app launch.
        _ = Self.retireRemovedFeatureKeysOnce
    }

    /// Remember a read-only document's bytes so a later save can hand them back.
    /// A no-op for anything this build's schema covers.
    static func rememberOriginal(_ config: DashboardConfig, bytes: Data) {
        guard config.isReadOnlyForThisBuild else { return }
        originalBytes[config.uid] = bytes
    }

    /// The untouched bytes of a read-only document, if they were captured when
    /// it was read.
    static func originalBytes(forUID uid: String) -> Data? { originalBytes[uid] }

    // MARK: - Single Dashboard (backward compatible)

    func load() -> DashboardConfig {
        // Prefer the single-dashboard key (legacy / "active" surface).
        if let data = defaults.data(forKey: Self.userDefaultsKey),
           let stored = try? JSONDecoder().decode(DashboardConfig.self, from: data) {
            Self.rememberOriginal(stored, bytes: data)
            return migrateAndPersist(stored)
        }
        // No single-config blob, but the user may already have a
        // dashboard list from a newer build. Reading the list as the
        // source of truth here avoids the "active dashboard suddenly
        // becomes Default" drift where the two keys disagreed.
        if let data = defaults.data(forKey: Self.dashboardListKey) {
            let list = Self.decodeList(data).list
            guard !list.isEmpty else { return Self.defaultConfig }
            let activeUID = defaults.string(forKey: Self.activeDashboardKey)
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
           let raw = defaults.string(forKey: "dashboardDataSource"),
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

    @discardableResult
    func save(_ config: DashboardConfig) -> DashboardSaveOutcome {
        if config.isReadOnlyForThisBuild {
            // 계약 C2. Hand the original back rather than a re-encode; if it was
            // never captured, write nothing at all — either way this build does
            // not get to rewrite a document it cannot fully read.
            if let original = Self.originalBytes(forUID: config.uid) {
                defaults.set(original, forKey: Self.userDefaultsKey)
            }
            lastSaveError = nil
            return .keptOriginalBytes
        }
        guard let data = try? JSONEncoder().encode(config) else {
            let reason = L.tr(
                "'\(config.title)'을(를) 저장하지 못했습니다. 이전 상태는 그대로입니다.",
                "Could not save '\(config.title)'. The previous state is unchanged."
            )
            lastSaveError = reason
            return .failed(reason)
        }
        defaults.set(data, forKey: Self.userDefaultsKey)
        lastSaveError = nil
        return .saved
    }

    func resetToDefault() {
        save(Self.defaultConfig)
    }

    // MARK: - Dashboard List (multiple dashboards)

    func loadDashboardList() -> [DashboardConfig] {
        guard let data = defaults.data(forKey: Self.dashboardListKey) else {
            return [load()]
        }
        let (list, decodedAll) = Self.decodeList(data)
        guard !list.isEmpty else { return [load()] }

        // Apply migrations to each entry so the in-memory list always
        // carries the latest schema, even for entries written before this
        // version. Persist back only if anything changed.
        var anyMigrated = false
        let migrated = list.map { entry -> DashboardConfig in
            let m = DashboardMigrator.migrate(entry)
            if m.schemaVersion != entry.schemaVersion { anyMigrated = true }
            return m
        }
        // Only write back when every entry was understood. Saving a partial
        // list would make a transient read failure permanent — the entries
        // this build could not decode would be erased from disk on the next
        // save, and a downgrade or a future field would cost the user
        // dashboards it merely failed to READ.
        if anyMigrated && decodedAll { saveDashboardList(migrated) }
        return migrated
    }

    /// Decode the list entry by entry.
    ///
    /// Decoding `[DashboardConfig]` in one call is all-or-nothing: a single
    /// entry this build cannot read — one written by a newer version, one
    /// naming a panel type that did not exist yet — fails the whole array, and
    /// the caller then falls back to a single default and overwrites
    /// everything. One unreadable dashboard must cost the user that dashboard,
    /// not all of them.
    ///
    /// Returns the entries that decoded, and whether all of them did.
    static func decodeList(_ data: Data) -> (list: [DashboardConfig], decodedAll: Bool) {
        let decoder = JSONDecoder()
        // Even on the fast path the elements are walked once, so that a
        // read-only document's own bytes are captured for a later save.
        if let list = try? decoder.decode([DashboardConfig].self, from: data) {
            captureOriginals(in: data, for: list)
            return (list, true)
        }
        // Split the array at the JSON level so each element can be attempted
        // on its own, without a Codable type that has to model every shape a
        // dashboard might have.
        guard let elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return ([], false)
        }
        var out: [DashboardConfig] = []
        for element in elements {
            guard let elementData = try? JSONSerialization.data(
                    withJSONObject: element, options: [.fragmentsAllowed]),
                  let config = try? decoder.decode(DashboardConfig.self, from: elementData)
            else { continue }
            rememberOriginal(config, bytes: elementData)
            out.append(config)
        }
        return (out, out.count == elements.count)
    }

    /// Capture the on-disk bytes of every read-only entry in a list. Only the
    /// read-only ones are kept, so the cost on an ordinary list is one pass and
    /// no storage.
    private static func captureOriginals(in data: Data, for list: [DashboardConfig]) {
        guard list.contains(where: \.isReadOnlyForThisBuild),
              let elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return }
        for (config, element) in zip(list, elements) where config.isReadOnlyForThisBuild {
            guard let bytes = try? JSONSerialization.data(
                withJSONObject: element, options: [.fragmentsAllowed]) else { continue }
            rememberOriginal(config, bytes: bytes)
        }
    }

    @discardableResult
    func saveDashboardList(_ list: [DashboardConfig]) -> DashboardSaveOutcome {
        guard let encoded = try? JSONEncoder().encode(list),
              var elements = (try? JSONSerialization.jsonObject(with: encoded)) as? [Any]
        else {
            // Nothing has been written, so the list on disk is still the last
            // good one. Saying so is the whole point — a silent `return` here
            // let an edit vanish between the screen and the disk (계약 C6).
            let reason = L.tr("대시보드 목록을 저장하지 못했습니다. 이전 상태는 그대로입니다.",
                              "Could not save the dashboard list. The previous state is unchanged.")
            lastSaveError = reason
            return .failed(reason)
        }

        // A document from a schema beyond this build goes back as the bytes it
        // came in as, never as a re-encode (계약 C2).
        var keptOriginal = false
        for (index, config) in list.enumerated() where config.isReadOnlyForThisBuild {
            guard let bytes = Self.originalBytes(forUID: config.uid),
                  let object = try? JSONSerialization.jsonObject(
                    with: bytes, options: [.fragmentsAllowed])
            else { continue }
            elements[index] = object
            keptOriginal = true
        }

        // Carry forward any stored entry this build could not decode.
        //
        // Without this, `loadDashboardList()` returning a partial list and the
        // caller then adding or deleting a dashboard would erase the entries
        // that merely failed to READ — a downgrade would silently delete every
        // dashboard the newer build had written, on the first edit. The user
        // cannot see them, so they cannot have meant to remove them.
        let known = Set(list.map(\.uid))
        elements.append(contentsOf: Self.unreadableEntries(in: defaults, excludingUIDs: known))

        guard let data = try? JSONSerialization.data(withJSONObject: elements) else {
            let reason = L.tr("대시보드 목록을 저장하지 못했습니다. 이전 상태는 그대로입니다.",
                              "Could not save the dashboard list. The previous state is unchanged.")
            lastSaveError = reason
            return .failed(reason)
        }
        defaults.set(data, forKey: Self.dashboardListKey)
        lastSaveError = nil
        return keptOriginal ? .keptOriginalBytes : .saved
    }

    /// Stored list elements that do not decode into a `DashboardConfig`, minus
    /// any whose `uid` is already accounted for. `uid` is a plain string field,
    /// so it is readable even when the entry as a whole is not.
    private static func unreadableEntries(in defaults: UserDefaults,
                                          excludingUIDs known: Set<String>) -> [Any] {
        guard let data = defaults.data(forKey: dashboardListKey),
              let elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        let decoder = JSONDecoder()
        return elements.filter { element in
            guard let elementData = try? JSONSerialization.data(
                    withJSONObject: element, options: [.fragmentsAllowed])
            else { return false }
            if (try? decoder.decode(DashboardConfig.self, from: elementData)) != nil {
                return false
            }
            let uid = (element as? [String: Any])?["uid"] as? String
            return uid.map { !known.contains($0) } ?? true
        }
    }

    var activeDashboardUID: String? {
        get { defaults.string(forKey: Self.activeDashboardKey) }
        set { defaults.set(newValue, forKey: Self.activeDashboardKey) }
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

    @discardableResult
    func updateDashboardInList(_ config: DashboardConfig) -> DashboardSaveOutcome {
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
        return saveDashboardList(list)
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

    /// Set when `exportToFile` fails; nil after a success or a cancel.
    private(set) var lastExportError: String?

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

    /// Set when `chooseImportFile` fails; nil after a success or a cancel.
    private(set) var lastImportError: String?

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
