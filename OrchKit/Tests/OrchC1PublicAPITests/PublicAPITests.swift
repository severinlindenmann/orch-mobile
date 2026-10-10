import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchStore

// Public API only (host-api section 7): ordinary imports, no @testable, no package-level signers, no fixture keys.
// Runs in Release: swift test --package-path OrchKit -c release --filter OrchC1PublicAPITests

private func layout(_ realm: String) throws -> StoreLayout {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("orch-c1-" + UUID().uuidString)
    return try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                           shareGroupRoot: base.appendingPathComponent("share"), realm: realm)
}

private func custody() -> (any DeviceKeyCustody, SecretVault) {
    let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend())
    return (DefaultCustody.make(vault: vault), vault)
}

@Suite struct C1PublicAPITests {
    @Test func demoBootstrapBindsDemoStoreCustodyAndInProcessRelay() async throws {
        let (c, _) = custody()
        let clock = TestClock()
        let env = try await DemoSetup.setup(layout: layout("demo"), custody: c, clock: clock, wall: clock)
        #expect(env.context.realm == .demo && env.context.origin == "https://relay.demo.invalid")
        #expect(env.layout.realm == "demo" && env.relay.origin == env.context.origin)
        #expect(c.status(realm: .demo) == .present && c.status(realm: .live) == .missing)
        // The Demo relay answers through real bytes.
        let reply = try await env.transport.challenge()
        #expect(reply.status == 200)
        #expect(try HostAPI.challenge(reply.body).challenge.count == 32)
    }

    @Test func aLiveStoreCannotBecomeADemoRealm() async throws {
        let (c, _) = custody()
        let clock = TestClock()
        await #expect(throws: RealmViolation.wrongStore) { _ = try await DemoSetup.setup(layout: layout("live"), custody: c, clock: clock, wall: clock) }
        #expect(c.status(realm: .demo) == .missing)       // nothing was created on the way
    }

    @Test func demoTransportIsInProcessOnlyAndRefusesExternalOrigins() async throws {
        let (c, _) = custody()
        let clock = TestClock()
        let env = try await DemoSetup.setup(layout: layout("demo"), custody: c, clock: clock, wall: clock)
        let live = try RealmContext.live(origin: "https://relay.example.org")
        // A relay needs a DemoCapability and a Demo context made from that very capability: there is no public way to build a live one.
        #expect(throws: RealmViolation.wrongStore) { _ = try FakeRelay(capability: env.capability, context: live, clock: clock, wall: clock) }
        let other = try await DemoSetup.setup(layout: layout("demo"), custody: c, clock: clock, wall: clock)
        #expect(throws: RealmViolation.wrongStore) { _ = try FakeRelay(capability: other.capability, context: env.context, clock: clock, wall: clock) }
        #expect(throws: TransportError.realm(.wrongTransport)) { try InProcessRelayTransport(context: live, relay: env.relay) }
        for origin in ["https://relay.example.org", "http://localhost", "https://relay.demo.invalid:8443"] {
            #expect(throws: RealmViolation.self) { try env.context.admit(origin: origin) }
        }
        // A live context cannot take the Demo origin either.
        #expect(throws: RealmViolation.crossRealmOrigin) { try RealmContext.live(origin: DemoRelay.origin) }
        #expect(await env.relay.requestsReceived == 0)
    }

    @Test func aDemoCertificateIsRefusedByEveryLiveEntryPoint() async throws {
        let (c, _) = custody()
        let clock = TestClock()
        let env = try await DemoSetup.setup(layout: layout("demo"), custody: c, clock: clock, wall: clock)
        let primary = DemoSetup.makeAuthority(env)
        let cert = try await primary.certifyOwnDevice()
        let live = try RealmContext.live(origin: "https://relay.example.org")
        #expect(throws: RealmViolation.crossRealmCertificate) { _ = try live.admitCertificate(cert, ownerKey: primary.publicKey, nowMs: clock.nowMs) }
        // Its own realm takes it.
        _ = try env.context.admitCertificate(cert, ownerKey: primary.publicKey, nowMs: clock.nowMs)
    }

    @Test func demoAuthorityKeysAreFreshEveryTimeAndNeverTheVectorKeys() async throws {
        let (c, _) = custody()
        let clock = TestClock()
        let env = try await DemoSetup.setup(layout: layout("demo"), custody: c, clock: clock, wall: clock)
        let a = DemoSetup.makeAuthority(env), b = DemoSetup.makeAuthority(env)
        #expect(a.publicKey != b.publicKey && a.personID != b.personID && a.deviceID != b.deviceID)
        // The synthetic authority's device is not this iPhone's Demo device, and neither is a live device.
        #expect(a.deviceID != env.deviceID)
        let liveIdentity = try c.create(realm: .live)
        #expect(liveIdentity.publicKeys.sig != env.device.publicKeys.sig && liveIdentity.publicKeys.kx != env.device.publicKeys.kx)
    }
}
