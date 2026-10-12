import CryptoKit
import Foundation
import Testing
import OrchCustody
import OrchProtocol
@testable import OrchClient

@Suite struct RealmTests {
    @Test func demoContextIsPinnedToTheDemoOrigin() throws {
        let c = demoContext()
        #expect(c.realm == .demo && c.origin == "https://relay.demo.invalid")
        try c.admit(origin: DemoRelay.origin)
        for o in ["https://relay.example.org", "https://relay.demo.invalid:8443", "http://localhost", "https://relay.demo.invalid/",
                  "https://RELAY.demo.invalid", "https://relay.demo.invalid.evil.example", ""] {
            #expect(throws: RealmViolation.self) { try c.admit(origin: o) }
        }
        #expect(throws: RealmViolation.externalOrigin) { try c.admit(origin: "https://relay.example.org") }
        #expect(throws: RealmViolation.invalidOrigin) { try c.admit(origin: "relay.demo.invalid") }
    }

    @Test func liveContextRefusesDemoLookingOrigins() throws {
        #expect(throws: RealmViolation.crossRealmOrigin) { try RealmContext.live(origin: "https://relay.demo.invalid") }
        #expect(throws: RealmViolation.crossRealmOrigin) { try RealmContext.live(origin: "https://anything.invalid") }
        #expect(throws: RealmViolation.invalidOrigin) { try RealmContext.live(origin: "http://relay.example.org") }
        let live = try RealmContext.live(origin: "https://relay.example.org")
        try live.admit(origin: "https://relay.example.org")
        #expect(throws: RealmViolation.crossRealmOrigin) { try live.admit(origin: DemoRelay.origin) }
        #expect(throws: RealmViolation.externalOrigin) { try live.admit(origin: "https://other.example.org") }
        #expect(throws: RealmViolation.crossRealmRecord) { try live.admit(realm: .demo) }
        try demoContext().admit(realm: .demo)
        #expect(throws: RealmViolation.crossRealmRecord) { try demoContext().admit(realm: .live) }
    }

    @Test func transportCannotBeBuiltForAnOriginTheContextRefuses() throws {
        let sender = RecordingSender()
        #expect(throws: RealmViolation.externalOrigin) {
            try RoutedRelayTransport(context: demoContext(), origin: "https://relay.example.org", sender: sender, clientAddress: "a")
        }
        #expect(sender.requests.isEmpty)
    }

    @Test func perRealmDeviceKeysAreDistinct() throws {
        let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let custody = DefaultCustody.make(vault: vault)
        let demo = try demoContext().deviceIdentity(custody: custody, createIfMissing: true)
        let live = try RealmContext.live(origin: "https://relay.example.org").deviceIdentity(custody: custody, createIfMissing: true)
        #expect(demo.publicKeys.sig != live.publicKeys.sig && demo.publicKeys.kx != live.publicKeys.kx)
        // The same call again loads, never replaces.
        #expect(try demoContext().deviceIdentity(custody: custody, createIfMissing: true).publicKeys == demo.publicKeys)
        // A live context never creates implicitly when told not to.
        let empty = DefaultCustody.make(vault: SecretVault(group: .keys, backend: InMemoryVaultBackend()))
        #expect(throws: CustodyError.missing) { try demoContext().deviceIdentity(custody: empty, createIfMissing: false) }
        #expect(try vault.ids().map(\.realm).sorted { $0.rawValue < $1.rawValue } == [.demo, .demo, .live, .live])
    }

    @Test func anIdentityCarriesItsCustodyRealmAndTheOtherRealmRefusesIt() throws {
        let custody = DefaultCustody.make(vault: SecretVault(group: .keys, backend: InMemoryVaultBackend()))
        let live = try custody.create(realm: .live), demo = try custody.create(realm: .demo)
        #expect(live.realm == .live && demo.realm == .demo)
        #expect(try custody.load(realm: .live).realm == .live && custody.load(realm: .demo).realm == .demo)
        let liveCtx = try RealmContext.live(origin: "https://relay.example.org")
        try liveCtx.admit(identity: live)
        try demoContext().admit(identity: demo)
        #expect(throws: RealmViolation.wrongStore) { try demoContext().admit(identity: live) }
        #expect(throws: RealmViolation.wrongStore) { try liveCtx.admit(identity: demo) }
        // A custody that answers a Demo request with the live identity (or creates one) is refused by the context.
        struct Liar: DeviceKeyCustody {
            let inner: any DeviceKeyCustody
            func create(realm: Realm) throws -> DeviceIdentity { try inner.load(realm: .live) }
            func load(realm: Realm) throws -> DeviceIdentity { try inner.load(realm: .live) }
            func delete(realm: Realm) throws {}
            func status(realm: Realm) -> CustodyStatus { inner.status(realm: .live) }
        }
        #expect(throws: RealmViolation.wrongStore) { try demoContext().deviceIdentity(custody: Liar(inner: custody), createIfMissing: true) }
        #expect(try liveCtx.deviceIdentity(custody: Liar(inner: custody), createIfMissing: false).realm == .live)
    }

    @Test func testClockAdvancesSleepersAndWallTime() async throws {
        let clock = TestClock(wallStartMs: 1_000)
        #expect(clock.nowMs == 1_000)
        let done = Flag()
        let task = Task { try await clock.sleep(for: .seconds(10)); done.set() }
        guard await waitForSleeper(clock) else { return }
        clock.advance(by: .seconds(9))
        await Task.yield()
        #expect(!done.value && clock.sleeperCount == 1)
        clock.advance(milliseconds: 1_000)
        try await task.value
        #expect(done.value && clock.nowMs == 11_000)
        // Cancellation wakes a sleeper with CancellationError.
        let t2 = Task { try await clock.sleep(for: .seconds(100)) }
        guard await waitForSleeper(clock) else { return }
        t2.cancel()
        await #expect(throws: CancellationError.self) { try await t2.value }
        #expect(clock.sleeperCount == 0)
        // A deadline already passed returns at once.
        try await clock.sleep(for: .zero)
    }

    @Test func aCancellationThatBeatsTheRegistrationIsKept() async throws {
        let clock = TestClock()
        // Cancel arrives before the sleeper registers: it must not be lost (the sleeper would wait forever).
        let id = clock.beginSleep()
        clock.cancelSleep(id)
        await #expect(throws: CancellationError.self) { try await clock.awaitSleep(id, until: clock.now.advanced(by: .seconds(100))) }
        #expect(clock.sleeperCount == 0)
        // The other order: registered, then cancelled; and cancelled twice.
        let id2 = clock.beginSleep()
        let parked = Task { try await clock.awaitSleep(id2, until: clock.now.advanced(by: .seconds(100))) }
        guard await waitForSleeper(clock) else { return }
        clock.cancelSleep(id2); clock.cancelSleep(id2)
        await #expect(throws: CancellationError.self) { try await parked.value }
        #expect(clock.sleeperCount == 0)
        // A cancelled-first sleeper does not poison a later one, and a due deadline still wins nothing over a cancel.
        let id3 = clock.beginSleep()
        try await clock.awaitSleep(id3, until: clock.now)
        // The public path with a task cancelled before it starts sleeping.
        let early = Task { () throws -> Void in
            while !Task.isCancelled { await Task.yield() }
            try await clock.sleep(for: .seconds(100))
        }
        early.cancel()
        await #expect(throws: CancellationError.self) { try await early.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test func scriptedFaultsAreConsumedOnceInOrder() {
        let f = ScriptedFaults().enqueue(.drop, at: .beforeQueue, times: 2).enqueue(.corrupt, at: .pollDelivery, routePrefix: "GET")
        #expect(f.action(at: .pollDelivery, route: "POST x") == .none)
        #expect(f.action(at: .beforeQueue, route: "a") == .drop)
        #expect(f.action(at: .beforeQueue, route: "a") == .drop)
        #expect(f.action(at: .beforeQueue, route: "a") == .none)
        #expect(f.action(at: .pollDelivery, route: "GET bridge") == .corrupt)
        #expect(f.remaining == 0)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var value: Bool { lock.withLock { v } }
    func set() { lock.withLock { v = true } }
}

/// Waits (real time, capped) for a sleeper to park on `clock`; records an issue instead of spinning until the CI job timeout.
func waitForSleeper(_ clock: TestClock, seconds: Int = 30) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while clock.sleeperCount == 0 {
        if ContinuousClock.now >= deadline { Issue.record("no sleeper parked on the test clock after \(seconds) s of real time"); return false }
        await Task.yield()
    }
    return true
}
