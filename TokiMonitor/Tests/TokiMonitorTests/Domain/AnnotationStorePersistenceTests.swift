import Foundation
import Testing
@testable import TokiMonitor

/// The save path of `AnnotationStore`, driven through its public API.
///
/// Every mutator here is load → change → write the whole array. That shape is
/// what made the all-or-nothing decode a data-loss bug rather than a display
/// bug: one annotation this build could not read meant "there are no
/// annotations", and the next `addAnnotation` wrote that belief over every
/// annotation on every dashboard. Annotations are typed by hand and exist
/// nowhere else.
///
/// These run against a scratch `UserDefaults` suite, never `.standard`. In
/// this test target `UserDefaults.standard` is the live `com.toki.monitor`
/// domain holding the user's real work — a previous session destroyed it
/// exactly that way.
@MainActor
@Suite("Annotations survive an entry the build cannot read")
struct AnnotationStorePersistenceTests {

    private static let storeKey = "dashboardAnnotations"

    /// Valid JSON that this build cannot decode: `text` is an object, as a
    /// later build that made annotation text structured would write it.
    private var futureAnnotation: [String: Any] {
        [
            "id": "8B0D6C1E-5F2A-4E0B-9C3D-7A1E4F6B2C90",
            "dashboardUID": "other-dashboard",
            "timestamp": 760_000_000.0,
            "text": ["markdown": "deploy **v3**", "author": "jw"],
            "tags": ["release"],
            "colorHex": "#00AAFF",
        ]
    }

    private func annotation(
        _ text: String, uid: String, at seconds: TimeInterval = 700_000_000
    ) -> DashboardAnnotation {
        DashboardAnnotation(
            dashboardUID: uid,
            timestamp: Date(timeIntervalSinceReferenceDate: seconds),
            text: text
        )
    }

    private func encoded(_ a: DashboardAnnotation) -> Any {
        try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(a))
    }

    /// A scratch defaults suite seeded with `elements`, handed to `body` along
    /// with a store pointed at it. Torn down unconditionally so no
    /// `toki.monitor.tests.<uuid>.plist` is left behind.
    private func withSeededStore(
        _ elements: [Any],
        _ body: (AnnotationStore, UserDefaults) throws -> Void
    ) rethrows {
        try ScratchDefaults.with { defaults in
            defaults.set(try! JSONSerialization.data(withJSONObject: elements), forKey: Self.storeKey)
            try body(AnnotationStore(defaults: defaults), defaults)
        }
    }

    /// What is on disk right now, as raw JSON.
    private func stored(_ defaults: UserDefaults) throws -> [[String: Any]] {
        let data = try #require(defaults.data(forKey: Self.storeKey))
        return try #require(
            (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        ).compactMap { $0 as? [String: Any] }
    }

    // MARK: - Reading

    @Test("an unreadable annotation costs itself, not the readable ones")
    func readingKeepsTheRest() throws {
        try withSeededStore([
            encoded(annotation("shipped", uid: "main")),
            futureAnnotation,
            encoded(annotation("rollback", uid: "main")),
        ]) { store, _ in
            let visible = store.annotations(for: "main")
            #expect(visible.map(\.text).sorted() == ["rollback", "shipped"])
        }
    }

    // MARK: - Writing

    @Test("adding an annotation does not delete the one the build cannot read")
    func addPreservesUnreadable() throws {
        try withSeededStore([
            encoded(annotation("shipped", uid: "main")),
            futureAnnotation,
        ]) { store, defaults in
            store.addAnnotation(annotation("new note", uid: "main"))

            let raw = try stored(defaults)
            #expect(raw.count == 3)

            // Still there, and still itself: a re-encode through
            // `DashboardAnnotation` would have flattened `text` to a string and
            // silently rewritten what the user's other build wrote.
            let kept = try #require(raw.first { $0["dashboardUID"] as? String == "other-dashboard" })
            let text = try #require(kept["text"] as? [String: Any])
            #expect(text["markdown"] as? String == "deploy **v3**")
            #expect(text["author"] as? String == "jw")
            #expect(kept["colorHex"] as? String == "#00AAFF")

            #expect(store.annotations(for: "main").count == 2)
        }
    }

    @Test("removing one annotation does not take the unreadable one with it")
    func removePreservesUnreadable() throws {
        let doomed = annotation("shipped", uid: "main")
        try withSeededStore([encoded(doomed), futureAnnotation]) { store, defaults in
            store.removeAnnotation(id: doomed.id)

            let raw = try stored(defaults)
            #expect(raw.count == 1)
            #expect(raw.first?["dashboardUID"] as? String == "other-dashboard")
            #expect(store.annotations(for: "main").isEmpty)
        }
    }

    @Test("clearing one dashboard leaves an unreadable entry belonging to another")
    func removeAllForOneDashboardPreservesUnreadable() throws {
        // The sharpest version of the bug: the user clears the annotations on
        // the dashboard they are looking at, and the unreadable entry belongs
        // to a different dashboard entirely. It has no business being touched.
        try withSeededStore([
            encoded(annotation("a", uid: "main")),
            encoded(annotation("b", uid: "main")),
            futureAnnotation,
        ]) { store, defaults in
            store.removeAll(for: "main")

            let raw = try stored(defaults)
            #expect(raw.count == 1)
            #expect(raw.first?["dashboardUID"] as? String == "other-dashboard")
        }
    }

    @Test("editing an annotation does not disturb the unreadable one")
    func updatePreservesUnreadable() throws {
        var edited = annotation("typo", uid: "main")
        try withSeededStore([encoded(edited), futureAnnotation]) { store, defaults in
            edited.text = "fixed"
            store.updateAnnotation(edited)

            #expect(store.annotations(for: "main").map(\.text) == ["fixed"])
            let raw = try stored(defaults)
            #expect(raw.count == 2)
            #expect(raw.contains { $0["dashboardUID"] as? String == "other-dashboard" })
        }
    }

    @Test("repeated edits do not erode the unreadable entry")
    func repeatedEditsAreStable() throws {
        try withSeededStore([futureAnnotation]) { store, defaults in
            // Five ordinary edits. The bug is cumulative in the other
            // direction — one save is enough to lose everything — so a store
            // that survives one save but drops the entry on the second is
            // still broken.
            for i in 0..<5 {
                store.addAnnotation(annotation("note \(i)", uid: "main", at: 700_000_000 + Double(i)))
            }

            #expect(store.annotations(for: "main").count == 5)
            let raw = try stored(defaults)
            #expect(raw.count == 6)
            let kept = try #require(raw.first { $0["dashboardUID"] as? String == "other-dashboard" })
            #expect((kept["text"] as? [String: Any])?["markdown"] as? String == "deploy **v3**")
        }
    }

    @Test("a store with nothing written yet reads and writes cleanly")
    func emptyStore() {
        ScratchDefaults.with { defaults in
            let store = AnnotationStore(defaults: defaults)
            #expect(store.annotations(for: "main").isEmpty)
            store.addAnnotation(annotation("first", uid: "main"))
            #expect(store.annotations(for: "main").map(\.text) == ["first"])
        }
    }
}
