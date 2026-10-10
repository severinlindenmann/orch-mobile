import CryptoKit
import Security
@testable import OrchCustody
@testable import OrchProtocol
import XCTest

/// Hosted tests against the real keychain (simulator). They need the app's keychain entitlements, so the test
/// run must be ad-hoc signed (CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES), see .github/workflows/ci.yml.
/// The Secure Enclave itself does not exist in the Simulator: see the SE checklist in the M3a report.
final class CustodyKeychainTests: XCTestCase {
    var backend: KeychainBackend!

    override func setUpWithError() throws {
        guard let b = KeychainBackend.fromBundle(.main) else {
            // On CI a missing entitlement prefix must fail the run, not hide the keychain tests.
            if ProcessInfo.processInfo.environment["CI"] != nil {
                XCTFail("no OrchAppIdentifierPrefix in the test host: keychain tests cannot run")
            }
            throw XCTSkip("no OrchAppIdentifierPrefix / keychain entitlement in this test host")
        }
        backend = b
        try resetAll()
    }

    override func tearDownWithError() throws { if backend != nil { try resetAll() } }

    func resetAll() throws { for g in KeychainGroup.allCases { try SecretVault(group: g, backend: backend).resetAll() } }

    func vault(_ g: KeychainGroup) -> SecretVault { SecretVault(group: g, backend: backend) }

    func testConcurrentCreateOnRealKeychain() throws {
        let custody = DefaultCustody.make(vault: vault(.keys))
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            do { let id = try custody.create(realm: .live); box.win(id.publicKeys) }
            catch CustodyError.alreadyExists { box.lose() }
            catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(box.wins.count, 1)
        XCTAssertEqual(box.losses, 5)
        XCTAssertEqual(try custody.load(realm: .live).publicKeys, box.wins.first)
    }

    func testUpdateKeepsAccessibilityAndResetRemovesUnparseable() throws {
        let v = vault(.keys)
        let id = try SecretID(realm: .live, purpose: "k")
        try v.put(Data([1]), for: id)
        try v.put(Data([2]), for: id)
        var q = backend.groupQuery(.keys)
        q[kSecAttrService] = id.service; q[kSecAttrAccount] = id.account
        q[kSecReturnAttributes] = true
        var out: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(q as CFDictionary, &out), errSecSuccess)
        let attrs = out as? [String: Any]
        XCTAssertEqual(attrs?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
        // A leftover whose tag does not parse is invisible to ids() but must go on a full reset.
        var junk = backend.groupQuery(.keys)
        junk[kSecAttrService] = "legacy"; junk[kSecAttrAccount] = "Junk"; junk[kSecValueData] = Data([9])
        junk[kSecAttrAccessible] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        XCTAssertEqual(SecItemAdd(junk as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(try v.ids(), [id])
        try v.resetAll()
        var all = backend.groupQuery(.keys)
        all[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
        all[kSecReturnAttributes] = true
        all[kSecMatchLimit] = kSecMatchLimitAll
        XCTAssertEqual(SecItemCopyMatching(all as CFDictionary, nil), errSecItemNotFound)
    }

    func testRoundTripInBothGroups() throws {
        for g in KeychainGroup.allCases {
            let v = vault(g)
            let id = try SecretID(realm: .live, ws: "11111111111111111111111111111111", purpose: "k")
            XCTAssertThrowsError(try v.get(id)) { XCTAssertEqual($0 as? VaultError, .notFound) }
            try v.put(Data([1, 2, 3]), for: id)
            try v.put(Data([4]), for: id) // update path
            XCTAssertEqual(try v.get(id), Data([4]))
            XCTAssertEqual(try v.ids(), [id])
            try v.delete(id)
            XCTAssertThrowsError(try v.get(id)) { XCTAssertEqual($0 as? VaultError, .notFound) }
            try v.delete(id)
        }
    }

    func testGroupsAreSeparate() throws {
        let id = try SecretID(realm: .live, ws: "22222222222222222222222222222222", purpose: "k")
        try vault(.push).put(Data([1]), for: id)
        XCTAssertThrowsError(try vault(.keys).get(id)) { XCTAssertEqual($0 as? VaultError, .notFound) }
        XCTAssertEqual(try vault(.keys).ids(), [])
    }

    func testDemoCannotReadLive() throws {
        let v = vault(.keys)
        try v.scoped(to: .live).put(Data([7]), ws: "22222222222222222222222222222222", purpose: "wk")
        XCTAssertThrowsError(try v.scoped(to: .demo).get(ws: "22222222222222222222222222222222", purpose: "wk"))
        try v.scoped(to: .demo).put(Data([1]), ws: "22222222222222222222222222222222", purpose: "wk")
        try v.scoped(to: .demo).wipe()
        XCTAssertEqual(try v.scoped(to: .live).get(ws: "22222222222222222222222222222222", purpose: "wk"), Data([7]))
    }

    func testWipeAndOrphanCleanup() throws {
        let v = vault(.push)
        try v.put(Data([1]), for: SecretID(realm: .live, ws: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", purpose: "k"))
        try v.put(Data([1]), for: SecretID(realm: .live, ws: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", purpose: "k"))
        try v.wipe(realm: .live, ws: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(try v.ids().count, 1)
        XCTAssertEqual(try v.wipeUnindexed(realm: .live, knownWorkspaces: []).count, 1)
        XCTAssertEqual(try v.ids().count, 0)
    }

    func testDeviceCustodyOnSimulator() throws {
        XCTAssertFalse(DefaultCustody.isSecureEnclave)
        let custody = DefaultCustody.make(vault: vault(.keys))
        XCTAssertEqual(custody.status(realm: .live), .missing)
        let id = try custody.create(realm: .live)
        XCTAssertEqual(custody.status(realm: .live), .present)
        let sig = try Signature.sign(id.sig, label: "orch|t|", message: Data([1]))
        XCTAssertTrue(Signature.verify(id.sig.publicKey, signature: sig, label: "orch|t|", message: Data([1])))
        XCTAssertEqual(try custody.load(realm: .live).publicKeys, id.publicKeys)
        try custody.delete(realm: .live)
        XCTAssertEqual(custody.status(realm: .live), .missing)
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _wins: [DevicePublicKeys] = [], _losses = 0
    var wins: [DevicePublicKeys] { lock.withLock { _wins } }
    var losses: Int { lock.withLock { _losses } }
    func win(_ k: DevicePublicKeys) { lock.withLock { _wins.append(k) } }
    func lose() { lock.withLock { _losses += 1 } }
}
