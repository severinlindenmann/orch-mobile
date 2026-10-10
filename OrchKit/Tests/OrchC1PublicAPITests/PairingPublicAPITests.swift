import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchStore

// Public API only (host-api section 7): the whole first-time pairing through the types a screen and the Demo controls can reach,
// and the realm boundaries around it. Runs in Release.

private func layout(_ realm: String) throws -> StoreLayout {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("orch-c1p-" + UUID().uuidString)
    return try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                           shareGroupRoot: base.appendingPathComponent("share"), realm: realm)
}

private struct Setup {
    let env: DemoEnvironment
    let clock: TestClock
    let vault: SecretVault
    let custody: any DeviceKeyCustody
    let rig: PairingRig
    let config: PairingConfig
    let coordinator: PairingCoordinator

    static func make(_ scenario: PairingScenario) async throws -> Setup {
        let clock = TestClock()
        let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let custody = DefaultCustody.make(vault: vault)
        let env = try await DemoSetup.setup(layout: layout("demo"), custody: custody, clock: clock, wall: clock)
        let rig = try await PairingRig.make(env: env, scenario: scenario)
        let config = PairingConfig(context: env.context, transport: env.transport, index: env.index, vault: vault, custody: custody, clock: clock,
                                   wall: clock, deviceLabel: "Severin's iPhone")
        return Setup(env: env, clock: clock, vault: vault, custody: custody, rig: rig, config: config, coordinator: PairingCoordinator(config))
    }

    @discardableResult
    func drive(_ until: (PairingState) -> Bool) async throws -> PairingState {
        for _ in 0..<400 {
            let s = await coordinator.state
            if until(s) { return s }
            try await rig.pump()
            await coordinator.poll()
            clock.advance(milliseconds: 1000)
        }
        return await coordinator.state
    }
}

@Suite struct C1PairingPublicAPITests {
    @Test func firstTimePairingThroughPublicTypesOnly() async throws {
        let s = try await Setup.make(.firstTime)
        let offer = try await s.rig.newOffer()
        // the link carries the secret: it is in no description of the offer
        #expect(!"\(offer)".contains(offer.link) && !String(reflecting: offer).contains(offer.link))
        let link = try PairingLink.parse(offer.link)
        #expect(link.origin == DemoRelay.origin)
        _ = await s.coordinator.start(link: link)
        guard case .comparingHost(let code) = try await s.drive({ if case .comparingHost = $0 { return true }; return false }) else { Issue.record("no host code"); return }
        let panel = await s.rig.host.pendingPairings()
        #expect(panel.count == 1 && panel[0].sas == code && panel[0].state == "pending")
        // the host's human compares and approves (an explicit input; there is no automatic path)
        await #expect(throws: PairingApprovalError.comparisonNotConfirmed) {
            try await s.rig.host.approvePairing(device: s.env.deviceID, confirmedComparison: false, relay: s.env.relay, transport: s.env.transport)
        }
        try await s.rig.host.approvePairing(device: s.env.deviceID, confirmedComparison: true, relay: s.env.relay, transport: s.env.transport)
        guard case .comparingPrimary(let certCode, let label, _) = try await s.drive({ if case .comparingPrimary = $0 { return true }; return false }) else {
            Issue.record("no cert code"); return
        }
        #expect(label == "Demo Mac" && certCode != code)
        let ws = s.rig.host.workspace
        let grants = await s.env.relay.grantCount(workspace: ws, device: s.env.deviceID)
        let hasWrap = await s.env.relay.hasCardKeyWrap(workspace: ws, device: s.env.deviceID, cardSeq: 1)
        let hasCert = await s.env.relay.hasCertificate(s.env.deviceID)
        #expect(grants == 0 && !hasWrap && !hasCert)               // nothing for the device before the primary signed
        let prompt = try #require(await s.rig.primary.openPrompts().first)
        #expect(prompt.certCode == certCode)
        try await s.rig.primary.approve(request: prompt.requestID, confirmedComparison: true, relay: s.env.relay)
        guard case .ready(let handle) = try await s.drive({ $0.isTerminal }) else { Issue.record("not ready"); return }
        #expect(handle.joined.name == "Laptop" && handle.joined.scopes == ["look", "decide"] && handle.joined.epoch == 1)
        #expect(!handle.joined.hosted.marker && handle.joined.hosted.hostedBy == nil)
        let rows = try await s.env.index.workspaces(), pending = try await s.env.index.pairings()
        #expect(rows.map(\.ws) == [ws.hex] && pending.isEmpty)
        let hasGrant = await s.env.relay.hasGrant(workspace: ws, device: s.env.deviceID, epoch: 1)
        let wrapNow = await s.env.relay.hasCardKeyWrap(workspace: ws, device: s.env.deviceID, cardSeq: 1)
        #expect(hasGrant && wrapNow)
    }

    @Test func aLinkForAnotherOriginNeverReachesTheRelay() async throws {
        let s = try await Setup.make(.firstTime)
        let offer = try await s.rig.newOffer()
        let before = await s.env.relay.requestsReceived
        for origin in ["https://relay.example.org", "http://localhost:8787", "https://relay.demo.invalid:8443"] {
            let tampered = offer.link.replacingOccurrences(of: DemoRelay.origin, with: origin)
            let state = await PairingCoordinator(s.config).start(link: try PairingLink.parse(tampered))
            guard case .failed(.realm(let v)) = state else { Issue.record("\(origin): \(state)"); continue }
            #expect([RealmViolation.externalOrigin, .crossRealmOrigin].contains(v))
        }
        // and a live-realm context takes no Demo origin
        #expect(throws: RealmViolation.crossRealmOrigin) { _ = try RealmContext.live(origin: DemoRelay.origin) }
        let after = await s.env.relay.requestsReceived
        #expect(after == before)
        let wss = try await s.env.index.workspaces(), rows = try await s.env.index.pairings()
        #expect(wss.isEmpty && rows.isEmpty)
    }

    @Test func rejectOnHostAndPrimaryOfflineLeaveNothingAtTheRelay() async throws {
        let s = try await Setup.make(.rejectOnHost)
        _ = await s.coordinator.start(link: try PairingLink.parse(try await s.rig.newOffer().link))
        try await s.drive({ if case .comparingHost = $0 { return true }; return false })
        // the default is reject
        try await s.rig.host.rejectPairing(device: s.env.deviceID)
        #expect(try await s.drive({ $0.isTerminal }) == .rejected)
        let grants = await s.env.relay.grantCount(workspace: s.rig.host.workspace, device: s.env.deviceID)
        let wraps = await s.env.relay.hasCardKeyWrap(workspace: s.rig.host.workspace, device: s.env.deviceID, cardSeq: 1)
        let cert = await s.env.relay.hasCertificate(s.env.deviceID)
        #expect(grants == 0 && !wraps && !cert)
        let rows = try await s.env.index.pairings()
        #expect(rows.isEmpty)
    }

    @Test func demoResetErasesAnInFlightPairing() async throws {
        let s = try await Setup.make(.firstTime)
        _ = await s.coordinator.start(link: try PairingLink.parse(try await s.rig.newOffer().link))
        try await s.drive({ if case .comparingHost = $0 { return true }; return false })
        try await DemoSetup.reset(s.env, custody: s.custody, vaults: [s.vault])
        // everything is gone and the stale environment cannot send: the next poll fails closed, creating nothing
        await s.coordinator.poll()
        #expect(s.custody.status(realm: .demo) == .missing)
        let items = try s.vault.ids().filter { $0.realm == .demo }
        #expect(items.isEmpty)
    }
}

// MARK: realm boundaries of the coordinator (public API only)

/// Counts every custody access so a test can prove none happened.
private final class SpyCustody: DeviceKeyCustody, @unchecked Sendable {
    private let inner: any DeviceKeyCustody
    private let lock = NSLock()
    private var n = 0
    var calls: Int { lock.withLock { n } }
    init(_ inner: any DeviceKeyCustody) { self.inner = inner }
    private func hit() { lock.withLock { n += 1 } }
    func create(realm: Realm) throws -> DeviceIdentity { hit(); return try inner.create(realm: realm) }
    func load(realm: Realm) throws -> DeviceIdentity { hit(); return try inner.load(realm: realm) }
    func publicKeys(realm: Realm) throws -> DevicePublicKeys { hit(); return try inner.publicKeys(realm: realm) }
    func delete(realm: Realm) throws { hit(); try inner.delete(realm: realm) }
    func status(realm: Realm) -> CustodyStatus { hit(); return inner.status(realm: realm) }
}

/// A relay transport that is not the Demo's: any use fails. Its context is the one it claims to carry.
private struct OtherTransport: RelayTransport {
    let context: RealmContext
    private func no() throws -> WireReply { throw TransportError.disconnected }
    func challenge() async throws -> WireReply { try no() }
    func login(_ body: Data) async throws -> WireReply { try no() }
    func pairingPost(_ envelope: Data, route: PairRoute) async throws -> WireReply { try no() }
    func pairingPoll(route: PairRoute, after: UInt64?) async throws -> WireReply { try no() }
    func bridgePost(_ envelope: Data, route: BridgeRoute, session: RelaySession) async throws -> WireReply { try no() }
    func bridgePoll(route: BridgeRoute, after: UInt64?, session: RelaySession) async throws -> WireReply { try no() }
    func grants(workspaceID: ID16, epoch: UInt32?, session: RelaySession) async throws -> WireReply { try no() }
    func memberList(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try no() }
    func card(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try no() }
    func cardKey(workspaceID: ID16, cardSequence: UInt32, session: RelaySession) async throws -> WireReply { try no() }
    func registerPush(_ body: Data, session: RelaySession) async throws -> WireReply { try no() }
    func unregisterPush(_ body: Data, session: RelaySession) async throws -> WireReply { try no() }
    func revocation(deviceID: ID16) async throws -> WireReply { try no() }
    func dropPut(objectID: ID16, ifMatch: UInt32, body: Data, session: RelaySession) async throws -> WireReply { try no() }
    func dropList(_ query: Data, session: RelaySession) async throws -> WireReply { try no() }
    func dropGet(objectID: ID16, version: UInt32, part: DropPart, session: RelaySession) async throws -> WireReply { try no() }
}

@Suite struct C1PairingRealmBoundaryTests {
    private struct Probe {
        let s: Setup
        let spy: SpyCustody
        let offer: PairingOffer
        let link: PairingLink
        let before: Int

        static func make() async throws -> Probe {
            let s = try await Setup.make(.firstTime)
            let spy = SpyCustody(s.custody)
            let offer = try await s.rig.newOffer()
            return Probe(s: s, spy: spy, offer: offer, link: try PairingLink.parse(offer.link), before: await s.env.relay.requestsReceived)
        }

        func config(context: RealmContext? = nil, transport: (any RelayTransport)? = nil, index: WorkspaceIndex? = nil, vault: SecretVault? = nil) -> PairingConfig {
            PairingConfig(context: context ?? s.env.context, transport: transport ?? s.env.transport, index: index ?? s.env.index, vault: vault ?? s.vault,
                          custody: spy, clock: s.clock, wall: s.clock, deviceLabel: "Severin's iPhone")
        }

        /// Refused with `violation`, before any custody access, any store write or any request.
        func expectRefused(_ c: PairingConfig, _ violation: RealmViolation, _ what: String, storeIsOpen: Bool = true) async throws {
            let coordinator = PairingCoordinator(c)
            let state = await coordinator.start(link: link)
            #expect(state == .failed(.realm(violation)), "\(what): \(state)")
            #expect(spy.calls == 0, "\(what): custody was touched")
            #expect(await s.env.relay.requestsReceived == before, "\(what): a request was made")
            if storeIsOpen {
                let rows = try await s.env.index.pairings(), wss = try await s.env.index.workspaces()
                #expect(rows.isEmpty && wss.isEmpty, "\(what)")
            }
            #expect(((try? s.vault.ids()) ?? []).filter { $0.realm == .demo && $0.ws != nil }.isEmpty, "\(what)")
            // adopting a certificate and resuming are refused the same way
            await #expect(throws: RealmViolation.self) { try await coordinator.adoptCertificate(.null, owner: s.rig.primary.publicKey) }
            _ = await coordinator.resume(ws: link.workspace)
            #expect(spy.calls == 0, "\(what): custody was touched by adopt/resume")
        }
    }

    @Test func aTransportOfAnotherRealmOrOriginIsRefusedBeforeAnyAccess() async throws {
        let p = try await Probe.make()
        let live = try RealmContext.live(origin: "https://relay.example")
        // a live transport under the Demo context, and the Demo transport under a live context
        try await p.expectRefused(p.config(transport: OtherTransport(context: live)), .wrongTransport, "live transport, demo context")
        try await p.expectRefused(p.config(context: live), .wrongTransport, "demo transport, live context")
        // a live transport for another origin under a live context
        let otherLive = try RealmContext.live(origin: "https://other.example")
        try await p.expectRefused(p.config(context: live, transport: OtherTransport(context: otherLive)), .wrongTransport, "origin mismatch")
    }

    @Test func anIndexOrVaultOfAnotherRealmIsRefusedBeforeAnyAccess() async throws {
        let p = try await Probe.make()
        let liveIndex = try await WorkspaceIndex(layout: layout("live"))
        try await p.expectRefused(p.config(index: liveIndex), .wrongStore, "live index under the Demo context")
        let pushVault = SecretVault(group: .push, backend: InMemoryVaultBackend())
        try await p.expectRefused(p.config(vault: pushVault), .wrongStore, "push-group vault")
    }

    @Test func aResetDemoRefusesEveryEntryPoint() async throws {
        let p = try await Probe.make()
        try await DemoSetup.reset(p.s.env, custody: p.s.custody, vaults: [p.s.vault])
        try await p.expectRefused(p.config(), .staleGeneration, "after a Demo reset", storeIsOpen: false)
    }

    @Test func certificateAdoptionGoesThroughTheRealmContext() async throws {
        // a live context takes no certificate owned by a Demo authority, and stores nothing
        let s = try await Setup.make(.firstTime)
        let live = try RealmContext.live(origin: "https://relay.example")
        let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let custody = DefaultCustody.make(vault: vault)
        let index = try await WorkspaceIndex(layout: layout("live"))
        let cfg = PairingConfig(context: live, transport: OtherTransport(context: live), index: index, vault: vault, custody: custody, clock: s.clock,
                                wall: s.clock, deviceLabel: "Severin's iPhone")
        let coordinator = PairingCoordinator(cfg)
        let id = try live.deviceIdentity(custody: custody, createIfMissing: true)
        let cert = try await s.rig.primary.certify(DemoKeys(id.publicKeys), label: "Live phone", scopesMax: ["look"])
        await #expect(throws: RealmViolation.crossRealmCertificate) { try await coordinator.adoptCertificate(cert, owner: s.rig.primary.publicKey) }
        #expect(((try? vault.ids()) ?? []).filter { $0.purpose == "device.cert" }.isEmpty)
        // and the Demo realm takes no certificate that is not from a Demo authority (here: a different key's signature)
        let demo = PairingCoordinator(s.config)
        let demoID = try s.env.context.deviceIdentity(custody: s.custody, createIfMissing: true)
        let ok = try await s.rig.primary.certify(DemoKeys(demoID.publicKeys), label: "Demo phone", scopesMax: ["look"])
        try await demo.adoptCertificate(ok, owner: s.rig.primary.publicKey)
        await #expect(throws: (any Error).self) { try await demo.adoptCertificate(ok, owner: s.rig.foreign.publicKey) }
    }
}
