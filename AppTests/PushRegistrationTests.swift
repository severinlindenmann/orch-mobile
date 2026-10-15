import Foundation
import OrchClient
@testable import OrchCustody
import OrchProtocol
import XCTest
@testable import OrchPush
@testable import Orch

#if DEBUG // VaultPushSink(backend:realm:) is DEBUG-only; the Release flag check compiles all tests
/// A workspace's push service that answers from a script.
final class FakePush: PushRegistering, @unchecked Sendable {
    let workspace: ID16
    private let lock = NSLock()
    private var registerScript: [PushRegistrationOutcome]
    private var unregisterScript: [PushRegistrationOutcome]
    private var _registerCalls: [(token: String, env: PushEnvironment)] = []
    private var _unregisterCalls = 0
    var unregisterDelay: Double = 0
    var material: (wsk: SigningPublicKey, kPush: [UInt32: Data])?

    init(_ ws: ID16 = PushFixtures.workspaceA.id, register: [PushRegistrationOutcome] = [], unregister: [PushRegistrationOutcome] = []) {
        workspace = ws; registerScript = register; unregisterScript = unregister
    }
    var registerCalls: [(token: String, env: PushEnvironment)] { lock.withLock { _registerCalls } }
    var unregisterCalls: Int { lock.withLock { _unregisterCalls } }

    func register(token: String, env: PushEnvironment) async -> PushRegistrationOutcome {
        lock.withLock { _registerCalls.append((token, env)); return registerScript.isEmpty ? .registered(workspace) : registerScript.removeFirst() }
    }
    func unregisterAll() async -> PushRegistrationOutcome {
        lock.withLock { _unregisterCalls += 1 }
        if unregisterDelay > 0 { try? await Task.sleep(for: .seconds(unregisterDelay)) }
        return lock.withLock { unregisterScript.isEmpty ? .removed : unregisterScript.removeFirst() }
    }
    func keyMaterial() async throws -> (wsk: SigningPublicKey, kPush: [UInt32: Data]) {
        if let material { return material }
        let a = PushFixtures.workspaceA
        return (try SigningPublicKey(x963: a.wskPublic), [1: Data(repeating: 7, count: 32)])
    }
}

@MainActor
final class PushRegistrationCoordinatorTests: XCTestCase {
    var backend = InMemoryVaultBackend()
    var enabled = true, allowed = true
    var env: PushEnvironment? = .sandbox
    var token: String? = B64U.encode(Data(repeating: 3, count: 32))
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func makeCoordinator() -> PushRegistrationCoordinator {
        PushRegistrationCoordinator(.init(
            realm: "live", enabled: { [unowned self] in enabled }, environment: { [unowned self] in env }, token: { [unowned self] in token },
            permissionAllowed: { [unowned self] in allowed }, sink: { [unowned self] in VaultPushSink(backend: backend, realm: .live) },
            now: { [unowned self] in now }))
    }

    func testRegistersEveryWorkspaceWithTheStoredTokenAndEnvironment() async {
        let c = makeCoordinator(), a = FakePush(), b = FakePush(ID16(bytes: Data(repeating: 0xB2, count: 16))!)
        await c.registerAll([a, b])
        XCTAssertEqual(a.registerCalls.map(\.token), [token!]); XCTAssertEqual(b.registerCalls.map(\.env), [.sandbox])
        XCTAssertEqual(c.status.count, 2)
        // every launch: asking again is the same call (the relay answers 200 for the same body)
        await c.registerAll([a, b])
        XCTAssertEqual(a.registerCalls.count, 2)
    }

    func testNothingIsSentWithoutCapabilityEnvironmentTokenOrPermission() async {
        let c = makeCoordinator(), a = FakePush()
        enabled = false; await c.registerAll([a])
        enabled = true; env = nil; await c.registerAll([a])                 // Simulator / no push entitlement
        env = .production; token = nil; await c.registerAll([a])
        token = "x"; allowed = false; await c.registerAll([a])
        XCTAssertTrue(a.registerCalls.isEmpty)
        let r = await c.unregister(a)                                        // enabled but no environment: nothing was ever registered
        env = nil
        let skipped = await c.unregister(a)
        XCTAssertEqual(r, .done); XCTAssertEqual(skipped, .done); XCTAssertEqual(a.unregisterCalls, 1)
    }

    func test404StopsAskingUntilTheNextLaunch() async {
        let c = makeCoordinator(), a = FakePush(register: [.pushOff])
        await c.registerAll([a])
        XCTAssertTrue(c.relayPushOff); XCTAssertEqual(c.status[a.workspace.hex], .relayPushOff)
        await c.registerAll([a]); await c.register(a)
        XCTAssertEqual(a.registerCalls.count, 1, "no retry in this process")
        XCTAssertTrue(c.summary.contains("not enabled"))
        let next = makeCoordinator()                                          // the next launch asks again
        await next.registerAll([a])
        XCTAssertEqual(a.registerCalls.count, 2)
    }

    func testRateLimitBacksOffForRetryAfter() async {
        let c = makeCoordinator(), a = FakePush(register: [.rateLimited(retryAfter: 60)])
        await c.register(a)
        await c.register(a)
        XCTAssertEqual(a.registerCalls.count, 1)
        now = now.addingTimeInterval(61)
        await c.register(a)
        XCTAssertEqual(a.registerCalls.count, 2)
    }

    func testRefusalsAndFailuresAreVisibleNotFatal() async {
        let c = makeCoordinator(), a = FakePush(register: [.refused("not_eligible")]), b = FakePush(ID16(bytes: Data(repeating: 9, count: 16))!, register: [.failed("offline")])
        await c.registerAll([a, b])
        XCTAssertEqual(c.status[a.workspace.hex], .refused("not_eligible")); XCTAssertEqual(c.status[b.workspace.hex], .failed("offline"))
        XCTAssertFalse(c.relayPushOff)
        XCTAssertFalse(c.summary.contains(token!))
    }

    func testUnregisterIsBoundedAndReportsOwedWhenOffline() async {
        let c = makeCoordinator()
        let ok = await c.unregister(FakePush())
        let offline = await c.unregister(FakePush(unregister: [.failed("offline")]))
        let limited = await c.unregister(FakePush(unregister: [.rateLimited(retryAfter: nil)]))
        let off = await c.unregister(FakePush(unregister: [.pushOff]))
        XCTAssertEqual([ok, offline, limited, off], [.done, .owed, .owed, .done])
        let slow = FakePush(); slow.unregisterDelay = 30
        let started = Date()
        let timedOut = await c.unregister(slow, seconds: 0.2)
        XCTAssertEqual(timedOut, .owed); XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testPublishesKPushThroughTheFencedSinkAndNeverWK() async throws {
        let c = makeCoordinator(), a = FakePush()
        let published = await c.publishMaterial(a, name: String(repeating: "n", count: 500), generation: 4)
        XCTAssertTrue(published)
        let raw = try SecretVault(group: .push, backend: backend).scoped(to: .live).get(ws: a.workspace.hex, purpose: PushMaterial.purpose)
        let m = try PushMaterial.decode(raw)
        XCTAssertEqual(m.generation, 4); XCTAssertEqual(m.kPush[1], Data(repeating: 7, count: 32)); XCTAssertEqual(m.name.unicodeScalars.count, PushMaterial.maxNameScalars)
        // a later epoch replaces the item atomically (one item per workspace)
        a.material = (try SigningPublicKey(x963: PushFixtures.workspaceA.wskPublic), [1: Data(repeating: 7, count: 32), 2: Data(repeating: 8, count: 32)])
        let again = await c.publishMaterial(a, name: "n", generation: 4)
        XCTAssertTrue(again)
        let after = try PushMaterial.decode(try SecretVault(group: .push, backend: backend).scoped(to: .live).get(ws: a.workspace.hex, purpose: PushMaterial.purpose))
        XCTAssertEqual(Set(after.kPush.keys), [1, 2])
        // disabled realm: nothing is written
        enabled = false
        let none = await c.publishMaterial(FakePush(ID16(bytes: Data(repeating: 5, count: 16))!), name: "x", generation: 1)
        XCTAssertFalse(none)
    }
}
#endif
