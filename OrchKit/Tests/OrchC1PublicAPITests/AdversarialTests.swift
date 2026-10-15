import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchStore

// Public API only (host-api section 7), Release too. These are the security review's adversarial cases with the fixed behaviour
// asserted: a realm tag on every device identity, logins bound to the transport, Demo reset that ends the lifetime.

private func layout(_ realm: String) throws -> StoreLayout {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("orch-adv-" + UUID().uuidString)
    return try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                           shareGroupRoot: base.appendingPathComponent("share"), realm: realm)
}

/// A custody wrapper that ignores the realm argument and always hands out the identity of `serving`.
private struct RealmIgnoringCustody: DeviceKeyCustody {
    let inner: any DeviceKeyCustody
    let serving: Realm
    func create(realm: Realm) throws -> DeviceIdentity { try inner.load(realm: serving) }
    func load(realm: Realm) throws -> DeviceIdentity { try inner.load(realm: serving) }
    func publicKeys(realm: Realm) throws -> DevicePublicKeys { try inner.publicKeys(realm: serving) }
    func delete(realm: Realm) throws {}
    func status(realm: Realm) -> CustodyStatus { inner.status(realm: serving) }
}

/// A public RelayTransport that wraps the Demo transport. It reports whatever context it is told to: the client must bind a login
/// to that context, so the wrapper cannot make a key sign an origin or serve a realm the context does not name.
private struct Forwarder: RelayTransport {
    let t: InProcessRelayTransport
    let reported: RealmContext
    var context: RealmContext { reported }
    func challenge() async throws -> WireReply { try await t.challenge() }
    func login(_ b: Data) async throws -> WireReply { try await t.login(b) }
    func pairingPost(_ e: Data, route: PairRoute) async throws -> WireReply { try await t.pairingPost(e, route: route) }
    func pairingPoll(route: PairRoute, after: UInt64?, wait: Int?) async throws -> WireReply { try await t.pairingPoll(route: route, after: after, wait: wait) }
    func bridgePost(_ e: Data, route: BridgeRoute, session: RelaySession) async throws -> WireReply { try await t.bridgePost(e, route: route, session: session) }
    func bridgePoll(route: BridgeRoute, after: UInt64?, wait: Int?, session: RelaySession) async throws -> WireReply { try await t.bridgePoll(route: route, after: after, wait: wait, session: session) }
    func grants(workspaceID: ID16, epoch: UInt32?, session: RelaySession) async throws -> WireReply { try await t.grants(workspaceID: workspaceID, epoch: epoch, session: session) }
    func memberList(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try await t.memberList(workspaceID: workspaceID, session: session) }
    func card(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try await t.card(workspaceID: workspaceID, session: session) }
    func cardKey(workspaceID: ID16, cardSequence: UInt32, session: RelaySession) async throws -> WireReply { try await t.cardKey(workspaceID: workspaceID, cardSequence: cardSequence, session: session) }
    func registerPush(_ b: Data, session: RelaySession) async throws -> WireReply { try await t.registerPush(b, session: session) }
    func unregisterPush(_ b: Data, session: RelaySession) async throws -> WireReply { try await t.unregisterPush(b, session: session) }
    func revocation(deviceID: ID16, after: String?, limit: Int?) async throws -> WireReply { try await t.revocation(deviceID: deviceID, after: after, limit: limit) }
    func dropPut(objectID: ID16, ifMatch: UInt32, body: Data, session: RelaySession) async throws -> WireReply { try await t.dropPut(objectID: objectID, ifMatch: ifMatch, body: body, session: session) }
    func dropList(_ q: Data, session: RelaySession) async throws -> WireReply { try await t.dropList(q, session: session) }
    func dropGet(objectID: ID16, version: UInt32, part: DropPart, session: RelaySession) async throws -> WireReply { try await t.dropGet(objectID: objectID, version: version, part: part, session: session) }
}

private func custody() -> (any DeviceKeyCustody, SecretVault) {
    let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend())
    return (DefaultCustody.make(vault: vault), vault)
}

@Suite struct Adversarial {
    // MARK: realm-tagged identity

    @Test func aWrapperCustodyReturningLiveKeysForDemoIsRefused() async throws {
        let (real, _) = custody()
        _ = try real.create(realm: .live)
        let clock = TestClock()
        let l = try layout("demo")
        await #expect(throws: RealmViolation.wrongStore) {
            _ = try await DemoSetup.setup(layout: l, custody: RealmIgnoringCustody(inner: real, serving: .live), clock: clock, wall: clock)
        }
        // Nothing was built on the way: no Demo store on disk, no Demo keys in custody.
        #expect(!FileManager.default.fileExists(atPath: l.realmDir.path))
        #expect(real.status(realm: .demo) == .missing)
    }

    @Test func aDemoIdentityInALiveContextIsRefused() async throws {
        let (real, _) = custody()
        _ = try real.create(realm: .demo)
        let live = try RealmContext.live(origin: "https://relay.example.com")
        #expect(throws: RealmViolation.wrongStore) {
            _ = try live.deviceIdentity(custody: RealmIgnoringCustody(inner: real, serving: .demo), createIfMissing: true)
        }
        // The honest custody answers each realm with its own identity.
        let demoCtx = try await DemoSetup.setup(layout: layout("demo"), custody: real, clock: TestClock(), wall: TestClock()).context
        #expect(throws: RealmViolation.wrongStore) { try live.admit(identity: real.load(realm: .demo)) }
        #expect(throws: RealmViolation.wrongStore) { try demoCtx.admit(identity: real.create(realm: .live)) }
    }

    // MARK: login bound to the transport

    @Test func aLiveIdentityOnADemoTransportIsRejectedBeforeAnyRequest() async throws {
        let (c, _) = custody()
        let clock = TestClock()
        let env = try await DemoSetup.setup(layout: layout("demo"), custody: c, clock: clock, wall: clock)
        let live = try c.create(realm: .live)
        let before = await env.relay.requestsReceived
        await #expect(throws: RealmViolation.wrongStore) {
            _ = try await RelayClient(transport: env.transport).openDeviceSession(identity: live, deviceID: Identifiers.deviceID(live.publicKeys.sig))
        }
        #expect(await env.relay.requestsReceived == before)
    }

    @Test func aTransportThatForwardsCannotMakeDemoKeysSignAForeignOrigin() async throws {
        let (c, _) = custody()
        let clock = TestClock()
        let env = try await DemoSetup.setup(layout: layout("demo"), custody: c, clock: clock, wall: clock)
        // The wrapper reports a live context but carries the bytes to the Demo relay.
        let liveContext = try RealmContext.live(origin: "https://relay.example.com")
        let forwarding = RelayClient(transport: Forwarder(t: env.transport, reported: liveContext))
        let before = await env.relay.requestsReceived
        await #expect(throws: RealmViolation.wrongStore) {
            _ = try await forwarding.openDeviceSession(identity: env.device, deviceID: env.deviceID)
        }
        #expect(await env.relay.requestsReceived == before)         // refused before the challenge was asked for
        // A wrapper that reports the Demo context signs the Demo origin only: the call goes through the relay's own checks.
        let honest = RelayClient(transport: Forwarder(t: env.transport, reported: env.context))
        do { _ = try await honest.openDeviceSession(identity: env.device, deviceID: env.deviceID) } catch { /* unknown device: relay answers, not the client */ }
        #expect(await env.relay.requestsReceived == before + 2)
        // The deviceID must be the identity's own.
        await #expect(throws: TransportError.invalidArgument) {
            _ = try await honest.openDeviceSession(identity: env.device, deviceID: ID16.random())
        }
    }

    // MARK: Demo reset owns the lifecycle

    @Test func resetEndsTheLifetimeAndErasesOnlyTheDemoRealm() async throws {
        let (c, vault) = custody()
        let clock = TestClock()
        let demoLayout = try layout("demo"), liveLayout = try layout("live")
        // Live data of every kind: custody keys, a vault item, and a workspace store with a file.
        let live = try c.create(realm: .live)
        let liveWS = ID16.random().hex
        try vault.put(Data([1]), for: SecretID(realm: .live, ws: liveWS, purpose: "wk"))
        let liveIndex = try await WorkspaceIndex(layout: liveLayout)
        try await liveIndex.addWorkspace(ws: liveWS, generation: 1)
        let liveFile = try liveLayout.filesDir(liveWS).appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: liveFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("live".utf8).write(to: liveFile)

        let env = try await DemoSetup.setup(layout: demoLayout, custody: c, clock: clock, wall: clock)
        let demoWS = ID16.random().hex
        try vault.put(Data([2]), for: SecretID(realm: .demo, ws: demoWS, purpose: "wk"))
        try await env.index.addWorkspace(ws: demoWS, generation: 1)
        let demoFile = try demoLayout.filesDir(demoWS).appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: demoFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("demo".utf8).write(to: demoFile)

        // A running Demo: authority, host, published directory, an open session.
        let primary = DemoSetup.makeAuthority(env)
        let host = try DemoSetup.makeHost(env, primary: primary)
        let phone = DemoKeys(env.device.publicKeys)
        let primaryCert = try await primary.certifyOwnDevice()
        let phoneCert = try await primary.certify(phone, label: "Demo iPhone", scopesMax: ["look"])
        _ = try await host.publishInitial(relay: env.relay, transport: env.transport, devices: [
            (primary.deviceKeys, primaryCert, ["look", "decide", "operate", "type"]), (phone, phoneCert, ["look"])])
        let client = RelayClient(transport: env.transport)
        let opened = try await client.openDeviceSession(identity: env.device, deviceID: env.deviceID)
        _ = try await client.card(workspace: host.workspace, session: opened.session)
        let sessionsBefore = await env.relay.sessionCount()
        #expect(sessionsBefore == 2 && env.generation.isCurrent)
        let retainedTransport = env.transport, retainedDevice = env.device, retainedRelay = env.relay

        try await DemoSetup.reset(env, custody: c, vaults: [vault])

        // The lifetime is over.
        #expect(!env.generation.isCurrent)
        // Transport: every retained handle fails before anything is sent, and the relay holds nothing.
        await #expect(throws: TransportError.realm(.staleGeneration)) { _ = try await retainedTransport.challenge() }
        await #expect(throws: TransportError.realm(.staleGeneration)) { _ = try await client.card(workspace: host.workspace, session: opened.session) }
        await #expect(throws: TransportError.realm(.staleGeneration)) { _ = try await retainedRelay.send(WireRequest(method: "POST", target: "/v2/session/challenge", headers: [:], body: HostAPI.json(), clientAddress: "a")) }
        let sessionsAfter = await retainedRelay.sessionCount()
        #expect(sessionsAfter == 0)
        let hasCert = await retainedRelay.hasCertificate(env.deviceID), listSeq = await retainedRelay.memberListSeq(workspace: host.workspace)
        #expect(hasCert == false && listSeq == nil)
        await #expect(throws: RealmViolation.staleGeneration) { try await retainedRelay.publishCertificate(phoneCert) }
        // Signing: a retained device identity no longer signs, even against a fresh Demo relay.
        let c2 = custody().0
        let env2 = try await DemoSetup.setup(layout: layout("demo"), custody: c2, clock: clock, wall: clock)
        await #expect(throws: RealmViolation.staleGeneration) {
            _ = try await RelayClient(transport: env2.transport).openDeviceSession(identity: retainedDevice, deviceID: env.deviceID)
        }
        let env2Sessions = await env2.relay.sessionCount()
        #expect(env2Sessions == 0 && env2.generation.isCurrent)
        // Authority actors: dead.
        await #expect(throws: RealmViolation.staleGeneration) { _ = try await primary.certifyOwnDevice() }
        await #expect(throws: RealmViolation.staleGeneration) { _ = try await primary.revoke(device: env.deviceID) }
        await #expect(throws: RealmViolation.staleGeneration) { _ = try await host.card() }
        await #expect(throws: RealmViolation.staleGeneration) { _ = try await host.openSession(transport: retainedTransport) }
        // A new lifetime's context is not the old one: the old host cannot log in through it either.
        await #expect(throws: RealmViolation.self) { _ = try await host.openSession(transport: env2.transport) }

        // Demo stores and keys are gone.
        #expect(!FileManager.default.fileExists(atPath: demoFile.path) && !FileManager.default.fileExists(atPath: demoLayout.realmDir.path))
        #expect(c.status(realm: .demo) == .missing)
        #expect(try vault.ids().allSatisfy { $0.realm == .live })
        // Live data of every kind is untouched.
        #expect(c.status(realm: .live) == .present)
        #expect(try c.load(realm: .live).publicKeys == live.publicKeys)
        #expect(try String(contentsOf: liveFile, encoding: .utf8) == "live")
        #expect(try await liveIndex.workspaces().map(\.ws) == [liveWS])
        #expect(try vault.get(SecretID(realm: .live, ws: liveWS, purpose: "wk")) == Data([1]))
        // A second reset of the same environment is a no-op.
        try await DemoSetup.reset(env, custody: c, vaults: [vault])
        #expect(c.status(realm: .live) == .present)
    }

    @Test func aFreshDemoAfterResetHasFreshKeys() async throws {
        let (c, vault) = custody()
        let clock = TestClock()
        let first = try await DemoSetup.setup(layout: layout("demo"), custody: c, clock: clock, wall: clock)
        let oldKeys = first.device.publicKeys
        try await DemoSetup.reset(first, custody: c, vaults: [vault])
        let second = try await DemoSetup.setup(layout: layout("demo"), custody: c, clock: clock, wall: clock)
        #expect(second.device.publicKeys.sig != oldKeys.sig && second.deviceID != first.deviceID)
        #expect(second.generation !== first.generation && second.generation.isCurrent)
    }

    // MARK: the review's other cases, fixed

    @Test func retryAfterIsStrictAndClamped() throws {
        let r = try WireReply(status: 429, headers: ["Retry-After": "-99999999"], body: HostAPI.json(["error": .string("rate_limited")]))
        #expect(HostAPI.failure(of: r) == .relay(RelayRefusal(status: 429, code: .rateLimited, retryAfter: nil)))
        let big = try WireReply(status: 429, headers: ["Retry-After": "99999999"], body: HostAPI.json(["error": .string("rate_limited")]))
        #expect(HostAPI.failure(of: big) == .relay(RelayRefusal(status: 429, code: .rateLimited, retryAfter: 3600)))
    }

    @Test func statusFamilyIsChecked() throws {
        let a = try WireReply(status: 500, body: try canonicalJSON(["error": .string("revoked")]))
        let b = try WireReply(status: 403, body: HostAPI.json(["error": .string("unauthenticated")]))
        #expect(HostAPI.failure(of: a) == .badReply)
        #expect(HostAPI.failure(of: b) == .badReply)
    }

    @Test func sessionDescriptionRedactsTheBearer() async throws {
        let s = RelaySession(token: "SECRET-BEARER")
        #expect(!"\(s)".contains("SECRET-BEARER") && !String(reflecting: s).contains("SECRET-BEARER"))
        var dumped = ""; dump(s, to: &dumped)
        #expect(!dumped.contains("SECRET-BEARER"))
        let o = "\(RelayClient.Opened.self)"; _ = o
    }

    @Test func headerInjectionAndConflictsAreRefused() throws {
        #expect(throws: WireError.self) { _ = try WireRequest(method: "GET", target: "/", headers: ["x": "a\r\nb: c"], clientAddress: "x") }
        #expect(throws: WireError.self) { _ = try WireReply(status: 200, headers: ["X-A": "1", "x-a": "2"]) }
        #expect(throws: WireError.self) { _ = try WireReply(status: 200, headers: ["x a": "1"]) }
    }

    @Test func aLiveRelayCannotBeBuiltThroughThePublicAPI() async throws {
        let live = try RealmContext.live(origin: "https://relay.example.com")
        let clock = TestClock()
        let (c, _) = custody()
        let env = try await DemoSetup.setup(layout: layout("demo"), custody: c, clock: clock, wall: clock)
        #expect(throws: RealmViolation.wrongStore) { _ = try FakeRelay(capability: env.capability, context: live, clock: clock, wall: clock) }
    }
}
