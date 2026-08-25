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

// MARK: - Round trip (계약 C1)

/// `save(load(D)) ≡ D`, modulo normalisation of the parts this build
/// understands.
///
/// The path these guard is ordinary and silent: a newer build writes a field, an
/// older build opens the dashboard once and saves, and the field is gone. The
/// user pressed save. Nothing told them anything was dropped, and unlike event
/// data there is no provider log to rebuild a dashboard from.
@Suite("A dashboard survives a build that does not understand all of it")
@MainActor
struct DashboardRoundTripTests {

    private var base: DashboardConfig { DashboardConfigStore.defaultConfig }

    private func objectify(_ config: DashboardConfig) throws -> [String: Any] {
        let data = try JSONEncoder().encode(config)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> DashboardConfig {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(DashboardConfig.self, from: data)
    }

    /// load → save, expressed as JSON on both ends so the assertion is about
    /// the bytes a downgrade would leave on disk, not about in-memory fields.
    private func roundTrip(_ object: [String: Any]) throws -> [String: Any] {
        try objectify(try decode(object))
    }

    // MARK: Level 1 — the dashboard

    @Test("an unknown key on the dashboard comes back with its value intact")
    func dashboardLevelKeySurvives() throws {
        var doc = try objectify(base)
        doc["crossPanelLinking"] = ["mode": "shared", "maxHops": 3, "enabled": true]

        let out = try roundTrip(doc)
        let carried = try #require(out["crossPanelLinking"] as? [String: Any])
        #expect(carried["mode"] as? String == "shared")
        #expect(carried["maxHops"] as? Int == 3)
        #expect(carried["enabled"] as? Bool == true)
    }

    // MARK: Level 2 — a panel

    @Test("an unknown key on a panel comes back with its value intact")
    func panelLevelKeySurvives() throws {
        var doc = try objectify(base)
        var panels = try #require(doc["panels"] as? [[String: Any]])
        panels[0]["annotationOverlay"] = ["source": "deploys", "opacity": 0.35]
        doc["panels"] = panels

        let out = try roundTrip(doc)
        let outPanels = try #require(out["panels"] as? [[String: Any]])
        let carried = try #require(outPanels[0]["annotationOverlay"] as? [String: Any])
        #expect(carried["source"] as? String == "deploys")
        #expect(carried["opacity"] as? Double == 0.35)
    }

    // MARK: Level 3 — a variable

    @Test("an unknown key on a variable comes back with its value intact")
    func variableLevelKeySurvives() throws {
        var doc = try objectify(base)
        var templating = try #require(doc["templating"] as? [String: Any])
        var list = try #require(templating["list"] as? [[String: Any]])
        list[0]["dependsOn"] = ["cluster", "namespace"]
        templating["list"] = list
        doc["templating"] = templating

        let out = try roundTrip(doc)
        let outTemplating = try #require(out["templating"] as? [String: Any])
        let outList = try #require(outTemplating["list"] as? [[String: Any]])
        #expect(outList[0]["dependsOn"] as? [String] == ["cluster", "namespace"])
    }

    // MARK: All three at once

    @Test("all three levels survive the same round trip")
    func allThreeLevelsSurviveTogether() throws {
        var doc = try objectify(base)
        doc["futureDashboardKey"] = "d"
        var panels = try #require(doc["panels"] as? [[String: Any]])
        panels[0]["futurePanelKey"] = "p"
        doc["panels"] = panels
        var templating = try #require(doc["templating"] as? [String: Any])
        var list = try #require(templating["list"] as? [[String: Any]])
        list[0]["futureVariableKey"] = "v"
        templating["list"] = list
        doc["templating"] = templating

        let out = try roundTrip(doc)
        #expect(out["futureDashboardKey"] as? String == "d")
        #expect((out["panels"] as? [[String: Any]])?[0]["futurePanelKey"] as? String == "p")
        let outList = (out["templating"] as? [String: Any])?["list"] as? [[String: Any]]
        #expect(outList?[0]["futureVariableKey"] as? String == "v")
    }

    @Test("a second round trip does not accumulate or drop anything")
    func roundTripIsStable() throws {
        var doc = try objectify(base)
        doc["futureDashboardKey"] = ["a": 1]

        let once = try roundTrip(doc)
        let twice = try roundTrip(once)
        #expect(NSDictionary(dictionary: once) == NSDictionary(dictionary: twice))
    }

    @Test("a document with only known keys round-trips to itself")
    func knownOnlyDocumentIsUnchanged() throws {
        let doc = try objectify(base)
        let out = try roundTrip(doc)
        #expect(NSDictionary(dictionary: out) == NSDictionary(dictionary: doc))
    }

    /// A key this build DOES understand must come from the live field, not
    /// from a preserved copy — otherwise an edit would be shadowed by the
    /// value that was on disk when the dashboard was opened.
    @Test("an edit to a known field is not shadowed by preserved data")
    func knownFieldWinsOverPreserved() throws {
        var doc = try objectify(base)
        doc["futureDashboardKey"] = "x"
        var loaded = try decode(doc)
        loaded.title = "Renamed"
        let out = try objectify(loaded)
        #expect(out["title"] as? String == "Renamed")
        #expect(out["futureDashboardKey"] as? String == "x")
    }

    // MARK: - Unknown panel type (계약 R5)

    @Test("a panel type this build cannot draw keeps the panel")
    func unknownPanelTypeKeepsThePanel() throws {
        var doc = try objectify(base)
        var panels = try #require(doc["panels"] as? [[String: Any]])
        let panelCount = panels.count
        panels[0]["panelType"] = "sankeyDiagram"
        doc["panels"] = panels

        let loaded = try decode(doc)
        #expect(loaded.panels.count == panelCount, "the panel must not be deleted")
        #expect(loaded.panels[0].panelType == .unknown)
        #expect(loaded.panels[0].unknownPanelTypeRaw == "sankeyDiagram")
        #expect(loaded.panels[0].panelTypeLabel == "sankeyDiagram")
    }

    @Test("an unknown panel type is written back as the name it came in as")
    func unknownPanelTypeRoundTrips() throws {
        var doc = try objectify(base)
        var panels = try #require(doc["panels"] as? [[String: Any]])
        panels[0]["panelType"] = "sankeyDiagram"
        doc["panels"] = panels

        let out = try roundTrip(doc)
        let outPanels = try #require(out["panels"] as? [[String: Any]])
        #expect(outPanels[0]["panelType"] as? String == "sankeyDiagram")
    }

    @Test("changing an unknown panel to a type this build has drops the placeholder")
    func editingAwayFromUnknownWritesTheNewType() throws {
        var doc = try objectify(base)
        var panels = try #require(doc["panels"] as? [[String: Any]])
        panels[0]["panelType"] = "sankeyDiagram"
        doc["panels"] = panels

        var loaded = try decode(doc)
        loaded.panels[0].panelType = .table
        let out = try objectify(loaded)
        #expect((out["panels"] as? [[String: Any]])?[0]["panelType"] as? String == "table")
    }

    @Test("the whole rest of the dashboard still loads around an undrawable panel")
    func unknownPanelDoesNotCostTheDashboard() throws {
        var doc = try objectify(base)
        var panels = try #require(doc["panels"] as? [[String: Any]])
        panels[1]["panelType"] = "somethingFromLater"
        doc["panels"] = panels

        let loaded = try decode(doc)
        #expect(loaded.title == base.title)
        #expect(loaded.panels.count == base.panels.count)
        #expect(loaded.panels.filter { $0.panelType == .unknown }.count == 1)
    }
}
