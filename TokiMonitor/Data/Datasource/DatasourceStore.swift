import Foundation

/// Persists user-defined datasource instances (Perses "user-level" scope).
/// Built-in defaults live in `DatasourceRegistry`; this store holds any
/// additional named instances the user has created.
@MainActor
final class DatasourceStore {
    private static let userKey = "datasourceInstances"

    /// Where this store reads and writes.
    ///
    /// Injectable for one reason: a test that exercised the save path against
    /// `.standard` would write into the real installation's datasources. A
    /// previous session did exactly that and destroyed the user's work.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `add` and `remove` both load, change and write the whole list, so an
    /// all-or-nothing decode here would let one unreadable instance delete
    /// every datasource the user defined on the next edit. Built-in kinds live
    /// in `DatasourceRegistry` and survive; anything hand-configured does not.
    func load() -> [DatasourceInstance] {
        loadPreservingUnreadable().items
    }

    private func loadPreservingUnreadable() -> (items: [DatasourceInstance], unreadable: [Any]) {
        guard let data = defaults.data(forKey: Self.userKey) else { return ([], []) }
        return LossTolerantStore.decodeArray(DatasourceInstance.self, from: data)
    }

    func save(_ list: [DatasourceInstance]) {
        let unreadable = loadPreservingUnreadable().unreadable
        guard let data = LossTolerantStore.encodeArray(list, preserving: unreadable) else { return }
        defaults.set(data, forKey: Self.userKey)
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
