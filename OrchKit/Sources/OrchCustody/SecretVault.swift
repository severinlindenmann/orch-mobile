import Foundation
import Security

public struct VaultAddress: Hashable, Sendable {
    public let group: KeychainGroup
    public let id: SecretID
}

/// Storage primitive behind `SecretVault`. Two implementations: `KeychainBackend` (Security framework) and
/// `InMemoryVaultBackend` (for `swift test` on macOS).
public protocol VaultBackend: Sendable {
    func write(_ data: Data, at address: VaultAddress) throws
    func read(_ address: VaultAddress) throws -> Data
    /// Deleting an absent item is not an error.
    func remove(_ address: VaultAddress) throws
    func list(group: KeychainGroup) throws -> [SecretID]
}

/// A simulated device lock for software custody and the in-memory vault (Simulator and macOS tests).
public final class SimulatedLock: @unchecked Sendable {
    private let mutex = NSLock()
    private var locked = false
    public init(locked: Bool = false) { self.locked = locked }
    public var isLocked: Bool {
        get { mutex.withLock { locked } }
        set { mutex.withLock { locked = newValue } }
    }
}

/// Typed keychain wrapper. Every item is tagged `(realm, ws?, purpose)`, non-synchronizable, in a group whose
/// accessibility class is fixed by the group.
public struct SecretVault: Sendable {
    public let group: KeychainGroup
    let backend: any VaultBackend

    public init(group: KeychainGroup, backend: any VaultBackend) {
        self.group = group; self.backend = backend
    }

    public func put(_ data: Data, for id: SecretID) throws { try backend.write(data, at: VaultAddress(group: group, id: id)) }
    public func get(_ id: SecretID) throws -> Data { try backend.read(VaultAddress(group: group, id: id)) }
    public func delete(_ id: SecretID) throws { try backend.remove(VaultAddress(group: group, id: id)) }
    public func contains(_ id: SecretID) throws -> Bool {
        do { _ = try get(id); return true } catch VaultError.notFound { return false }
    }

    public func ids() throws -> [SecretID] { try backend.list(group: group) }

    /// Remove every item of one workspace in one realm (not realm-level items such as device keys).
    public func wipe(realm: Realm, ws: String) throws {
        for id in try ids() where id.realm == realm && id.ws == ws { try delete(id) }
    }

    /// Remove everything of a realm in this group, device keys included.
    public func wipe(realm: Realm) throws {
        for id in try ids() where id.realm == realm { try delete(id) }
    }

    /// Launch cleanup (U9): remove workspace items whose workspace is not in the realm index (left over after a
    /// reinstall or an interrupted leave). Realm-level items (no `ws`) are kept. Returns what was removed.
    @discardableResult
    public func wipeUnindexed(realm: Realm, knownWorkspaces: Set<String>) throws -> [SecretID] {
        var removed: [SecretID] = []
        for id in try ids() where id.realm == realm {
            if let ws = id.ws, !knownWorkspaces.contains(ws) { try delete(id); removed.append(id) }
        }
        return removed
    }

    /// A view that can only address one realm: what Demo code receives, so it cannot name a live item.
    public func scoped(to realm: Realm) -> RealmVault { RealmVault(realm: realm, vault: self) }
}

public struct RealmVault: Sendable {
    public let realm: Realm
    let vault: SecretVault

    public func put(_ data: Data, ws: String? = nil, purpose: String) throws {
        try vault.put(data, for: SecretID(realm: realm, ws: ws, purpose: purpose))
    }
    public func get(ws: String? = nil, purpose: String) throws -> Data {
        try vault.get(SecretID(realm: realm, ws: ws, purpose: purpose))
    }
    public func delete(ws: String? = nil, purpose: String) throws {
        try vault.delete(SecretID(realm: realm, ws: ws, purpose: purpose))
    }
    public func wipe(ws: String) throws { try vault.wipe(realm: realm, ws: ws) }
    public func wipe() throws { try vault.wipe(realm: realm) }
}

// MARK: in-memory

public final class InMemoryVaultBackend: VaultBackend, @unchecked Sendable {
    private let mutex = NSLock()
    private var items: [VaultAddress: Data] = [:]
    public let lock: SimulatedLock

    public init(lock: SimulatedLock = SimulatedLock()) { self.lock = lock }

    private func check() throws { if lock.isLocked { throw VaultError.locked } }

    public func write(_ data: Data, at a: VaultAddress) throws {
        try check(); mutex.withLock { items[a] = data }
    }
    public func read(_ a: VaultAddress) throws -> Data {
        try check()
        guard let d = mutex.withLock({ items[a] }) else { throw VaultError.notFound }
        return d
    }
    public func remove(_ a: VaultAddress) throws { try check(); mutex.withLock { items[a] = nil } }
    public func list(group: KeychainGroup) throws -> [SecretID] {
        try check()
        return mutex.withLock { items.keys.filter { $0.group == group }.map(\.id) }
    }
}

// MARK: Security framework

/// The real keychain. `accessGroupPrefix` is the team prefix with its dot (`"77D4THRYUN."`); `nil` uses the
/// app's default access group (hosted tests, where the prefix is unknown).
public struct KeychainBackend: VaultBackend {
    public let accessGroupPrefix: String?

    public init(accessGroupPrefix: String?) { self.accessGroupPrefix = accessGroupPrefix }

    /// `errSecInteractionNotAllowed` is the only "locked" status; `errSecItemNotFound` the only "not found".
    static func map(_ status: OSStatus) -> VaultError {
        switch status {
        case errSecItemNotFound: .notFound
        case errSecInteractionNotAllowed: .locked
        default: .unexpected(status)
        }
    }

    static func cfAccessible(_ a: Accessibility) -> CFString {
        switch a {
        case .whenPasscodeSetThisDeviceOnly: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    func baseQuery(_ a: VaultAddress) -> [CFString: Any] {
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: a.id.service,
            kSecAttrAccount: a.id.account,
            kSecAttrSynchronizable: false,
        ]
        if let p = accessGroupPrefix { q[kSecAttrAccessGroup] = p + a.group.name }
        #if os(macOS)
        q[kSecUseDataProtectionKeychain] = true
        #endif
        return q
    }

    public func write(_ data: Data, at a: VaultAddress) throws {
        var add = baseQuery(a)
        add[kSecValueData] = data
        add[kSecAttrAccessible] = Self.cfAccessible(a.group.accessibility)
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(baseQuery(a) as CFDictionary, [kSecValueData: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Self.map(status) }
    }

    public func read(_ a: VaultAddress) throws -> Data {
        var q = baseQuery(a)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess else { throw Self.map(status) }
        guard let d = out as? Data else { throw VaultError.unexpected(errSecDecode) }
        return d
    }

    public func remove(_ a: VaultAddress) throws {
        let status = SecItemDelete(baseQuery(a) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.map(status) }
    }

    public func list(group: KeychainGroup) throws -> [SecretID] {
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrSynchronizable: false,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        if let p = accessGroupPrefix { q[kSecAttrAccessGroup] = p + group.name }
        #if os(macOS)
        q[kSecUseDataProtectionKeychain] = true
        #endif
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Self.map(status) }
        let rows = out as? [[String: Any]] ?? []
        // With no explicit access group the query spans every group of the app, so filter by the stored group
        // when the prefix is unknown only by the item tag; hosted tests use a single group per test run.
        return rows.compactMap { row in
            guard let s = row[kSecAttrService as String] as? String, let acc = row[kSecAttrAccount as String] as? String else { return nil }
            if accessGroupPrefix == nil, let g = row[kSecAttrAccessGroup as String] as? String, !g.hasSuffix(group.name) { return nil }
            return SecretID(service: s, account: acc)
        }
    }

    /// The team prefix of the running app (`"TEAMID."`), found by asking the keychain which group a fresh item
    /// lands in. `nil` when the process has no keychain entitlement.
    public static func discoverAccessGroupPrefix() -> String? {
        let probe: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "orch:probe",
            kSecAttrAccount: "prefix",
            kSecAttrSynchronizable: false,
        ]
        SecItemDelete(probe as CFDictionary)
        var add = probe
        add[kSecValueData] = Data([0])
        add[kSecReturnAttributes] = true
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var out: CFTypeRef?
        defer { SecItemDelete(probe as CFDictionary) }
        guard SecItemAdd(add as CFDictionary, &out) == errSecSuccess,
              let g = (out as? [String: Any])?[kSecAttrAccessGroup as String] as? String,
              let dot = g.firstIndex(of: ".") else { return nil }
        return String(g[...dot])
    }
}
