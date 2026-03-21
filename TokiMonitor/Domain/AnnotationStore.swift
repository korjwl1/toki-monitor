import Foundation

/// Persists dashboard annotations per dashboard UID.
@MainActor
final class AnnotationStore {
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
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let items = try? JSONDecoder().decode([DashboardAnnotation].self, from: data)
        else { return [] }
        return items
    }

    private func saveAll(_ items: [DashboardAnnotation]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }
}
