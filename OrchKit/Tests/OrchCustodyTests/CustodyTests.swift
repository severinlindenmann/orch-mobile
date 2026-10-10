import CryptoKit
import Foundation
import OrchProtocol
import Testing
@testable import OrchCustody

#if targetEnvironment(simulator) || os(macOS)
@Suite struct SoftwareCustodyTests {
    let lock = SimulatedLock()
    let vault: SecretVault
    let custody: SoftwareCustody

    init() {
        vault = makeVault(.keys, lock: lock)
        custody = SoftwareCustody(vault: vault, lock: lock)
    }

    @Test func createSignsAndAgrees() throws {
        let id = try custody.create(realm: .live)
        let msg = Data("hello".utf8)
        let sig = try Signature.sign(id.sig, label: "orch|test|", message: msg)
        #expect(Signature.verify(id.sig.publicKey, signature: sig, label: "orch|test|", message: msg))
        let peer = SoftwareKeyAgreer()
        #expect(try id.kx.sharedSecret(with: peer.publicKey) == peer.sharedSecret(with: id.kx.publicKey))
        #expect(try custody.publicKeys(realm: .live) == id.publicKeys)
        #expect(custody.status(realm: .live) == .present)
    }

    @Test func loadReturnsSameKeys() throws {
        let a = try custody.create(realm: .live)
        let b = try custody.load(realm: .live)
        #expect(a.publicKeys == b.publicKeys)
        #expect(throws: CustodyError.alreadyExists) { try custody.create(realm: .live) }
    }

    @Test func missingFailsClosed() throws {
        #expect(custody.status(realm: .live) == .missing)
        #expect(custody.status(realm: .live).failsClosed)
        #expect(throws: CustodyError.missing) { try custody.load(realm: .live) }
    }

    @Test func halfPresentIsOrphaned() throws {
        _ = try custody.create(realm: .live)
        try vault.delete(SecretID(realm: .live, purpose: "dk_kx"))
        #expect(custody.status(realm: .live) == .orphaned)
        #expect(throws: CustodyError.orphaned) { try custody.load(realm: .live) }
    }

    @Test func garbageBlobIsOrphaned() throws {
        _ = try custody.create(realm: .live)
        try vault.put(Data(repeating: 1, count: 5), for: SecretID(realm: .live, purpose: "dk_sig"))
        #expect(custody.status(realm: .live) == .orphaned)
    }

    @Test func lockedIsNotLost() throws {
        let id = try custody.create(realm: .live)
        lock.isLocked = true
        #expect(custody.status(realm: .live) == .locked)
        #expect(!custody.status(realm: .live).failsClosed)
        #expect(throws: CustodyError.locked) { try custody.load(realm: .live) }
        #expect(throws: CustodyError.locked) { try id.sig.rawSignature(over: Data([1])) }
        #expect(throws: CustodyError.locked) { try id.kx.sharedSecret(with: SoftwareKeyAgreer().publicKey) }
        lock.isLocked = false
        #expect(custody.status(realm: .live) == .present)
        #expect(try custody.load(realm: .live).publicKeys == id.publicKeys)
    }

    @Test func demoRealmIsSeparate() throws {
        let live = try custody.create(realm: .live)
        #expect(custody.status(realm: .demo) == .missing)
        let demo = try custody.create(realm: .demo)
        #expect(demo.publicKeys != live.publicKeys)
        try custody.delete(realm: .demo)
        #expect(custody.status(realm: .demo) == .missing)
        #expect(custody.status(realm: .live) == .present)
    }

    @Test func deleteRemovesBoth() throws {
        _ = try custody.create(realm: .live)
        try custody.delete(realm: .live)
        #expect(custody.status(realm: .live) == .missing)
        #expect(try vault.ids().isEmpty)
    }

    @Test func defaultCustodyIsSoftwareHere() {
        #expect(!DefaultCustody.isSecureEnclave)
    }
}
#endif
