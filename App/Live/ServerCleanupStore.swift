import Foundation

/// Durable list of workspaces removed locally whose server-side cleanup (push unsubscribe, membership removal) is still pending (U9).
/// Names and ids only: no keys, no tokens.
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
        var items = load().filter { $0.ws != item.ws }
        items.append(item)
        save(items); return items
    }

    @discardableResult
    func remove(ws: String) -> [PendingServerCleanup] {
        let items = load().filter { $0.ws != ws }
        save(items); return items
    }

    @discardableResult
    func clear() -> [PendingServerCleanup] { save([]); return [] }
}
