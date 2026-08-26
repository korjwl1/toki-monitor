import Foundation
import Testing
@testable import TokiMonitor

/// The half of `DashboardVersionStore` that `VersionHistoryDiffTests` says it
/// deliberately leaves out: the persistence path.
///
/// It could not be covered before because the store read and wrote
/// `UserDefaults.standard` with no injection point, and in this test target
/// `UserDefaults.standard` is the live `com.toki.monitor` domain holding the
/// user's real dashboards. The store now takes `init(defaults:)` — the same
/// shape `DashboardConfigStore` already had, for the same reason — so these
/// run against a scratch suite.
///
/// What is under test is the loss: `saveVersion` and `deleteVersions` both
/// write the whole array back, so an all-or-nothing decode turned one entry
/// this build could not read into the silent deletion of every version the
/// user had. Unlike the dashboard list, nothing else holds a copy.
@MainActor
@Suite("Version history survives an entry the build cannot read")
struct DashboardVersionStorePersistenceTests {

    private static let storeKey = "dashboardVersions"

    private func config(_ title: String, uid: String = "main") -> DashboardConfig {
        var c = DashboardConfig()
        c.uid = uid
        c.title = title
        return c
    }

    /// Valid JSON this build cannot decode: `version` is a string where an Int
    /// is required, the structural fault an older build meeting a newer
    /// numbering scheme would hit.
    private var futureVersion: [String: Any] {
        [
            "id": "F1A2B3C4-D5E6-4789-9ABC-DEF012345678",
            "dashboardUID": "main",
            "version": "3.1",
            "timestamp": 760_000_000.0,
            "config": encoded(config("From a newer build")),
            "message": "renumbered by a later build",
        ]
    }

    private func encoded<T: Encodable>(_ value: T) -> Any {
        try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(value))
    }

    private func version(_ n: Int, _ title: String, uid: String = "main") -> DashboardVersion {
        DashboardVersion(dashboardUID: uid, version: n, config: config(title, uid: uid))
    }

    private func withSeededStore(
        _ elements: [Any],
        _ body: (DashboardVersionStore, UserDefaults) throws -> Void
    ) rethrows {
        try ScratchDefaults.with { defaults in
            defaults.set(try! JSONSerialization.data(withJSONObject: elements), forKey: Self.storeKey)
            try body(DashboardVersionStore(defaults: defaults), defaults)
        }
    }

    private func stored(_ defaults: UserDefaults) throws -> [[String: Any]] {
        let data = try #require(defaults.data(forKey: Self.storeKey))
        return try #require(
            (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        ).compactMap { $0 as? [String: Any] }
    }

    // MARK: - Reading

    @Test("an unreadable version costs itself, not the readable ones")
    func readingKeepsTheRest() throws {
        try withSeededStore([
            encoded(version(1, "first")),
            futureVersion,
            encoded(version(2, "second")),
        ]) { store, _ in
            #expect(store.versions(for: "main").map(\.version) == [2, 1])
        }
    }

    // MARK: - Writing

    @Test("saving a version does not delete the one the build cannot read")
    func savePreservesUnreadable() throws {
        try withSeededStore([encoded(version(1, "first")), futureVersion]) { store, defaults in
            store.saveVersion(for: config("third"), message: "edit")

            let raw = try stored(defaults)
            #expect(raw.count == 3)

            let kept = try #require(raw.first { $0["version"] as? String == "3.1" })
            #expect(kept["message"] as? String == "renumbered by a later build")
            let keptConfig = try #require(kept["config"] as? [String: Any])
            #expect(keptConfig["title"] as? String == "From a newer build")

            #expect(store.versions(for: "main").count == 2)
        }
    }

    @Test("deleting one dashboard's history leaves an unreadable entry for another")
    func deleteForOtherDashboardPreservesUnreadable() throws {
        // The unreadable entry says `dashboardUID: "main"`, but this build
        // cannot decode it, so it cannot know that. Deleting a *different*
        // dashboard's history must still write it back untouched.
        try withSeededStore([
            encoded(version(1, "a", uid: "other")),
            futureVersion,
        ]) { store, defaults in
            store.deleteVersions(for: "other")

            let raw = try stored(defaults)
            #expect(raw.count == 1)
            #expect(raw.first?["version"] as? String == "3.1")
        }
    }

    @Test("clearing a dashboard whose only remaining entry is unreadable is not a delete")
    func deleteEverythingReadableIsNotDeleteEverything() throws {
        try withSeededStore([encoded(version(1, "a")), futureVersion]) { store, defaults in
            store.deleteVersions(for: "main")

            #expect(store.versions(for: "main").isEmpty)
            let raw = try stored(defaults)
            #expect(raw.count == 1)
            #expect(raw.first?["version"] as? String == "3.1")
        }
    }

    @Test("repeated saves do not erode the unreadable entry")
    func repeatedSavesAreStable() throws {
        try withSeededStore([futureVersion]) { store, defaults in
            for i in 0..<5 { store.saveVersion(for: config("edit \(i)")) }

            #expect(store.versions(for: "main").map(\.version) == [5, 4, 3, 2, 1])
            let raw = try stored(defaults)
            #expect(raw.count == 6)
            let kept = try #require(raw.first { $0["version"] as? String == "3.1" })
            #expect((kept["config"] as? [String: Any])?["title"] as? String == "From a newer build")
        }
    }

    @Test("a store with nothing written yet reads and writes cleanly")
    func emptyStore() {
        ScratchDefaults.with { defaults in
            let store = DashboardVersionStore(defaults: defaults)
            #expect(store.versions(for: "main").isEmpty)
            store.saveVersion(for: config("first"), message: "initial")
            #expect(store.versions(for: "main").map(\.version) == [1])
            #expect(store.versions(for: "main").first?.message == "initial")
        }
    }
}
