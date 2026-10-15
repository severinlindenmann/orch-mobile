import Foundation
import OrchCustody

/// Durable list of workspaces removed locally whose server-side cleanup (push unsubscribe, membership removal) is still pending (U9).
/// Workspace id and generation only (no names, no keys, no tokens): the list outlives "Removed from this iPhone" in a backed-up UserDefaults, so it must not say what was removed.
struct ServerCleanupStore {
    private let defaults: UserDefaults
    let realm: Realm
    /// One list per realm: a Demo cleanup must never be retried against Live, nor a Live one cleared by leaving Demo.
    private var key: String { "orch.serverCleanup.pending." + realm.rawValue }
    /// Before realms were separated the single list could only hold Demo entries; it is adopted by the Demo list once.
    private static let legacyKey = "orch.serverCleanup.pending"
    init(defaults: UserDefaults, realm: Realm = .demo) {
        self.defaults = defaults; self.realm = realm
        if realm == .demo, let legacy = defaults.data(forKey: Self.legacyKey) {
            if defaults.data(forKey: key) == nil { defaults.set(legacy, forKey: key) }
            defaults.removeObject(forKey: Self.legacyKey)
        }
    }

    func load() -> [PendingServerCleanup] {
        guard let data = defaults.data(forKey: key), let items = try? JSONDecoder().decode([PendingServerCleanup].self, from: data) else { return [] }
        return items
    }

    private func save(_ items: [PendingServerCleanup]) {
        if items.isEmpty { defaults.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: key) }
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
