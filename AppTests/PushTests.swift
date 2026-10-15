import Foundation
@testable import OrchCustody
import OrchProtocol
@testable import OrchPush
import XCTest
@testable import Orch

/// Hosted tests against the real keychain and App Group of the simulator host app (ad-hoc signed with the app's
/// entitlements, like CustodyKeychainTests).
#if DEBUG // VaultPushSink(backend:realm:) is DEBUG-only; the Release flag check compiles all tests
final class PushAppTests: XCTestCase {
    var backend: KeychainBackend!
    let a = PushFixtures.workspaceA

    override func setUpWithError() throws {
        guard let b = KeychainBackend.fromBundle(.main), KeychainPushMaterialSource.fromBundle(.main) != nil else {
            if ProcessInfo.processInfo.environment["CI"] != nil { XCTFail("no OrchAppIdentifierPrefix in the test host") }
            throw XCTSkip("no OrchAppIdentifierPrefix / keychain entitlement in this test host")
        }
        backend = b
        try SecretVault(group: .push, backend: b).resetAll()
    }

    override func tearDownWithError() throws { if backend != nil { try SecretVault(group: .push, backend: backend).resetAll() } }

    private func publish(realm: String = "live", ws: ID16? = nil, generation: Int64 = 1) throws {
        let material = try PushMaterial.decode(PushFixtures.materialJSON(a, generation: generation))
        try PushMaterialPublisher(sink: VaultPushSink(backend: backend, realm: Realm(rawValue: realm)!), realm: realm).publish(workspace: ws ?? a.id, material: material)
    }

    /// The tag format custody writes and the extension's reader parses must stay identical.
    func testPublisherAndExtensionReaderAgreeOnTheKeychainItem() throws {
        try publish()
        let loaded = try KeychainPushMaterialSource.fromBundle(.main)!.loadAll(realm: "live")
        XCTAssertEqual(loaded.keys.map(\.hex), [a.id.hex])
        XCTAssertEqual(loaded[a.id], try PushMaterial.decode(PushFixtures.materialJSON(a)))
        // protection class of the item: readable after first unlock, this device only (A9)
        var q = backend.groupQuery(.push)
        q[kSecAttrAccount] = PushMaterial.purpose; q[kSecReturnAttributes] = true
        var out: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(q as CFDictionary, &out), errSecSuccess)
        XCTAssertEqual((out as? [String: Any])?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testReaderIsRealmScopedAndPushGroupOnly() throws {
        try publish(realm: "demo")
        XCTAssertTrue(try KeychainPushMaterialSource.fromBundle(.main)!.loadAll(realm: "live").isEmpty, "demo material is invisible to the live extension")
        // an item with the same tag in the keys group is not push material
        try SecretVault(group: .keys, backend: backend).put(PushFixtures.materialJSON(a), for: SecretID(realm: .live, ws: a.id.hex, purpose: PushMaterial.purpose))
        defer { try? SecretVault(group: .keys, backend: backend).resetAll() }
        XCTAssertTrue(try KeychainPushMaterialSource.fromBundle(.main)!.loadAll(realm: "live").isEmpty)
        // a corrupt item is skipped, not fatal
        try SecretVault(group: .push, backend: backend).put(Data("junk".utf8), for: SecretID(realm: .live, ws: a.id.hex, purpose: PushMaterial.purpose))
        XCTAssertTrue(try KeychainPushMaterialSource.fromBundle(.main)!.loadAll(realm: "live").isEmpty)
    }

    func testWipeOfWorkspaceItemsRemovesPushMaterial() throws {
        try publish()
        try SecretVault(group: .push, backend: backend).wipe(realm: .live, ws: a.id.hex)
        XCTAssertTrue(try KeychainPushMaterialSource.fromBundle(.main)!.loadAll(realm: "live").isEmpty)
    }

    /// The whole extension pipeline against the real keychain and a real file system: material from the keychain, replay
    /// state on disk, marker, generic text for drops.
    func testHandlerWithRealKeychainMaterial() throws {
        try publish()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orch-app-push-\(UUID().uuidString)")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let h = PushHandler(material: KeychainPushMaterialSource.fromBundle(.main)!, pushDir: dir)
        for f in PushFixtures.sequence(nowMs: now) {
            let o = ((try JSONSerialization.jsonObject(with: f.apns)) as! [String: Any])["o"] as! String
            let r = h.handle(o: o)
            XCTAssertEqual(r.outcome.rawValue, f.expectedOutcome, f.name)
            XCTAssertEqual(r.presentation.body, f.expectedBody ?? PushPresentation.genericBody, f.name)
        }
        XCTAssertEqual(NSEMarker.read(pushDir: dir)?.count, 8)
        // replay state file protection (A8). The simulator may not report a class; a real one must be the right one.
        let state = ReplayStore(pushDir: dir, realm: "live").stateDir(workspace: a.id).appendingPathComponent("replay.1.json")
        let prot = try FileManager.default.attributesOfItem(atPath: state.path)[.protectionKey] as? FileProtectionType
        if let prot { XCTAssertEqual(prot, .completeUntilFirstUserAuthentication) }
    }

    func testAppGroupContainerExists() throws {
        guard let dir = PushGroup.pushDir() else { throw XCTSkip("no app group entitlement in this test host") }
        XCTAssertTrue(dir.path.contains("Shared/AppGroup") || dir.path.contains("AppGroup"))
    }
}

#endif

final class APNsTokenStoreTests: XCTestCase {
    func testTokenStoredPerInstallationAndChangeDetected() {
        let defaults = UserDefaults(suiteName: "orch.test.\(UUID().uuidString)")!
        let s = APNsTokenStore(defaults: defaults)
        XCTAssertNil(s.stored)
        XCTAssertTrue(s.save(deviceToken: Data([1, 2, 3]), environment: .sandbox))
        XCTAssertEqual(s.stored, .init(token: B64U.encode(Data([1, 2, 3])), environment: .sandbox))
        XCTAssertFalse(s.save(deviceToken: Data([1, 2, 3]), environment: .sandbox), "same token: nothing to re-register")
        XCTAssertTrue(s.save(deviceToken: Data([1, 2, 3]), environment: .production), "environment change counts")
        XCTAssertTrue(s.save(deviceToken: Data([9]), environment: .production))
        s.clear()
        XCTAssertNil(s.stored)
    }

    func testEnvironmentFollowsBuildConfiguration() {
        #if DEBUG
        XCTAssertEqual(APNsEnvironment.current, .sandbox)
        #else
        XCTAssertEqual(APNsEnvironment.current, .production)
        #endif
    }

    func testReleaseIgnoresPushHarnessFlags() {
        let args = ["orch", "--push-harness", "--push-material", "x:y"]
        XCTAssertFalse(LaunchOptions.parse(arguments: args, debug: false).pushHarness)
        XCTAssertNil(LaunchOptions.parse(arguments: args, debug: false).pushMaterial)
        XCTAssertTrue(LaunchOptions.parse(arguments: args, debug: true).pushHarness)
    }
}
