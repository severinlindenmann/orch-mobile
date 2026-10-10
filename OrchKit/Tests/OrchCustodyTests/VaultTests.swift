import Foundation
import Testing
@testable import OrchCustody

func makeVault(_ group: KeychainGroup = .keys, lock: SimulatedLock = SimulatedLock()) -> SecretVault {
    SecretVault(group: group, backend: InMemoryVaultBackend(lock: lock))
}

@Suite struct VaultTests {
    @Test func putGetDeleteRoundTrip() throws {
        let v = makeVault()
        let id = try SecretID(realm: .live, ws: "w1", purpose: "wk.1")
        #expect(try v.contains(id) == false)
        try v.put(Data([1, 2]), for: id)
        #expect(try v.get(id) == Data([1, 2]))
        try v.put(Data([3]), for: id)
        #expect(try v.get(id) == Data([3]))
        try v.delete(id)
        #expect(throws: VaultError.notFound) { try v.get(id) }
        try v.delete(id) // absent: not an error
    }

    @Test func lockedIsNotNotFound() throws {
        let lock = SimulatedLock()
        let v = makeVault(lock: lock)
        let id = try SecretID(realm: .live, purpose: "p")
        try v.put(Data([9]), for: id)
        lock.isLocked = true
        #expect(throws: VaultError.locked) { try v.get(id) }
        lock.isLocked = false
        #expect(try v.get(id) == Data([9]))
    }

    @Test func statusMapping() {
        #expect(KeychainBackend.map(errSecItemNotFound) == .notFound)
        #expect(KeychainBackend.map(errSecInteractionNotAllowed) == .locked)
        #expect(KeychainBackend.map(errSecAuthFailed) == .unexpected(errSecAuthFailed))
    }

    @Test func groupAccessibilityClasses() {
        #expect(KeychainGroup.keys.accessibility == .whenPasscodeSetThisDeviceOnly)
        #expect(KeychainGroup.push.accessibility == .afterFirstUnlockThisDeviceOnly)
        #expect(KeychainGroup.keys.name == "io.severin.orch.keys")
        #expect(KeychainGroup.push.name == "io.severin.orch.push")
    }

    @Test func badNamesRejected() {
        #expect(throws: VaultError.badName) { try SecretID(realm: .live, purpose: "") }
        #expect(throws: VaultError.badName) { try SecretID(realm: .live, ws: "a:b", purpose: "p") }
        #expect(throws: VaultError.badName) { try SecretID(realm: .live, purpose: "a:b") }
    }

    @Test func tagRoundTrip() throws {
        let id = try SecretID(realm: .demo, ws: "w", purpose: "k")
        #expect(SecretID(service: id.service, account: id.account) == id)
        let r = try SecretID(realm: .live, purpose: "dk_sig")
        #expect(SecretID(service: r.service, account: r.account) == r)
        #expect(SecretID(service: "other", account: "x") == nil)
    }

    @Test func wipeWorkspaceAndRealm() throws {
        let v = makeVault()
        for (r, w, p) in [(Realm.live, "a", "k"), (.live, "a", "j"), (.live, "b", "k"), (.live, nil, "dk_sig"), (.demo, "a", "k")] as [(Realm, String?, String)] {
            try v.put(Data([1]), for: SecretID(realm: r, ws: w, purpose: p))
        }
        try v.wipe(realm: .live, ws: "a")
        #expect(try v.ids().count == 3)
        #expect(try v.contains(SecretID(realm: .demo, ws: "a", purpose: "k")))
        try v.wipe(realm: .live)
        #expect(try v.ids() == [SecretID(realm: .demo, ws: "a", purpose: "k")])
    }

    @Test func orphansWithoutIndexAreCleaned() throws {
        let v = makeVault(.push)
        try v.put(Data([1]), for: SecretID(realm: .live, ws: "known", purpose: "k"))
        try v.put(Data([1]), for: SecretID(realm: .live, ws: "stale", purpose: "k"))
        try v.put(Data([1]), for: SecretID(realm: .live, purpose: "realm-level"))
        let removed = try v.wipeUnindexed(realm: .live, knownWorkspaces: ["known"])
        #expect(removed.map(\.ws) == ["stale"])
        #expect(try v.ids().count == 2)
    }

    @Test func demoCannotReadLive() throws {
        let v = makeVault()
        try v.scoped(to: .live).put(Data([7]), ws: "w", purpose: "wk")
        try v.scoped(to: .live).put(Data([8]), purpose: "dk_sig")
        let demo = v.scoped(to: .demo)
        #expect(throws: VaultError.notFound) { try demo.get(ws: "w", purpose: "wk") }
        #expect(throws: VaultError.notFound) { try demo.get(purpose: "dk_sig") }
        try demo.put(Data([1]), ws: "w", purpose: "wk")
        try demo.wipe()
        #expect(try v.scoped(to: .live).get(ws: "w", purpose: "wk") == Data([7]))
        try v.scoped(to: .live).wipe(ws: "w")
        #expect(try v.ids().count == 1)
    }
}
