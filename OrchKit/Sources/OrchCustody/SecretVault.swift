import Foundation
import Security
import OrchProtocol

public struct VaultAddress: Hashable, Sendable {
    public let group: KeychainGroup
    public let id: SecretID
}

/// Storage primitive behind `SecretVault`. Two implementations: `KeychainBackend` (Security framework) and
/// `InMemoryVaultBackend` (for `swift test` on macOS).
public protocol VaultBackend: Sendable {
    /// Create or replace.
    func write(_ data: Data, at address: VaultAddress) throws
    /// Add only: throws `VaultError.duplicate` if the item exists. Never replaces.
    func add(_ data: Data, at address: VaultAddress) throws
    func read(_ address: VaultAddress) throws -> Data
    /// Deleting an absent item is not an error.
    func remove(_ address: VaultAddress) throws
    func list(group: KeychainGroup) throws -> [SecretID]
    /// Delete every item of the group, whether or not its tag parses (full reset).
    func removeAll(group: KeychainGroup) throws
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
    /// Add-only put: throws `VaultError.duplicate` instead of replacing.
    public func putNew(_ data: Data, for id: SecretID) throws { try backend.add(data, at: VaultAddress(group: group, id: id)) }
    public func get(_ id: SecretID) throws -> Data { try backend.read(VaultAddress(group: group, id: id)) }
    public func delete(_ id: SecretID) throws { try backend.remove(VaultAddress(group: group, id: id)) }
    public func contains(_ id: SecretID) throws -> Bool {
        do { _ = try get(id); return true } catch VaultError.notFound { return false }
    }

    /// Full reset: remove every item in this group, including leftovers whose tag cannot be parsed.
    public func resetAll() throws { try backend.removeAll(group: group) }

    public func ids() throws -> [SecretID] { try backend.list(group: group) }

    /// Remove every item of one workspace in one realm (not realm-level items such as device keys).
    public func wipe(realm: Realm, ws: String) throws {
        for id in try ids() where id.realm == realm && id.ws == ws { try delete(id) }
    }

    /// Remove everything of a realm in this group, device keys included, EXCEPT the hub pairing (`hub.<hub_id>.*`, D-B1): a direct-mode
    /// wipe (first Live entry, Leave Live, an interrupted reset) never removes it. Only `HubKeyCustody.deleteAll` and
    /// `wipeHubItems` (Reset this iPhone) do.
    public func wipe(realm: Realm) throws {
        for id in try ids() where id.realm == realm && !Self.isHubItem(id) { try delete(id) }
    }

    /// Items of the hub pairing namespace.
    public static func isHubItem(_ id: SecretID) -> Bool { id.ws == nil && id.purpose.hasPrefix("hub.") }

    /// Remove every hub pairing item of a realm in this group ("Reset this iPhone" only).
    public func wipeHubItems(realm: Realm) throws {
        for id in try ids() where id.realm == realm && Self.isHubItem(id) { try delete(id) }
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
    public func scoped(to realm: Realm) -> RealmVault { RealmVault(realm: realm, vault: self, fence: nil) }
    /// A realm view whose `put` runs inside `fence` from the start.
    public func scoped(to realm: Realm, fence: any WriteFence) -> RealmVault { RealmVault(realm: realm, vault: self, fence: fence) }
}

public struct RealmVault: Sendable {
    public let realm: Realm
    let vault: SecretVault
    let fence: (any WriteFence)?

    /// The same view with every `put` running inside the realm fence (check and keychain write are one step against invalidation).
    
    /// A view already bound to another fence is refused (`VaultError.fenceMismatch`).
    public func fenced(by f: any WriteFence) throws -> RealmVault {
        if let fence, fence !== f { throw VaultError.fenceMismatch }
        return RealmVault(realm: realm, vault: vault, fence: f)
    }

    public func put(_ data: Data, ws: String? = nil, purpose: String) throws {
        let id = try SecretID(realm: realm, ws: ws, purpose: purpose)
        try fenced { try vault.put(data, for: id) }
    }
    public func get(ws: String? = nil, purpose: String) throws -> Data {
        try vault.get(SecretID(realm: realm, ws: ws, purpose: purpose))
    }
    /// Deletes and wipes are fenced like puts: a participant (session, coordinator) that outlives its realm, for example past the shutdown
    /// deadline, must not remove a successor realm's items, whose ids (the device certificate, a re-paired workspace) are the same.
    /// Only the reset/teardown path, which holds an unfenced view (`SecretVault.scoped(to:)`), removes after invalidation.
    public func delete(ws: String? = nil, purpose: String) throws {
        let id = try SecretID(realm: realm, ws: ws, purpose: purpose)
        try fenced { try vault.delete(id) }
    }
    /// Deletes one listed item (it must belong to this realm).
    public func delete(item: SecretID) throws {
        guard item.realm == realm else { throw VaultError.badName }
        try fenced { try vault.delete(item) }
    }
    public func wipe(ws: String) throws { try fenced { try vault.wipe(realm: realm, ws: ws) } }
    public func wipe() throws { try fenced { try vault.wipe(realm: realm) } }
    private func fenced<T>(_ body: () throws -> T) throws -> T {
        guard let fence else { return try body() }
        return try fence.performFenced(body)
    }
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
    public func add(_ data: Data, at a: VaultAddress) throws {
        try check()
        try mutex.withLock {
            guard items[a] == nil else { throw VaultError.duplicate }
            items[a] = data
        }
    }
    public func removeAll(group: KeychainGroup) throws {
        try check(); mutex.withLock { items = items.filter { $0.key.group != group } }
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

/// The real keychain. Every query carries an explicit access group (`<team prefix>io.severin.orch.<group>`), so
/// `.keys` and `.push` can never merge. The prefix comes from the `OrchAppIdentifierPrefix` Info.plist key
/// (`$(AppIdentifierPrefix)` at build time); without it there is no backend (fail closed).
public struct KeychainBackend: VaultBackend {
    let prefix: String?
    /// The access-group name before the group suffix: `io.severin.orch` for the app, `io.severin.orch.devsandbox` for the Simulator
    /// dev-sandbox variant (its keys are never in the normal app's keychain group).
    let base: String

    /// `prefix` is the team id with its trailing dot, e.g. `"77D4THRYUN."`.
    public init(accessGroupPrefix prefix: String, groupBase base: String = KeychainBackend.defaultBase) {
        precondition(Self.validPrefix(prefix), "access group prefix must look like TEAMID.")
        precondition(Self.validBase(base), "access group base must be io.severin.orch[.name]")
        self.prefix = prefix
        self.base = base
    }

    public static let defaultBase = "io.severin.orch"

    static func validBase(_ b: String) -> Bool {
        guard b == defaultBase || b.hasPrefix(defaultBase + ".") else { return false }
        return b.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E }
    }

    func groupName(_ group: KeychainGroup) -> String { base + "." + group.rawValue }

    static func validPrefix(_ p: String) -> Bool {
        let u = Array(p.utf8)
        return u.count > 1 && u.last == 0x2E && u.dropLast().allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
        }
    }

    /// Reads `OrchAppIdentifierPrefix` from the bundle. Nil when absent or unresolved: callers must then treat
    /// custody as unavailable rather than guess a group.
    public static func fromBundle(_ bundle: Bundle = .main) -> KeychainBackend? {
        guard let p = bundle.object(forInfoDictionaryKey: "OrchAppIdentifierPrefix") as? String, validPrefix(p) else { return nil }
        // optional: the variant's own group base; a malformed one is no backend at all (fail closed), never the default
        if let b = bundle.object(forInfoDictionaryKey: "OrchKeychainGroupBase") {
            guard let base = b as? String, validBase(base) else { return nil }
            return KeychainBackend(accessGroupPrefix: p, groupBase: base)
        }
        return KeychainBackend(accessGroupPrefix: p)
    }

    #if DEBUG
    /// TEST-ONLY: no access group in the query (the app's default group). Not compiled into Release.
    public init(unscopedForTests: Void) { prefix = nil; base = Self.defaultBase }
    #endif

    /// `errSecInteractionNotAllowed` is the only "locked" status; `errSecItemNotFound` the only "not found".
    static func map(_ status: OSStatus) -> VaultError {
        switch status {
        case errSecItemNotFound: .notFound
        case errSecInteractionNotAllowed: .locked
        case errSecDuplicateItem: .duplicate
        default: .unexpected(status)
        }
    }

    static func cfAccessible(_ a: Accessibility) -> CFString {
        switch a {
        case .whenPasscodeSetThisDeviceOnly: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    func groupQuery(_ group: KeychainGroup) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword]
        if let p = prefix { q[kSecAttrAccessGroup] = p + groupName(group) }
        #if os(macOS)
        q[kSecUseDataProtectionKeychain] = true
        #endif
        return q
    }

    func baseQuery(_ a: VaultAddress) -> [CFString: Any] {
        var q = groupQuery(a.group)
        q[kSecAttrService] = a.id.service
        q[kSecAttrAccount] = a.id.account
        q[kSecAttrSynchronizable] = false
        return q
    }

    public func add(_ data: Data, at a: VaultAddress) throws {
        var q = baseQuery(a)
        q[kSecValueData] = data
        q[kSecAttrAccessible] = Self.cfAccessible(a.group.accessibility)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.map(status) }
    }

    public func write(_ data: Data, at a: VaultAddress) throws {
        do { try add(data, at: a) }
        catch VaultError.duplicate {
            let attrs: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: Self.cfAccessible(a.group.accessibility)]
            let status = SecItemUpdate(baseQuery(a) as CFDictionary, attrs as CFDictionary)
            guard status == errSecSuccess else { throw Self.map(status) }
        }
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

    public func removeAll(group: KeychainGroup) throws {
        var q = groupQuery(group)
        q[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.map(status) }
    }

    public func list(group: KeychainGroup) throws -> [SecretID] {
        var q = groupQuery(group)
        q[kSecAttrSynchronizable] = false
        q[kSecReturnAttributes] = true
        q[kSecMatchLimit] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Self.map(status) }
        let rows = out as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let s = row[kSecAttrService as String] as? String, let acc = row[kSecAttrAccount as String] as? String else { return nil }
            if prefix == nil, let g = row[kSecAttrAccessGroup as String] as? String, !g.hasSuffix(groupName(group)) { return nil }
            return SecretID(service: s, account: acc)
        }
    }
}
