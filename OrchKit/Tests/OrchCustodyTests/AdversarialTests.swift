import CryptoKit
import Foundation
import OrchProtocol
import Security
import Testing
@testable import OrchCustody

/// Wraps the in-memory backend to inject read and write failures.
final class FlakyBackend: VaultBackend, @unchecked Sendable {
    let inner = InMemoryVaultBackend()
    private let mutex = NSLock()
    private var _failReads: VaultError?
    private var _failWritesFor: String?
    var failReadsWith: VaultError? { get { mutex.withLock { _failReads } } set { mutex.withLock { _failReads = newValue } } }
    var failWritesForPurpose: String? { get { mutex.withLock { _failWritesFor } } set { mutex.withLock { _failWritesFor = newValue } } }

    func write(_ d: Data, at a: VaultAddress) throws { try inner.write(d, at: a) }
    func add(_ d: Data, at a: VaultAddress) throws {
        if failWritesForPurpose == a.id.purpose { throw VaultError.unexpected(-1) }
        try inner.add(d, at: a)
    }
    func read(_ a: VaultAddress) throws -> Data { if let e = failReadsWith { throw e }; return try inner.read(a) }
    func remove(_ a: VaultAddress) throws { try inner.remove(a) }
    func list(group: KeychainGroup) throws -> [SecretID] { try inner.list(group: group) }
    func removeAll(group: KeychainGroup) throws { try inner.removeAll(group: group) }
}

#if targetEnvironment(simulator) || os(macOS)
@Suite struct Adversarial {
    // An unknown keychain status is "cannot tell", never "lost": no cleanup may follow.
    @Test func unexpectedStatusIsUnavailableNotOrphaned() throws {
        let b = FlakyBackend()
        let c = SoftwareCustody(vault: SecretVault(group: .keys, backend: b))
        _ = try c.create(realm: .live)
        b.failReadsWith = .unexpected(-25291)
        let s = c.status(realm: .live)
        #expect(s == .unavailable)
        #expect(!s.failsClosed)
        b.failReadsWith = nil
        #expect(c.status(realm: .live) == .present)
    }

    @Test func restoreErrorClassification() {
        let v = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let store = KeyBlobStore(vault: v)
        let r = Realm.live
        try? v.put(Data([1]), for: SecretID(realm: r, purpose: "dk_sig"))
        try? v.put(Data([2]), for: SecretID(realm: r, purpose: "dk_kx"))
        struct Other: Error {}
        #expect(store.status(r) { _, _ in throw Other() } == .unavailable)
        #expect(store.status(r) { _, _ in throw CustodyError.unavailable } == .unavailable)
        #expect(store.status(r) { _, _ in throw CustodyError.orphaned } == .orphaned)
        #expect(store.status(r) { _, _ in throw CustodyError.locked } == .locked)
        #expect(store.status(r) { _, _ in } == .present)
    }

    @Test func concurrentCreateExactlyOneWins() throws {
        for _ in 0..<200 {
            let c = SoftwareCustody(vault: SecretVault(group: .keys, backend: InMemoryVaultBackend()))
            let results = Locked<[Data]>([])
            let failures = Locked<[Error]>([])
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                do { let id = try c.create(realm: .live); results.mutate { $0.append(id.publicKeys.sig.x963) } }
                catch { failures.mutate { $0.append(error) } }
            }
            #expect(results.value.count == 1)
            #expect(failures.value.allSatisfy { ($0 as? CustodyError) == .alreadyExists })
            #expect(try c.load(realm: .live).publicKeys.sig.x963 == results.value[0])
        }
    }

    @Test func createRollsBackWhenSecondWriteFails() throws {
        let b = FlakyBackend()
        let v = SecretVault(group: .keys, backend: b)
        let c = SoftwareCustody(vault: v)
        b.failWritesForPurpose = "dk_kx"
        #expect(throws: CustodyError.self) { try c.create(realm: .live) }
        #expect(try v.ids().isEmpty)
        #expect(c.status(realm: .live) == .missing)
        b.failWritesForPurpose = nil
        _ = try c.create(realm: .live)
        #expect(c.status(realm: .live) == .present)
    }

    @Test func createNeverOverwritesExistingKey() throws {
        let v = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let c = SoftwareCustody(vault: v)
        let first = try c.create(realm: .live)
        // Only the kx blob is missing: create must refuse, not replace the surviving sig key.
        try v.delete(SecretID(realm: .live, purpose: "dk_kx"))
        #expect(throws: CustodyError.alreadyExists) { try c.create(realm: .live) }
        #expect(try v.get(SecretID(realm: .live, purpose: "dk_sig")).count == 32)
        _ = first
    }

    @Test func keyMaterialNotInDescriptions() throws {
        let v = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let c = SoftwareCustody(vault: v)
        let id = try c.create(realm: .live)
        let raw = try v.get(SecretID(realm: .live, purpose: "dk_sig"))
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        var dumped = ""; dump(id, to: &dumped)
        let s = String(describing: id) + String(reflecting: id) + dumped
        #expect(!s.contains(hex))
    }

    @Test func nilPrefixIsDebugOnlyAndPrefixValidated() throws {
        #expect(KeychainBackend.validPrefix("77D4THRYUN."))
        #expect(!KeychainBackend.validPrefix(""))
        #expect(!KeychainBackend.validPrefix("."))
        #expect(!KeychainBackend.validPrefix("77D4THRYUN"))
        #expect(!KeychainBackend.validPrefix("$(AppIdentifierPrefix)"))
        let k = KeychainBackend(accessGroupPrefix: "77D4THRYUN.")
        for g in KeychainGroup.allCases {
            let q = k.baseQuery(VaultAddress(group: g, id: try SecretID(realm: .live, purpose: "x")))
            #expect(q[kSecAttrAccessGroup] as? String == "77D4THRYUN." + g.name)
        }
        #expect(KeychainBackend.fromBundle(Bundle(for: BundleToken.self)) == nil)
    }

    @Test func orphanCleanupScope() throws {
        let v = SecretVault(group: .push, backend: InMemoryVaultBackend())
        let a = String(repeating: "a", count: 32)
        try v.put(Data([1]), for: SecretID(realm: .live, purpose: "dk_sig"))
        try v.put(Data([1]), for: SecretID(realm: .demo, ws: a, purpose: "k"))
        try v.put(Data([1]), for: SecretID(realm: .live, ws: a, purpose: "k"))
        let removed = try v.wipeUnindexed(realm: .live, knownWorkspaces: [])
        #expect(removed.count == 1)
        #expect(try v.ids().count == 2)
    }

    @Test func resetAllRemovesEverythingInGroup() throws {
        let b = InMemoryVaultBackend()
        let keys = SecretVault(group: .keys, backend: b), push = SecretVault(group: .push, backend: b)
        try keys.put(Data([1]), for: SecretID(realm: .live, purpose: "a"))
        try keys.put(Data([1]), for: SecretID(realm: .demo, purpose: "a"))
        try push.put(Data([1]), for: SecretID(realm: .live, purpose: "a"))
        try keys.resetAll()
        #expect(try keys.ids().isEmpty)
        #expect(try push.ids().count == 1)
    }

    @Test func addOnlyThrowsDuplicate() throws {
        let v = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let id = try SecretID(realm: .live, purpose: "a")
        try v.putNew(Data([1]), for: id)
        #expect(throws: VaultError.duplicate) { try v.putNew(Data([2]), for: id) }
        #expect(try v.get(id) == Data([1]))
    }

    @Test func secureEnclaveLockErrorMapping() {
        #expect(mapSecureEnclaveError(CryptoKitError.underlyingCoreCryptoError(error: errSecInteractionNotAllowed)) as? CustodyError == .locked)
        let ns = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))
        #expect(mapSecureEnclaveError(ns) as? CustodyError == .locked)
        #expect(mapSecureEnclaveError(CryptoKitError.incorrectKeySize) as? CryptoKitError == .incorrectKeySize)
    }
}

final class BundleToken {}

final class Locked<T>: @unchecked Sendable {
    private let m = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { m.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { m.withLock { f(&v) } }
}
#endif
