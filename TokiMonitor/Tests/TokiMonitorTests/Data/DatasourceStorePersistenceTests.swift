import Foundation
import Testing
@testable import TokiMonitor

/// The save path of `DatasourceStore`, driven through its public API.
///
/// `add` and `remove` both load, change and write the whole list, so an
/// all-or-nothing decode let one unreadable instance delete every datasource
/// the user had defined on the next edit. Built-in kinds live in
/// `DatasourceRegistry` and come back; anything hand-configured does not.
///
/// A scratch `UserDefaults` suite throughout — in this test target
/// `UserDefaults.standard` is the live `com.toki.monitor` domain.
@MainActor
@Suite("Datasources survive an entry the build cannot read")
struct DatasourceStorePersistenceTests {

    private static let userKey = "datasourceInstances"

    /// Valid JSON this build cannot decode: `name` is an object, as a later
    /// build that made datasource names localizable would write it.
    private var futureInstance: [String: Any] {
        [
            "id": "3C7E9A21-64B8-4D5F-8E1A-2B9C0D3F5A67",
            "name": ["ko": "사내 프록시", "en": "corp proxy"],
            "kind": "toki-server",
            "displayName": "Corp proxy",
            "spec": "eyJ1cmwiOiJodHRwczovL2ludGVybmFsIn0=",
            "isDefault": false,
        ]
    }

    private func instance(_ name: String, kind: String = "toki-server") -> DatasourceInstance {
        DatasourceInstance(name: name, kind: kind, displayName: nil)
    }

    private func encoded(_ i: DatasourceInstance) -> Any {
        try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(i))
    }

    private func withSeededStore(
        _ elements: [Any],
        _ body: (DatasourceStore, UserDefaults) throws -> Void
    ) rethrows {
        try ScratchDefaults.with { defaults in
            defaults.set(try! JSONSerialization.data(withJSONObject: elements), forKey: Self.userKey)
            try body(DatasourceStore(defaults: defaults), defaults)
        }
    }

    private func stored(_ defaults: UserDefaults) throws -> [[String: Any]] {
        let data = try #require(defaults.data(forKey: Self.userKey))
        return try #require(
            (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        ).compactMap { $0 as? [String: Any] }
    }

    // MARK: - Reading

    @Test("an unreadable instance costs itself, not the readable ones")
    func readingKeepsTheRest() throws {
        try withSeededStore([
            encoded(instance("staging")),
            futureInstance,
            encoded(instance("prod")),
        ]) { store, _ in
            #expect(store.load().map(\.name).sorted() == ["prod", "staging"])
        }
    }

    // MARK: - Writing

    @Test("adding a datasource does not delete the one the build cannot read")
    func addPreservesUnreadable() throws {
        try withSeededStore([encoded(instance("staging")), futureInstance]) { store, defaults in
            store.add(instance("prod"))

            let raw = try stored(defaults)
            #expect(raw.count == 3)

            let kept = try #require(raw.first { $0["displayName"] as? String == "Corp proxy" })
            let name = try #require(kept["name"] as? [String: Any])
            #expect(name["ko"] as? String == "사내 프록시")
            #expect(name["en"] as? String == "corp proxy")
            #expect(kept["spec"] as? String == "eyJ1cmwiOiJodHRwczovL2ludGVybmFsIn0=")

            #expect(store.load().map(\.name).sorted() == ["prod", "staging"])
        }
    }

    @Test("removing a datasource does not take the unreadable one with it")
    func removePreservesUnreadable() throws {
        let doomed = instance("staging")
        try withSeededStore([encoded(doomed), futureInstance]) { store, defaults in
            store.remove(id: doomed.id)

            let raw = try stored(defaults)
            #expect(raw.count == 1)
            #expect(raw.first?["displayName"] as? String == "Corp proxy")
            #expect(store.load().isEmpty)
        }
    }

    @Test("removing the last readable datasource still leaves the unreadable one")
    func removingEverythingReadableIsNotRemovingEverything() throws {
        // `load()` returns [] here whether the store is empty or unreadable.
        // The whole repair is that `save([])` must still not be a delete.
        try withSeededStore([futureInstance]) { store, defaults in
            #expect(store.load().isEmpty)
            store.save([])

            let raw = try stored(defaults)
            #expect(raw.count == 1)
            #expect((raw.first?["name"] as? [String: Any])?["en"] as? String == "corp proxy")
        }
    }

    @Test("replacing an instance by name and kind leaves the unreadable one alone")
    func replacePreservesUnreadable() throws {
        try withSeededStore([encoded(instance("prod")), futureInstance]) { store, defaults in
            // `add` de-dupes on (name, kind), so this replaces rather than appends.
            var replacement = instance("prod")
            replacement.displayName = "Production"
            store.add(replacement)

            #expect(store.load().count == 1)
            #expect(store.load().first?.displayName == "Production")

            let raw = try stored(defaults)
            #expect(raw.count == 2)
            #expect(raw.contains { $0["displayName"] as? String == "Corp proxy" })
        }
    }

    @Test("repeated edits do not erode the unreadable entry")
    func repeatedEditsAreStable() throws {
        try withSeededStore([futureInstance]) { store, defaults in
            for i in 0..<5 { store.add(instance("ds\(i)")) }

            #expect(store.load().count == 5)
            let raw = try stored(defaults)
            #expect(raw.count == 6)
            #expect(raw.contains { $0["displayName"] as? String == "Corp proxy" })
        }
    }

    @Test("a store with nothing written yet reads and writes cleanly")
    func emptyStore() {
        ScratchDefaults.with { defaults in
            let store = DatasourceStore(defaults: defaults)
            #expect(store.load().isEmpty)
            store.add(instance("first"))
            #expect(store.load().map(\.name) == ["first"])
        }
    }
}
