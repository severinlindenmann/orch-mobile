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
    let generation: Int64
    private let lock = NSLock()
    private var registerScript: [PushRegistrationOutcome]
    private var unregisterScript: [PushRegistrationOutcome]
    private var _registerCalls: [(token: String, env: PushEnvironment)] = []
    private var _unregisterCalls = 0
    var unregisterDelay: Double = 0
    var registerDelay: Double = 0
    var onRegister: (@Sendable () -> Void)?
    var material: (wsk: SigningPublicKey, kPush: [UInt32: Data])?

    init(_ ws: ID16 = PushFixtures.workspaceA.id, generation: Int64 = 1, register: [PushRegistrationOutcome] = [], unregister: [PushRegistrationOutcome] = []) {
        workspace = ws; self.generation = generation; registerScript = register; unregisterScript = unregister
    }
    var registerCalls: [(token: String, env: PushEnvironment)] { lock.withLock { _registerCalls } }
    var unregisterCalls: Int { lock.withLock { _unregisterCalls } }

    func register(token: String, env: PushEnvironment) async -> PushRegistrationOutcome {
        onRegister?()
        if registerDelay > 0 { try? await Task.sleep(for: .seconds(registerDelay)) }
        return lock.withLock { _registerCalls.append((token, env)); return registerScript.isEmpty ? .registered(workspace) : registerScript.removeFirst() }
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
    var enabled = true, allowed = true, active = true
    var fakes: [ID16: FakePush] = [:]
    var env: PushEnvironment? = .sandbox
    var token: String? = B64U.encode(Data(repeating: 3, count: 32))
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    final class Flag: @unchecked Sendable { var v = false }
    let flag = Flag()

    func unregister(_ c: PushRegistrationCoordinator, _ f: FakePush, seconds: Double = 3) async -> PushRegistrationCoordinator.Removal {
        fakes[f.workspace] = f
        return await c.unregister(workspace: f.workspace, seconds: seconds)
    }

    /// The persisted 404 note (per install): survives a coordinator, like the next launch.
    var offSince: Date?

    func makeCoordinator() -> PushRegistrationCoordinator {
        PushRegistrationCoordinator(.init(
            realm: "live", enabled: { [unowned self] in enabled }, environment: { [unowned self] in env }, token: { [unowned self] in flag.v ? B64U.encode(Data(repeating: 4, count: 32)) : token },
            permissionAllowed: { [unowned self] in allowed }, sink: { [unowned self] in VaultPushSink(backend: backend, realm: .live) },
            isActive: { [unowned self] _ in active },
            unregisterDetached: { [unowned self] id in await fakes[id]?.unregisterAll() ?? .removed }, now: { [unowned self] in now },
            pushOffSince: { [unowned self] in offSince }, setPushOffSince: { [unowned self] in offSince = $0 }))
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
        let r = await unregister(c, a)                                        // enabled but no environment: nothing was ever registered
        env = nil
        let skipped = await unregister(c, a)
        XCTAssertEqual(r, .done); XCTAssertEqual(skipped, .done); XCTAssertEqual(a.unregisterCalls, 1)
    }

    func test404MarksTheRelayOffAndAsksAgainOnlyAfterSixHours() async {
        let c = makeCoordinator(), a = FakePush(register: [.pushOff])
        await c.registerAll([a])
        XCTAssertTrue(c.relayPushOff); XCTAssertEqual(c.status[a.workspace.hex], .relayPushOff)
        await c.registerAll([a]); await c.register(a)
        XCTAssertEqual(a.registerCalls.count, 1, "no retry within the window (foreground included)")
        XCTAssertTrue(c.summary.contains("not enabled"))
        now = now.addingTimeInterval(3600)
        let next = makeCoordinator()                                          // a launch within six hours: still off, nothing sent
        await next.registerAll([a])
        XCTAssertEqual(a.registerCalls.count, 1)
        XCTAssertTrue(next.summary.contains("not enabled"))
        now = now.addingTimeInterval(6 * 3600)                                // a foreground after the window asks once more
        await c.register(a)
        XCTAssertEqual(a.registerCalls.count, 2)
        XCTAssertFalse(c.relayPushOff, "a relay that now registers clears the note")
        XCTAssertNil(offSince)
    }

    func testAnotherPushOffAnswerRestartsTheWindow() async {
        let c = makeCoordinator(), a = FakePush(register: [.pushOff, .pushOff])
        await c.register(a)
        now = now.addingTimeInterval(7 * 3600)
        await c.register(a)
        XCTAssertEqual(a.registerCalls.count, 2); XCTAssertTrue(c.relayPushOff)
        now = now.addingTimeInterval(3600)
        await c.register(a)
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
        let ok = await unregister(c, FakePush())
        let offline = await unregister(c, FakePush(unregister: [.failed("offline")]))
        let limited = await unregister(c, FakePush(unregister: [.rateLimited(retryAfter: nil)]))
        let off = await unregister(c, FakePush(unregister: [.pushOff]))
        XCTAssertEqual([ok, offline, limited, off], [.done, .owed, .owed, .done])
        let slow = FakePush(); slow.unregisterDelay = 30
        let started = Date()
        let timedOut = await unregister(c, slow, seconds: 0.2)
        XCTAssertEqual(timedOut, .owed); XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testConcurrentTriggersShareOneRegistration() async {
        let c = makeCoordinator(), a = FakePush()
        a.registerDelay = 0.2
        async let x: Void = c.register(a)
        async let y: Void = c.register(a)
        async let z: Void = c.registerAll([a])
        _ = await (x, y, z)
        XCTAssertEqual(a.registerCalls.count, 1)
        XCTAssertEqual(c.status[a.workspace.hex], .registered)
    }

    func testATokenChangeDuringARegistrationReRunsOnceWithTheNewToken() async {
        let c = makeCoordinator(), a = FakePush()
        a.registerDelay = 0.1
        let f = flag
        a.onRegister = { f.v = true }
        await c.register(a)
        XCTAssertEqual(a.registerCalls.map(\.token), [B64U.encode(Data(repeating: 3, count: 32)), B64U.encode(Data(repeating: 4, count: 32))])
    }

    func testARegistrationThatCompletesAfterLeaveKeepsNothing() async {
        let c = makeCoordinator(), a = FakePush()
        a.registerDelay = 0.2
        let reg = Task { @MainActor in await c.register(a) }
        try? await Task.sleep(for: .milliseconds(50))
        active = false                                   // the workspace is left while the request is out
        let removal = await unregister(c, a)
        await reg.value
        XCTAssertEqual(removal, .done)
        XCTAssertNil(c.status[a.workspace.hex], "the late result is discarded")
        let before = a.registerCalls.count
        active = true
        await c.register(a); await c.registerAll([a])     // a left workspace never registers again
        XCTAssertEqual(a.registerCalls.count, before)
        c.workspaceStarted(a.workspace)                   // a re-pair is a new membership
        await c.register(a)
        XCTAssertEqual(a.registerCalls.count, before + 1)
    }

    func testNothingIsSentOrPublishedForAnInactiveWorkspace() async {
        let c = makeCoordinator(), a = FakePush()
        active = false
        await c.register(a)
        let published = await c.publishMaterial(a, name: "x", generation: 1)
        XCTAssertTrue(a.registerCalls.isEmpty); XCTAssertFalse(published)
        XCTAssertNil(try? SecretVault(group: .push, backend: backend).scoped(to: .live).get(ws: a.workspace.hex, purpose: PushMaterial.purpose))
    }

    func testClosingRefusesEveryRegisterAndPublish() async {
        let c = makeCoordinator(), a = FakePush()
        c.beginClosing()
        await c.register(a)
        let published = await c.publishMaterial(a, name: "x", generation: 1)
        XCTAssertTrue(a.registerCalls.isEmpty); XCTAssertFalse(published)
        XCTAssertTrue(c.closing)
    }

    func testAnInFlightRegistrationThatOutlastsTheWaitMakesTheCleanupOwed() async {
        let c = makeCoordinator(), a = FakePush()
        a.registerDelay = 5
        let reg = Task { @MainActor in await c.register(a) }
        try? await Task.sleep(for: .milliseconds(50))
        let r = await unregister(c, a, seconds: 0.2)
        XCTAssertEqual(r, .owed)
        reg.cancel()
    }

    func testSeveralInFlightGenerationsShareOneBound() async {
        let c = makeCoordinator(), a = FakePush(generation: 1)
        let b = FakePush(a.workspace, generation: 2)
        a.registerDelay = 30; b.registerDelay = 30     // both outlast the bound; per-generation waits would add up to 0.8 s
        // distinct keys: same workspace, two generations; both are in flight (counted) before the unregister starts
        let t1 = Task { @MainActor in await c.register(a) }, t2 = Task { @MainActor in await c.register(b) }
        for _ in 0..<400 where c.inFlightCount(workspace: a.workspace) < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(c.inFlightCount(workspace: a.workspace), 2)
        let started = Date()
        let r = await unregister(c, a, seconds: 0.4)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(r, .owed)
        t1.cancel(); t2.cancel()
    }

    func testAnUnreadableUnregisterReplyStaysOwed() {
        XCTAssertEqual(PushRegistrationCoordinator.removal(for: .refused("bad_reply")), .owed)
        XCTAssertEqual(PushRegistrationCoordinator.removal(for: .refused("revoked")), .done)
    }

    func testPermanentRefusalsAreNotRetried() async {
        let c = makeCoordinator(), a = FakePush(register: [.refused("malformed")])
        await c.register(a); await c.register(a); await c.registerAll([a])
        XCTAssertEqual(a.registerCalls.count, 1)
        c.workspaceStarted(a.workspace)                  // a re-pair starts fresh
        await c.register(a)
        XCTAssertEqual(a.registerCalls.count, 2)
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
