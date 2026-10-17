import Foundation
import Testing
import OrchCustody
import OrchProtocol
import OrchStore
@testable import OrchClient
@testable import OrchFakeHost

// C2b increment 5: the Simulator dev-sandbox lane (host 11A.17). These tests exist only in a Debug Simulator build, like the lane itself:
// run them with `xcodebuild test -scheme OrchKit-Package -destination 'platform=iOS Simulator,...' -only-testing:OrchFakeHostTests/DevSandboxLaneTests`
// (`swift test` on macOS compiles this file to nothing).
#if DEBUG && targetEnvironment(simulator)

/// A sender that stands for the network (not an `InProcessDemoSender`) but forwards to the FakeRelay, on the variant's origin.
private struct NetworkForwarder: RequestSender {
    let relay: FakeRelay
    let origin: String
    func send(_ request: WireRequest) async throws -> WireReply { try await relay.send(request) }
}

/// Never reaches anything: 202 with an empty body.
private struct StubSender: RequestSender {
    let origin: String
    func send(_ request: WireRequest) async throws -> WireReply { try WireReply(status: 202, headers: [:], body: Data()) }
}

private let devOrigin = "https://relay.dev.severin.io"
private let id8 = "a1b2c3d4"

/// A Live-realm phone on a software key, over the FakeRelay and FakeHost, with the lane enabled (or not).
private struct LaneRig {
    let w: World
    let p: Phone
    let api: BridgeWorkspaceAPI
    let ops: OpCounter
    let hooks: Hooks
    let relay: FakeRelay
    let hostTransport: RoutedRelayTransport<FakeRelay>

    static func make(enabler: Bool = true, reader: ReaderRuntime = .production, origin: String = devOrigin, devOn: Bool = true,
                     serve: (@Sendable (HostRequest, FakeHost) async -> HostReply?)? = nil) async throws -> LaneRig {
        let w = try await World.make(publish: false)
        DemoAuthorities.shared.unregisterForTesting(w.primary.personID)     // this host stands in for a real Mac in a Live-realm test
        let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let ctx = try RealmContext.liveDevSandbox(origin: origin, enabler: DevSandboxLaneEnabler())
        let identity = try ctx.deviceIdentity(custody: SoftwareCustody(vault: vault), createIfMissing: true)
        let keys = DemoKeys(identity.publicKeys)
        // a relay of its own on the variant's origin (the world's is the Demo relay); the host talks to it in process, the phone as if over a network
        let relay = FakeRelay(testingContext: ctx, clock: w.clock, wall: w.clock)
        let hostTransport = try RoutedRelayTransport(context: ctx, origin: origin, sender: relay, clientAddress: "host")
        let cert = try await w.primary.certify(keys, label: "Simulator", scopesMax: ["look", "decide"])
        let primaryCert = try await w.primary.certifyOwnDevice()
        func step<T>(_ n: String, _ f: () async throws -> T) async throws -> T { do { return try await f() } catch { Issue.record("step \(n): \(error)"); throw error } }
        await w.host.setTestingLiveOrigin(origin)
        // `publishInitial`, with the card naming this relay's origin (a relay publishes only its own)
        try await step("publish") {
            await relay.registerOwner(w.primary.publicKey)
            for c in [primaryCert, cert] { try await relay.publishCertificate(c) }
            try await relay.publishCard(try await w.host.card(relayURL: origin))
            let session = try await w.host.openSession(transport: hostTransport)
            try await w.host.publishMembership(roster: [(w.primary.deviceKeys, World.all), (keys, ["look", "decide"])], epoch: 1,
                                               wraps: [w.primary.deviceKeys, keys], relay: relay, session: session)
        }
        let transport = try LiveTransport.testingTransport(context: ctx, sender: NetworkForwarder(relay: relay, origin: origin))
        let index = try await WorkspaceIndex(layout: tempLayout(realm: "live"), fence: ctx.writeFence)
        try await index.addWorkspace(ws: w.ws.hex, generation: 1)
        let container = try await WorkspaceContainer(index: index, ws: w.ws.hex, generation: 1)
        let pclock = TestClock(wallStartMs: w.clock.nowMs)
        let scoped = vault.scoped(to: .live)
        try scoped.put(try canonicalJSON(["pk_pub": .string(B64U.encode(await w.primary.publicKey.x963))]), purpose: "device.cert")
        var cfg = WorkspaceSessionConfig(context: ctx, workspace: w.ws, generation: 1, identity: identity, wsk: w.host.wskPublic, container: container,
                                         vault: scoped, transport: transport, clock: pclock, wall: pclock, entropy: SystemEntropy(),
                                         pollInterval: .milliseconds(500), responseTimeout: .seconds(30), longPollSeconds: nil,
                                         reader: reader, sendsReaderDigest: true, blocksUntilDeclared: true, enforcesOpTable: true)
        if enabler { cfg.devSandboxEnabler = DevSandboxLaneEnabler() }
        let session = try await step("session") { try await WorkspaceSession(cfg) }
        try await step("refreshGrants") { try await session.refreshGrants() }
        let p = Phone(session: session, container: container, clock: pclock)
        if devOn { await w.host.setDevSimConvenience(id8) }
        let ops = OpCounter()
        let host = w.host
        await host.setHandler { req in
            ops.bump(req.meta.object?["op"]?.string ?? "?")
            if let serve, let r = await serve(req, host) { return r }
            return await host.handleView(req)
        }
        let hooks = Hooks()
        await session.setCrashHook { try hooks.hit($0) }
        let rig = LaneRig(w: w, p: p, api: BridgeWorkspaceAPI(session: session), ops: ops, hooks: hooks, relay: relay, hostTransport: hostTransport)
        // the pairing declares the reader (level 1) and the host stores it; here the session does it once, as a paired session would have
        if reader.capability != nil { _ = try await rig.serve { try await session.declareReader() } }
        return rig
    }

    /// `World.serve` over this rig's relay: the host pumps while `body` runs.
    func serve<T: Sendable>(steps: Int = 200, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let done = Done()
        let task = Task { () -> Result<T, Error> in
            defer { done.set() }
            do { return .success(try await body()) } catch { return .failure(error) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        for _ in 0..<steps {
            if done.value || ContinuousClock.now >= deadline { break }
            while !done.value && p.clock.sleeperCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
            if done.value { break }
            _ = try await w.host.pump(relay: relay, transport: hostTransport, session: try await w.host.currentSession(transport: hostTransport))
            w.clock.advance(milliseconds: 500); p.clock.advance(milliseconds: 500)
            await Task.yield()
        }
        if !done.value { task.cancel() }
        return try await task.value.get()
    }

    func firstQuestion() async throws -> ID16 {
        let api = api
        let s = try await serve { try await api.snapshot() }
        return s.questions[0].questionID
    }
    func review(_ id: ID16) async throws -> QuestionReview {
        let api = api
        return try await serve { try await api.review(questionID: id) }
    }
    func answer(_ s: ReviewedSnapshot, steps: Int = 400) async throws -> WriteOutcome {
        let api = api
        return try await serve(steps: steps) { try await api.answer(s, option: "approve") }
    }
    func rows(_ sql: String) async throws -> [SQLRow] { try await p.container.database().query(sql) }
}

@Suite struct DevSandboxLaneTests {
    // MARK: derive

    @Test func deriveMatrix() async throws {
        func ctx(_ origin: String = devOrigin) throws -> RealmContext { try RealmContext.liveDevSandbox(origin: origin, enabler: DevSandboxLaneEnabler()) }
        // the variant's own context refuses any other origin; a plain Live context on another origin gets no lane either
        #expect(throws: RealmViolation.self) { try ctx("https://relay.example.org") }
        func software(_ realm: Realm = .live) throws -> DeviceIdentity { DeviceIdentity(sig: try SoftwareSigner(), kx: try SoftwareKeyAgreer(), realm: realm, custody: .software) }
        let level1 = ReaderRuntime.production
        let level0 = ReaderRuntime(capability: nil, build: "t")
        #expect(level1.level >= 1)
        func derive(_ id: DeviceIdentity, _ c: RealmContext, enabler: Bool = true, reader: ReaderRuntime = level1) throws -> PersonEventPolicy? {
            PersonEventPolicy.derive(identity: id, context: c, grant: nil, transport: try LiveTransport.testingTransport(context: c, sender: StubSender(origin: c.origin)),
                                     enabler: enabler ? DevSandboxLaneEnabler() : nil, reader: reader)
        }
        let c = try ctx()
        let ok = try #require(try derive(try software(), c))
        #expect(ok.auth == .convenience && ok.lane == .devSandbox && ok.realm == .live)
        #expect(try derive(try software(), c, enabler: false) == nil)              // no enabler (the normal app)
        #expect(try derive(try software(), c, reader: level0) == nil)             // reader level 0
        #expect(try derive(try software(.demo), c) == nil)                        // a Demo identity in a Live context
        #expect(try derive(try software(), try RealmContext.live(origin: "https://relay.example.org")) == nil)   // the wrong origin
        #expect(throws: (any Error).self) { try ctx("http://127.0.0.1:8123") }              // owner ruling 15 Oct: no http loopback in the app
        #expect(throws: (any Error).self) { try ctx("http://[::1]:8123") }
        #expect(throws: (any Error).self) { try ctx("http://localhost:8123") }
        // a Demo context never gets the lane, whatever the enabler says
        let world = try await World.make()
        let dctx = world.env.context
        #expect(PersonEventPolicy.derive(identity: world.env.device, context: dctx, grant: nil, transport: world.env.transport,
                                         enabler: DevSandboxLaneEnabler(), reader: level1) == nil)
        // a Secure-Enclave-tagged identity is `derive`'s: secure-enclave-unlocked, never the lane
        let se = DeviceIdentity(sig: try SoftwareSigner(), kx: try SoftwareKeyAgreer(), realm: .live, custody: .secureEnclave)
        #expect(try derive(se, c)?.auth == .secureEnclaveUnlocked)
        #expect(try derive(se, c)?.lane == .live)
    }

    // MARK: whoami `relay.dev` parse

    @Test func relayDevParsesLeniently() throws {
        func support(_ dev: JSONValue?) -> HostWriteSupport? {
            var relay: [String: JSONValue] = ["ops": ["answer": 1], "r6_ready": true]
            if let dev { relay["dev"] = dev }
            return HostWriteSupport(.object(relay))
        }
        #expect(support(["sim_convenience": true, "sandbox": "0123abcd"])?.dev?.sandbox == "0123abcd")
        for bad: JSONValue? in [nil, ["sim_convenience": false, "sandbox": "0123abcd"], ["sim_convenience": 1, "sandbox": "0123abcd"],
                                ["sim_convenience": "true", "sandbox": "0123abcd"], ["sim_convenience": true], ["sim_convenience": true, "sandbox": "0123ABCD"],
                                ["sim_convenience": true, "sandbox": "0123abc"], ["sim_convenience": true, "sandbox": "0123abcde"],
                                ["sim_convenience": true, "sandbox": 5], "yes", .null, []] {
            let s = support(bad)
            #expect(s?.dev == nil)
            #expect(s?.allows("answer") == true)       // the rest of the read is untouched
        }
    }

    // MARK: transport

    @Test func theTransportChecksTheLaneAndTheRoute() async throws {
        let wsA = ID16(hex: "00112233445566778899aabbccddeeff")!, wsB = ID16(hex: "ffeeddccbbaa99887766554433221100")!
        let rid = ID16(hex: "0102030405060708090a0b0c0d0e0f10")!
        let session = RelaySession(token: "tok")
        func transport(origin: String = devOrigin) throws -> (RoutedRelayTransport<StubSender>, RealmContext) {
            let c = origin == devOrigin ? try RealmContext.liveDevSandbox(origin: origin, enabler: DevSandboxLaneEnabler()) : try RealmContext.live(origin: origin)
            return (try RoutedRelayTransport(context: c, origin: origin, sender: StubSender(origin: origin), clientAddress: "t"), c)
        }
        let (t, c) = try transport()
        func permit(_ ws: ID16?, auth: F1Auth = .convenience, ctx: RealmContext = c) -> WritePermit {
            .forTesting(auth: auth, realm: .live, generation: ctx.generation, devSandboxWorkspace: ws)
        }
        func post(_ p: WritePermit?, route ws: ID16, on t: RoutedRelayTransport<StubSender>) async -> Bool {
            do { _ = try await t.bridgePost(Data([1]), route: BridgeRoute(workspaceID: ws, requestID: rid), session: session, permit: p); return true } catch { return false }
        }
        #expect(await post(permit(wsA), route: wsA, on: t))                 // the lane's own permit, its own route: passes the checks (the relay may still say no)
        #expect(await !post(permit(wsA), route: wsB, on: t))                // a permit for workspace A on route B
        #expect(await !post(permit(nil), route: wsA, on: t))                // convenience without the lane
        #expect(await !post(permit(wsA, auth: .passphrase), route: wsA, on: t))
        #expect(await post(permit(nil, auth: .secureEnclaveUnlocked), route: wsA, on: t))     // SE unchanged
        // a convenience permit over a transport on any other origin
        let (other, oc) = try transport(origin: "https://relay.example.org")
        #expect(await !post(permit(wsA, ctx: oc), route: wsA, on: other))
        // over Demo's in-process sender
        let world = try await World.make()
        let dt = world.env.transport
        let dp = WritePermit.forTesting(auth: .convenience, realm: .demo, generation: world.env.context.generation, devSandboxWorkspace: wsA)
        do { _ = try await dt.bridgePost(Data([1]), route: BridgeRoute(workspaceID: wsA, requestID: rid), session: session, permit: dp); Issue.record("sent") } catch {}
        // PhoneActor: lane builds only
        #expect(throws: Never.self) { _ = try PhoneActor(person: wsA, device: wsB, auth: .convenience) }
    }

    // MARK: session

    @Test func aFreshReadOpensEveryReviewAndTheConvenienceAnswerLands() async throws {
        let r = try await LaneRig.make()
        #expect(await r.p.session.policy?.lane == .devSandbox)
        let q = try await r.firstQuestion()
        let before = r.ops.value("whoami")
        _ = try await r.review(q)
        #expect(r.ops.value("whoami") == before + 1)                          // +1 per review
        let review = try await r.review(q)
        #expect(r.ops.value("whoami") == before + 2)
        let snap = try #require(review.snapshot)
        #expect(snap.devSandbox == id8)
        let out = try await r.answer(snap)
        guard case .landed = out else { Issue.record("\(out)"); return }
        #expect(try await r.rows("SELECT auth FROM pe_attempts").first?.text("auth") == "convenience")
        #expect(r.ops.value("answer") == 1 && r.hooks.count("pe.sign") == 1)
    }

    @Test func hostThatStoppedOfferingGivesNoSheetAndNothingSigned() async throws {
        let r = try await LaneRig.make()
        let q = try await r.firstQuestion()
        _ = try await r.review(q)
        await r.w.host.setDevSimConvenience(nil)                              // dev turned off between two reviews
        await #expect(throws: ViewError.hostRefusesSimulator) { _ = try await r.review(q) }
        #expect(r.hooks.count("pe.sign") == 0 && r.ops.value("answer") == 0)
        #expect(await r.p.session.currentHostSupport?.dev == nil)             // the cache followed the read
        #expect(await !r.api.writesAvailable())                               // so the screen shows the exact refusal text
        #expect(DevSandboxLane.hostRefusesText == "This host does not accept Simulator answers")
        // no field at all (an old host), and a failed read
        await r.w.host.setRelayCaps(.absent)
        await #expect(throws: ViewError.hostRefusesSimulator) { _ = try await r.review(q) }
    }

    @Test func aFailedWhoamiReadIsNoGrantAndOtherReadsStillWork() async throws {
        let r = try await LaneRig.make(serve: { req, _ in req.meta.object?["op"]?.string == "whoami" ? .refuse(.malformed) : nil })
        let q = try await r.firstQuestion()                                   // a snapshot works
        await #expect(throws: ViewError.hostRefusesSimulator) { _ = try await r.review(q) }
        #expect(r.hooks.count("pe.sign") == 0 && r.ops.value("answer") == 0)
    }

    @Test func gateDroppingAfterTheTapIsClassDWithoutAResign() async throws {
        let r = try await LaneRig.make()
        let q = try await r.firstQuestion()
        let snap = try #require(try await r.review(q).snapshot)
        await r.w.host.setDevSimConvenience(nil)                              // the host restarted without the flag, after the review
        let out = try await r.answer(snap)
        guard case .refused(let code) = out else { Issue.record("\(out)"); return }
        #expect(code == "op.not_allowed")
        #expect(r.hooks.count("pe.sign") == 1 && r.ops.value("answer") == 1)  // signed once, sent once, never signed again
        #expect(try await r.rows("SELECT * FROM pe_attempts").count == 1)
    }

    @Test func aSentAnswerIsSettledAfterTheGateWentOff() async throws {
        let r = try await LaneRig.make()
        await r.w.host.demoLoseNextWriteResponse()
        let q = try await r.firstQuestion()
        let snap = try #require(try await r.review(q).snapshot)
        let first = try await r.answer(snap)
        if case .landed = first {} else {
            await r.w.host.setDevSimConvenience(nil)
            let id = try #require(try await r.rows("SELECT review FROM pe_reviews").first?.text("review"))
            let p = r.p
            let out = try await r.serve { try await p.session.settle(reviewID: id) }
            guard case .landed = out else { Issue.record("\(out)"); return }     // a settlement read is never blocked
        }
        #expect(r.hooks.count("pe.sign") == 1)
    }

    @Test func anAutomaticResignReadsTheGateFirst() async throws {
        let r = try await LaneRig.make()
        let q = try await r.firstQuestion()
        let snap = try #require(try await r.review(q).snapshot)
        await r.w.host.demoBumpMembersV()                                     // members.stale: C-auto
        let before = r.ops.value("whoami")
        let out = try await r.answer(snap)
        guard case .landedAfterResign = out else { Issue.record("\(out)"); return }
        #expect(r.ops.value("whoami") == before + 1)                          // the re-sign asked first
        #expect(r.hooks.count("pe.sign") == 2)
    }

    @Test func noGrantNoAutomaticResign() async throws {
        let r = try await LaneRig.make(serve: { req, host in
            // the host stops offering Simulator answers right after it answered the first write with members.stale
            if req.meta.object?["op"]?.string == "answer" { await host.setDevSimConvenience(nil) }
            return nil
        })
        let q = try await r.firstQuestion()
        let snap = try #require(try await r.review(q).snapshot)
        await r.w.host.demoBumpMembersV()
        let out = try await r.answer(snap)
        // the first write is refused (op.not_allowed or members.stale); nothing is signed a second time without a fresh grant
        #expect(r.hooks.count("pe.sign") == 1)
        if case .landedAfterResign = out { Issue.record("re-signed without a grant") }
    }

    @Test func creationIsNotOnTheLane() async throws {
        let r = try await LaneRig.make()
        #expect(await !r.api.writesAvailable(op: "new_ticket"))
        await #expect(throws: ViewError.writesUnavailable) { _ = try await r.api.reviewCreation(type: "bug", title: "x") }
    }

    @Test func noEnablerOrNoReaderMeansNoLane() async throws {
        let none = try await LaneRig.make(enabler: false)
        #expect(await none.p.session.policy == nil)
        #expect(await !none.api.writesAvailable())
        let level0 = try await LaneRig.make(reader: ReaderRuntime(capability: nil, build: "t"))
        #expect(await level0.p.session.policy == nil)
        #expect(level0.ops.value("answer") == 0)
    }
}
#endif
