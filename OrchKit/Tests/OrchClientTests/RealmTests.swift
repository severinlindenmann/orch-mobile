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

    @Test func testClockAdvancesSleepersAndWallTime() async throws {
        let clock = TestClock(wallStartMs: 1_000)
        #expect(clock.nowMs == 1_000)
        let done = Flag()
        let task = Task { try await clock.sleep(for: .seconds(10)); done.set() }
        while clock.sleeperCount == 0 { await Task.yield() }
        clock.advance(by: .seconds(9))
        await Task.yield()
        #expect(!done.value && clock.sleeperCount == 1)
        clock.advance(milliseconds: 1_000)
        try await task.value
        #expect(done.value && clock.nowMs == 11_000)
        // Cancellation wakes a sleeper with CancellationError.
        let t2 = Task { try await clock.sleep(for: .seconds(100)) }
        while clock.sleeperCount == 0 { await Task.yield() }
        t2.cancel()
        await #expect(throws: CancellationError.self) { try await t2.value }
        #expect(clock.sleeperCount == 0)
        // A deadline already passed returns at once.
        try await clock.sleep(for: .zero)
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
