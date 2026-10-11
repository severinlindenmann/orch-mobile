import Foundation

/// Durable list of workspaces removed locally whose server-side cleanup (push unsubscribe, membership removal) is still pending (U9).
/// Workspace id and generation only (no names, no keys, no tokens): the list outlives "Removed from this iPhone" in a backed-up UserDefaults, so it must not say what was removed.
struct ServerCleanupStore {
    private let defaults: UserDefaults
    private static let key = "orch.serverCleanup.pending"
    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> [PendingServerCleanup] {
        guard let data = defaults.data(forKey: Self.key), let items = try? JSONDecoder().decode([PendingServerCleanup].self, from: data) else { return [] }
        return items
    }

    private func save(_ items: [PendingServerCleanup]) {
        if items.isEmpty { defaults.removeObject(forKey: Self.key) }
        else if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.key) }
    }

    @discardableResult
    func add(_ item: PendingServerCleanup) -> [PendingServerCleanup] {
        var items = load().filter { $0.id != item.id }
        items.append(item)
        save(items); return items
    }

    @discardableResult
    func remove(ws: String, generation: Int64? = nil) -> [PendingServerCleanup] {
        let items = load().filter { $0.ws != ws || (generation != nil && $0.generation != generation) }
        save(items); return items
    }

    @discardableResult
    func clear() -> [PendingServerCleanup] { save([]); return [] }
}
