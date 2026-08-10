import Testing
import Foundation
@testable import TokiMonitor

/// The store had a data-loss path with no tests on it at all: the dashboard
/// list decoded all-or-nothing, so ONE entry this build could not read failed
/// the whole array, the caller fell back to a single default, and the next
/// save overwrote everything. It is reachable by an ordinary downgrade — an
/// older build meeting a panel type that did not exist when it shipped.
///
/// These tests work on the decode/merge functions rather than UserDefaults, so
/// they cannot disturb a real installation.
@Suite("Dashboard list survives an entry it cannot read")
@MainActor
struct DashboardConfigStoreTests {

    private func dashboard(_ title: String, uid: String) -> DashboardConfig {
        var c = DashboardConfig()
        c.title = title
        c.uid = uid
        return c
    }

    private func listData(_ elements: [Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: elements)
    }

    private func encoded(_ config: DashboardConfig) -> Any {
        let data = try! JSONEncoder().encode(config)
        return try! JSONSerialization.jsonObject(with: data)
    }

    /// An entry from a newer build: valid JSON, but names a panel type this
    /// build's enum has no case for.
    private var futureEntry: [String: Any] {
        [
            "id": UUID().uuidString,
            "uid": "fromfuture",
            "title": "From a newer build",
            "schemaVersion": 4,
            "version": 1,
            "tags": [],
            "panels": [[
                "id": UUID().uuidString,
                "title": "p",
                "panelType": "somethingThisBuildDoesNotKnow",
                "metric": "totalTokens",
                "gridPosition": ["column": 0, "row": 0, "width": 6, "height": 2],
                "targets": [], "dataLinks": [], "collapsed": false,
                "options": [:],
            ]],
            "annotations": [], "editable": true, "datasources": [:],
            "templating": ["list": []],
            "time": ["from": "now-24h", "to": "now"],
            "refresh": "",
        ]
    }

    // MARK: - Reading

    @Test("one unreadable entry costs that entry, not the whole list")
    func partialDecodeKeepsTheRest() {
        let data = listData([
            encoded(dashboard("Default", uid: "aaa")),
            futureEntry,
            encoded(dashboard("Work", uid: "ccc")),
        ])
        let (list, decodedAll) = DashboardConfigStore.decodeList(data)
        #expect(list.map(\.uid) == ["aaa", "ccc"])
        #expect(!decodedAll, "the caller must know something was skipped")
    }

    @Test("a list this build understands fully reports so")
    func fullDecodeReportsComplete() {
        let data = listData([
            encoded(dashboard("Default", uid: "aaa")),
            encoded(dashboard("Work", uid: "bbb")),
        ])
        let (list, decodedAll) = DashboardConfigStore.decodeList(data)
        #expect(list.count == 2)
        #expect(decodedAll)
    }

    @Test("garbage that is not even an array yields nothing rather than a crash")
    func nonArrayIsEmpty() {
        let (list, decodedAll) = DashboardConfigStore.decodeList(Data("not json".utf8))
        #expect(list.isEmpty)
        #expect(!decodedAll)
    }

    @Test("an empty list is complete, not a failure")
    func emptyListIsComplete() {
        let (list, decodedAll) = DashboardConfigStore.decodeList(listData([]))
        #expect(list.isEmpty)
        #expect(decodedAll)
    }

    /// The failure that actually happened: a value of the wrong TYPE for a
    /// required field. Every other entry must still load.
    @Test("a type mismatch in one entry does not take its neighbours down")
    func typeMismatchIsContained() {
        var broken = futureEntry
        broken["schemaVersion"] = "four"
        let data = listData([encoded(dashboard("Default", uid: "aaa")), broken])
        #expect(DashboardConfigStore.decodeList(data).list.map(\.uid) == ["aaa"])
    }

    // MARK: - Round-tripping what could not be read

    /// Re-encoding only what decoded is what makes the loss permanent: the
    /// user adds one dashboard and the entries this build could not read are
    /// gone from disk forever.
    @Test("an unreadable entry is still in the bytes after a save")
    func unreadableEntrySurvivesAWrite() throws {
        let stored = listData([encoded(dashboard("Default", uid: "aaa")), futureEntry])
        let (list, _) = DashboardConfigStore.decodeList(stored)
        #expect(list.map(\.uid) == ["aaa"])

        // What a save must produce: the decoded entries plus the untouched
        // bytes of the ones that were skipped.
        let survivors = try #require(
            (try? JSONSerialization.jsonObject(with: stored)) as? [Any]
        ).filter { element in
            guard let d = try? JSONSerialization.data(withJSONObject: element) else { return false }
            return (try? JSONDecoder().decode(DashboardConfig.self, from: d)) == nil
        }
        #expect(survivors.count == 1)
        #expect((survivors[0] as? [String: Any])?["uid"] as? String == "fromfuture")
    }

    // MARK: - Migration is not a rewrite

    /// Every field this rework added is optional, so a dashboard written
    /// before them must migrate without acquiring anything it did not have.
    @Test("a pre-rework dashboard migrates without gaining invented settings")
    func migrationLeavesNewFieldsAlone() throws {
        var old = dashboard("Old", uid: "old")
        old.schemaVersion = 3
        old.panels = [PanelConfig(
            title: "p", panelType: .stat, metric: .totalTokens,
            gridPosition: GridPosition(column: 0, row: 0, width: 6, height: 1)
        )]

        let migrated = DashboardMigrator.migrate(old)
        #expect(migrated.schemaVersion == DashboardMigrator.currentVersion)
        let panel = try #require(migrated.panels.first)
        #expect(panel.fieldConfig == nil)
        #expect(panel.fieldSelection == nil)
        #expect(panel.panelType == .stat)
    }

    @Test("migrating twice changes nothing the second time")
    func migrationIsIdempotent() {
        var old = dashboard("Old", uid: "old")
        old.schemaVersion = 1
        let once = DashboardMigrator.migrate(old)
        let twice = DashboardMigrator.migrate(once)
        #expect(once == twice)
    }

    /// A config from a newer schema must be left alone rather than "migrated"
    /// backwards into something this build likes.
    @Test("a newer schema version is not rewritten")
    func newerSchemaUntouched() {
        var future = dashboard("Future", uid: "f")
        future.schemaVersion = DashboardMigrator.currentVersion + 1
        #expect(DashboardMigrator.migrate(future) == future)
    }
}
