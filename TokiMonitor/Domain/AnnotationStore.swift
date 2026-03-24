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

    private func loadAll() -> [DashboardAnnotation] {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey) else { return [] }
        do {
            return try JSONDecoder().decode([DashboardAnnotation].self, from: data)
        } catch {
            Self.logger.error("Failed to decode annotations from key '\(Self.storeKey)': \(error.localizedDescription)")
            return []
        }
    }

    private func saveAll(_ items: [DashboardAnnotation]) {
        do {
            let data = try JSONEncoder().encode(items)
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        } catch {
            Self.logger.error("Failed to encode \(items.count) annotations for key '\(Self.storeKey)': \(error.localizedDescription)")
        }
    }
}
