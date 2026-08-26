import Foundation
import os.log

/// Persists dashboard annotations per dashboard UID.
@MainActor
final class AnnotationStore {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TokiMonitor", category: "AnnotationStore")
    private static let storeKey = "dashboardAnnotations"

    func annotations(for dashboardUID: String) -> [DashboardAnnotation] {
        loadAll().filter { $0.dashboardUID == dashboardUID }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func addAnnotation(_ annotation: DashboardAnnotation) {
        var all = loadAll()
        all.append(annotation)
        saveAll(all)
    }

    func removeAnnotation(id: UUID) {
        var all = loadAll()
        all.removeAll { $0.id == id }
        saveAll(all)
    }

    func updateAnnotation(_ annotation: DashboardAnnotation) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.id == annotation.id }) {
            all[idx] = annotation
        }
        saveAll(all)
    }

    func removeAll(for dashboardUID: String) {
        var all = loadAll()
        all.removeAll { $0.dashboardUID == dashboardUID }
        saveAll(all)
    }

    // MARK: - Persistence

    /// Decoded annotations, plus the raw bytes of any entry this build could
    /// not read.
    ///
    /// The split is what stops a save from deleting everything. Every mutator
    /// here is load → change → write the whole array, so an all-or-nothing
    /// decode turns one unreadable annotation into "there are no annotations",
    /// and the next `addAnnotation` writes that belief to disk over every
    /// annotation on every dashboard. Logging the failure does not help: the
    /// caller gets `[]` either way and cannot tell "none" from "unreadable",
    /// so nothing upstream can refuse to save.
    ///
    /// Annotations are not reconstructible from anything else.
    private func loadAllPreservingUnreadable()
        -> (items: [DashboardAnnotation], unreadable: [Any]) {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey) else { return ([], []) }
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            Self.logger.error("Annotations at key '\(Self.storeKey)' are not a JSON array; leaving them untouched")
            return ([], [])
        }

        var items: [DashboardAnnotation] = []
        var unreadable: [Any] = []
        for element in raw {
            guard let bytes = try? JSONSerialization.data(withJSONObject: element),
                  let one = try? JSONDecoder().decode(DashboardAnnotation.self, from: bytes)
            else {
                unreadable.append(element)
                continue
            }
            items.append(one)
        }
        if !unreadable.isEmpty {
            Self.logger.error("\(unreadable.count) annotation(s) at key '\(Self.storeKey)' could not be decoded; they are preserved as written")
        }
        return (items, unreadable)
    }

    private func loadAll() -> [DashboardAnnotation] {
        loadAllPreservingUnreadable().items
    }

    /// Writes `items` back, re-appending verbatim whatever the load could not
    /// decode. Without that, saving is how the annotations get destroyed.
    private func saveAll(_ items: [DashboardAnnotation]) {
        let unreadable = loadAllPreservingUnreadable().unreadable
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(items)
        } catch {
            Self.logger.error("Failed to encode \(items.count) annotations for key '\(Self.storeKey)': \(error.localizedDescription)")
            return
        }

        guard !unreadable.isEmpty else {
            UserDefaults.standard.set(encoded, forKey: Self.storeKey)
            return
        }
        guard var merged = (try? JSONSerialization.jsonObject(with: encoded)) as? [Any],
              let out = { () -> Data? in
                  merged.append(contentsOf: unreadable)
                  return try? JSONSerialization.data(withJSONObject: merged)
              }()
        else {
            UserDefaults.standard.set(encoded, forKey: Self.storeKey)
            return
        }
        UserDefaults.standard.set(out, forKey: Self.storeKey)
    }
}
