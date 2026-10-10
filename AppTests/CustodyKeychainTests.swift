import CryptoKit
import OrchCustody
import OrchProtocol
import XCTest

/// Hosted tests against the real keychain (simulator). They need the app's keychain entitlements, so the test
/// run must be ad-hoc signed (CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES), see .github/workflows/ci.yml.
/// The Secure Enclave itself does not exist in the Simulator: see the SE checklist in the M3a report.
final class CustodyKeychainTests: XCTestCase {
    var prefix: String?

    override func setUpWithError() throws {
        prefix = KeychainBackend.discoverAccessGroupPrefix()
        try XCTSkipIf(prefix == nil, "no keychain entitlement in this test host (build was not signed with entitlements)")
        for g in KeychainGroup.allCases {
            let v = SecretVault(group: g, backend: KeychainBackend(accessGroupPrefix: prefix))
            for r in Realm.allCases { try v.wipe(realm: r) }
        }
    }

    override func tearDownWithError() throws {
        guard prefix != nil else { return }
        for g in KeychainGroup.allCases {
            let v = SecretVault(group: g, backend: KeychainBackend(accessGroupPrefix: prefix))
            for r in Realm.allCases { try v.wipe(realm: r) }
        }
    }

    func vault(_ g: KeychainGroup) -> SecretVault { SecretVault(group: g, backend: KeychainBackend(accessGroupPrefix: prefix)) }

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
