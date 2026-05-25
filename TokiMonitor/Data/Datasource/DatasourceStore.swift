import Foundation

/// Persists user-defined datasource instances (Perses "user-level" scope).
/// Built-in defaults live in `DatasourceRegistry`; this store holds any
/// additional named instances the user has created.
@MainActor
final class DatasourceStore {
    private static let userKey = "datasourceInstances"

    func load() -> [DatasourceInstance] {
        guard let data = UserDefaults.standard.data(forKey: Self.userKey),
              let list = try? JSONDecoder().decode([DatasourceInstance].self, from: data)
        else { return [] }
        return list
    }

    func save(_ list: [DatasourceInstance]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: Self.userKey)
    }

    func add(_ instance: DatasourceInstance) {
        var list = load()
        list.removeAll { $0.id == instance.id || ($0.name == instance.name && $0.kind == instance.kind) }
        list.append(instance)
        save(list)
    }

    func remove(id: UUID) {
        var list = load()
        list.removeAll { $0.id == id }
        save(list)
    }
}
