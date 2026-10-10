import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
@testable import OrchProtocol

@Suite struct RelayTests {
    // MARK: bridge routes (protocol 8.9)

    @Test func testRelayHeaderSessionBinding() async throws {
        let w = try await World.make()
        let rid = ID16.fresh(0x21)
        let route = BridgeRoute(workspaceID: w.ws, requestID: rid)
        let t = w.transport

        // The header's device is the session's device, the route matches the header, the mailbox id is the rid.
        let ok = try await t.bridgePost(try w.envelope(rid: rid), route: route, session: w.phoneSession)
        #expect(ok.status == 202)
        #expect(hostAPI(ok) == .int(0) && ok.body == HostAPI.json())

        // Another device's id in the header, with this device's session.
        let spoof = try await t.bridgePost(try w.envelope(device: w.primaryID, rid: rid, seq: 2), route: route, session: w.phoneSession)
        #expect(spoof.status == 403 && errorCode(spoof) == "not_for_this_device")
        // Route and header disagree on workspace, or on rid.
        let otherWS = ID16.fresh(0x55)
        let r1 = try await t.bridgePost(try w.envelope(rid: rid, seq: 3), route: BridgeRoute(workspaceID: otherWS, requestID: rid), session: w.phoneSession)
        #expect(r1.status == 400 && errorCode(r1) == "malformed")
        let r2 = try await t.bridgePost(try w.envelope(rid: ID16.fresh(0x22), seq: 4), route: route, session: w.phoneSession)
        #expect(r2.status == 400 && errorCode(r2) == "malformed")
        // A pairing envelope (epoch 0) never travels on the authenticated bridge route.
        let r3 = try await t.bridgePost(try w.envelope(rid: rid, seq: 5, epoch: 0, stream: ID16.fresh(1)), route: route, session: w.phoneSession)
        #expect(r3.status == 400)
        // A response envelope from a device session is not a request.
        let r4 = try await t.bridgePost(try w.envelope(direction: .toDevice, rid: rid, seq: 6, flags: [.last]), route: route, session: w.phoneSession)
        #expect(r4.status == 400)
        // No bearer, and a bearer that is not ours.
        let r5 = try await t.bridgePost(try w.envelope(rid: rid), route: route, session: RelaySession(token: "nope"))
        #expect(r5.status == 401 && errorCode(r5) == "unauthenticated" && hostAPI(r5) == .int(0))
        // Suite 1 header and a damaged magic.
        var bad = try w.envelope(rid: rid, seq: 7); bad[7] = 1
        #expect(errorCode(try await t.bridgePost(bad, route: route, session: w.phoneSession)) == "wrong_suite")
        var badMagic = try w.envelope(rid: rid, seq: 8); badMagic[0] = 0x4F ^ 1
        #expect(errorCode(try await t.bridgePost(badMagic, route: route, session: w.phoneSession)) == "malformed")
        // A request seq above 2^53-1 cannot be polled back as a JSON integer, so it is refused at the door.
        let big = try await t.bridgePost(try w.envelope(rid: rid, seq: UInt64(maxSafeInt) + 1), route: route, session: w.phoneSession)
        #expect(big.status == 400)
        // Request mailbox visible to the host only, by workspace session; only the good request is in it.
        let pending = try await w.relay.pendingRequests(workspace: w.ws, token: w.hostSession.token)
        #expect(pending.count == 1 && pending[0].device == w.phoneID && pending[0].rid == rid)
        await #expect(throws: ClientError.adapter(.unauthenticated)) { _ = try await w.relay.pendingRequests(workspace: w.ws, token: w.phoneSession.token) }

        // A device that is not in the member list cannot even queue; a removed or revoked one neither.
        let stranger = SoftwareSigner(), strangerKX = SoftwareKeyAgreer()
        let strangerKeys = DemoKeys(sig: stranger.publicKey, kx: strangerKX.publicKey)
        let cert = try await w.primary.certify(strangerKeys, label: "Other", scopesMax: ["look"])
        try await w.relay.publishCertificate(cert)
        let sid = Identifiers.deviceID(stranger.publicKey)
        let ch = try HostAPI.challenge(try HostAPI.expect(try await t.challenge()))
        let sig = try RelayAuth.sign(stranger, origin: w.env.context.origin, challenge: ch.challenge, kind: .device, id: sid)
        let login = try HostAPI.login(try HostAPI.expect(try await t.login(HostAPI.loginBody(challenge: ch.challenge, kind: .device, id: sid, signature: sig))))
        let ns = try await t.bridgePost(try w.envelope(device: sid, rid: ID16.fresh(0x30), signer: stranger), route: BridgeRoute(workspaceID: w.ws, requestID: ID16.fresh(0x30)), session: login.session)
        #expect(ns.status == 403 && errorCode(ns) == "not_eligible")
        try await w.relay.publishRevocation(try await w.primary.revoke(device: w.phoneID))
        // Revocation ends the device's session: the old bearer is unauthenticated, and a new login is refused (403 revoked).
        let rv = try await t.bridgePost(try w.envelope(rid: ID16.fresh(0x31)), route: BridgeRoute(workspaceID: w.ws, requestID: ID16.fresh(0x31)), session: w.phoneSession)
        #expect(rv.status == 401 && errorCode(rv) == "unauthenticated")
    }

    @Test func responsesComeOnlyFromTheHostAndPollIsNonConsumingWithCursor() async throws {
        let w = try await World.make()
        let rid = ID16.fresh(0x41)
        let route = BridgeRoute(workspaceID: w.ws, requestID: rid)
        let hostSigner = SoftwareSigner()          // the relay never verifies it
        // A device session cannot post a response (direction 2), even for itself.
        let denied = try await w.transport.bridgePost(try w.envelope(direction: .toDevice, rid: rid, seq: 0, flags: [.last]), route: route, session: w.phoneSession)
        #expect(denied.status == 400)
        var ids: [UInt64] = []
        for (n, seq) in [UInt64(0), 1, UInt64(UInt32.max) + 2, UInt64(maxSafeInt)].enumerated() {
            let last = n == 3
            let e = try w.envelope(direction: .toDevice, rid: rid, seq: seq, flags: last ? [.last] : [], signer: hostSigner)
            let r = try await w.transport.bridgePost(e, route: route, session: w.hostSession)
            #expect(r.status == 202)
            ids.append(seq)
        }
        // Poll is non-consuming; the cursor is "last received", exclusive, a full UInt64.
        for _ in 0..<2 {
            let all = try chunkList(try await w.transport.bridgePoll(route: route, after: nil, session: w.phoneSession))
            #expect(all.map(\.idx) == ids && all.last!.last && !all.first!.last && all.allSatisfy { $0.id == rid && !$0.stream })
        }
        func after(_ c: UInt64?) async throws -> [UInt64] {
            try chunkList(try await w.transport.bridgePoll(route: route, after: c, session: w.phoneSession)).map(\.idx)
        }
        #expect(try await after(0) == [1, UInt64(UInt32.max) + 2, UInt64(maxSafeInt)])
        #expect(try await after(UInt64(UInt32.max)) == [UInt64(UInt32.max) + 2, UInt64(maxSafeInt)])
        #expect(try await after(UInt64(UInt32.max) + 2) == [UInt64(maxSafeInt)])
        #expect(try await after(UInt64(maxSafeInt)) == [])
        #expect(try await after(UInt64.max) == [])
        // Raw bad cursors are malformed, not silently zero.
        for q in ["after=01", "after=-1", "after=18446744073709551616", "after=", "after=1&after=2", "x=1", "after=%31"] {
            let raw = try WireRequest(method: "GET", target: "/mobile/host-api/0/workspaces/\(w.ws.hex)/bridge/\(rid.hex)?\(q)",
                                      headers: ["Orch-Host-API": "0", "Authorization": "Bearer " + w.phoneSession.token], clientAddress: "a")
            #expect(try await w.relay.send(raw).status == 400, "\(q)")
        }
        // The mailbox belongs to the device it is addressed to: a second authenticated member polling the same rid sees nothing,
        // while the addressee sees all four; and that member's own post into the same rid is a separate mailbox.
        let second = try await w.addMember()
        let theirs = try chunkList(try await w.transport.bridgePoll(route: route, after: nil, session: second.session))
        #expect(theirs.isEmpty)
        #expect(try await after(nil).count == 4)
        let own = try w.envelope(device: second.id, rid: rid, seq: 1, signer: nil)
        #expect(try await w.transport.bridgePost(own, route: route, session: second.session).status == 202)
        #expect(try chunkList(try await w.transport.bridgePoll(route: route, after: nil, session: second.session)).isEmpty)
        #expect(try await after(nil).count == 4)
        // Neither may read the host's session routes.
        await #expect(throws: ClientError.adapter(.unauthenticated)) { _ = try await w.relay.pendingRequests(workspace: w.ws, token: second.session.token) }
        // Body lifetime: 60 s after receipt the sealed bodies are gone, and the empty list means nothing, not approval.
        w.clock.advance(milliseconds: 59_999)
        #expect(try await after(nil).count == 4)
        w.clock.advance(milliseconds: 1)
        #expect(try await after(nil) == [])
    }

    @Test func testPollCursorUInt64() async throws {
        // Relay side of the cursor: a chunk index beyond 32 bits is carried as an exact JSON integer.
        let w = try await World.make()
        let rid = ID16.fresh(0x42)
        let route = BridgeRoute(workspaceID: w.ws, requestID: rid)
        let idx = UInt64(UInt32.max) + 1
        let e = try w.envelope(direction: .toDevice, rid: rid, seq: idx, flags: [.last], signer: SoftwareSigner())
        #expect(try await w.transport.bridgePost(e, route: route, session: w.hostSession).status == 202)
        let reply = try await w.transport.bridgePoll(route: route, after: UInt64(UInt32.max), session: w.phoneSession)
        #expect(String(decoding: reply.body, as: UTF8.self).contains("\"idx\":4294967296"))
        #expect(try chunkList(reply).map(\.idx) == [idx])
        #expect(try chunkList(try await w.transport.bridgePoll(route: route, after: idx, session: w.phoneSession)).isEmpty)
        // A cursor of 2^32 must not wrap to 0.
        #expect(try chunkList(try await w.transport.bridgePoll(route: route, after: UInt64(UInt32.max) + 1, session: w.phoneSession)).isEmpty)
    }

    // MARK: version boundary

    @Test func testAdapterVersionRejected() async throws {
        let w = try await World.make()
        func raw(_ method: String, _ path: String, header: String?, body: Data = Data(), bearer: String? = nil) async throws -> WireReply {
            var h: [String: String] = [:]
            if let header { h["Orch-Host-API"] = header }
            if let bearer { h["Authorization"] = "Bearer " + bearer }
            return try await w.relay.send(WireRequest(method: method, target: path, headers: h, body: body, clientAddress: "a"))
        }
        let R = "/mobile/host-api/0"
        for header in [nil, "1", "00", "", "0,1", "-0"] as [String?] {
            let r = try await raw("POST", R + "/session/challenge", header: header, body: HostAPI.json())
            #expect(r.status == 400 && errorCode(r) == "unsupported_host_api" && hostAPI(r) == .int(0), "\(String(describing: header)) \(r.status) \(String(decoding: r.body, as: UTF8.self))")
        }
        let g = try await raw("GET", "\(R)/workspaces/\(w.ws.hex)/card", header: "1", bearer: w.phoneSession.token)
        #expect(g.status == 400 && errorCode(g) == "unsupported_host_api")
        // Body version: any other value, a string, a float, or none.
        for body in [#"{"host_api":1}"#, #"{"host_api":"0"}"#, #"{"host_api":null}"#] {
            let r = try await raw("POST", R + "/session/challenge", header: "0", body: Data(body.utf8))
            #expect(r.status == 400 && errorCode(r) == "unsupported_host_api", "\(body)")
        }
        #expect(try await raw("POST", R + "/session/challenge", header: "0", body: Data("{}".utf8)).status == 400)
        #expect(try await raw("POST", R + "/session/challenge", header: "0", body: HostAPI.json()).status == 200)
        // A different base version is not a route.
        let v1 = try await raw("POST", "/mobile/host-api/1/session/challenge", header: "0", body: HostAPI.json())
        #expect(v1.status == 404)
        // Nothing here ever leaked host_api into a section 14 refusal.
        let m = try await raw("POST", R + "/session/login", header: "0", body: HostAPI.json(["challenge": 1]))
        #expect(errorCode(m) == "malformed" && hostAPI(m) == nil)
    }

    @Test func testZeroGrantEpochRejected() async throws {
        let w = try await World.make()
        let c = RelayClient(transport: w.transport)
        await #expect(throws: TransportError.invalidEpoch) { _ = try await c.grants(workspace: w.ws, epoch: 0, session: w.phoneSession) }
        let before = await w.relay.requestsReceived
        // Even a hand-built request is refused by the relay.
        for q in ["epoch=0", "epoch=00", "epoch=-1", "epoch=4294967296", "epoch=", "epoch=1&epoch=1", "other=1"] {
            let raw = try WireRequest(method: "GET", target: "/mobile/host-api/0/workspaces/\(w.ws.hex)/grants?\(q)",
                                      headers: ["Orch-Host-API": "0", "Authorization": "Bearer " + w.phoneSession.token], clientAddress: "a")
            #expect(try await w.relay.send(raw).status == 400, "\(q)")
        }
        _ = before
        // A grant for epoch 0 is not publishable either: epoch 0 is reserved for pairing envelopes.
        let zero = try await w.host.grant(for: w.phone, epoch: 0)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 400, code: .malformed))) { try await w.relay.putGrant(zero, token: w.hostSession.token) }
        // Epoch 1 is served; asking for epoch 2 is a clean not_found.
        #expect(try await c.grants(workspace: w.ws, epoch: 1, session: w.phoneSession).count == 1)
        await #expect(throws: ClientError.adapter(.notFound)) { _ = try await c.grants(workspace: w.ws, epoch: 2, session: w.phoneSession) }
        #expect(try await c.grants(workspace: w.ws, session: w.phoneSession).count == 1)
    }

    // MARK: publication order (protocol 7.2)

    @Test func testMemberListRequiresGrantsBeforePublish() async throws {
        let w = try await World.make()
        let relay = w.relay
        // A new device joins: certificate first, then (grant, CK wrap), then the list.
        let laptop2 = SoftwareSigner(), kx2 = SoftwareKeyAgreer()
        let keys2 = DemoKeys(sig: laptop2.publicKey, kx: kx2.publicKey)
        let id2 = keys2.deviceID
        let list2 = try await w.host.memberList([(w.primaryID, World.all), (w.phoneID, ["look", "decide"]), (id2, ["look"])], epoch: 1, listSeq: 2)
        // No certificate: cert_invalid (400), nothing published.
        await #expect(throws: ClientError.relay(RelayRefusal(status: 400, code: .certInvalid))) { try await relay.publishMemberList(list2, token: w.hostSession.token) }
        // No grant for a device without a certificate.
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .notEligible))) {
            try await relay.putGrant(try await w.host.grant(for: keys2, epoch: 1), token: w.hostSession.token)
        }
        #expect(await relay.grantCount(workspace: w.ws, device: id2) == 0)
        try await relay.publishCertificate(try await w.primary.certify(keys2, label: "Laptop 2", scopesMax: ["look"]))
        // Certificate but no grant: missing_grant (409), and the old list still stands.
        await #expect(throws: ClientError.relay(RelayRefusal(status: 409, code: .missingGrant))) { try await relay.publishMemberList(list2, token: w.hostSession.token) }
        #expect(await relay.memberListSeq(workspace: w.ws) == 1)
        try await relay.putGrant(try await w.host.grant(for: keys2, epoch: 1), token: w.hostSession.token)
        try await relay.publishMemberList(list2, token: w.hostSession.token)
        #expect(await relay.memberListSeq(workspace: w.ws) == 2)
        // The phone now sees the new list through the real route, and it verifies with the pinned WSK.
        let fetched = try await RelayClient(transport: w.transport).memberList(workspace: w.ws, session: w.phoneSession)
        let verified = try MemberList.verify(fetched, wsk: w.host.wskPublic)
        #expect(verified.members.map(\.deviceID).contains(id2) && verified.listSeq == 2)
        // Same list_seq again, an older one, a skipped epoch, an epoch-1 start over a later list: refused with the specific code.
        await #expect(throws: ClientError.relay(RelayRefusal(status: 409, code: .staleList))) { try await relay.publishMemberList(list2, token: w.hostSession.token) }
        let skip = try await w.host.memberList([(w.primaryID, World.all)], epoch: 3, listSeq: 3)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 409, code: .badEpoch))) { try await relay.publishMemberList(skip, token: w.hostSession.token) }
        // Removal without an epoch bump needs rotation; with the bump but no grants for the rest, missing_grant.
        let drop = try await w.host.memberList([(w.primaryID, World.all)], epoch: 1, listSeq: 3)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 409, code: .rotationRequired))) { try await relay.publishMemberList(drop, token: w.hostSession.token) }
        let rotate = try await w.host.memberList([(w.primaryID, World.all)], epoch: 2, listSeq: 3)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 409, code: .missingGrant))) { try await relay.publishMemberList(rotate, token: w.hostSession.token) }
        let primaryKeys = w.primary.deviceKeys
        try await relay.putGrant(try await w.host.grant(for: primaryKeys, epoch: 2), token: w.hostSession.token)
        // A request mailbox of a device about to be removed goes away with it.
        let rid = ID16.fresh(0x61)
        _ = try await w.transport.bridgePost(try w.envelope(rid: rid), route: BridgeRoute(workspaceID: w.ws, requestID: rid), session: w.phoneSession)
        #expect(await relay.liveMailboxCount(workspace: w.ws, device: w.phoneID) == 1)
        try await relay.publishMemberList(rotate, token: w.hostSession.token)
        #expect(await relay.liveMailboxCount(workspace: w.ws, device: w.phoneID) == 0)
        let g1 = await relay.grantCount(workspace: w.ws, device: w.phoneID), g2 = await relay.grantCount(workspace: w.ws, device: id2)
        #expect(g1 == 0 && g2 == 0)
        // Departed devices lose their routes: not_eligible.
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .notEligible))) {
            _ = try await RelayClient(transport: w.transport).card(workspace: w.ws, session: w.phoneSession)
        }
    }

    @Test func memberListChecksCertificatesScopesAndRevocation() async throws {
        let w = try await World.make()
        let relay = w.relay
        let keys = DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey)
        try await relay.publishCertificate(try await w.primary.certify(keys, label: "Narrow", scopesMax: ["look"]))
        try await relay.putGrant(try await w.host.grant(for: keys, epoch: 1), token: w.hostSession.token)
        // scopes wider than scopes_max
        let wide = try await w.host.memberList([(w.primaryID, World.all), (w.phoneID, ["look", "decide"]), (keys.deviceID, ["look", "decide"])], epoch: 1, listSeq: 2)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .scopeExceeded))) { try await relay.publishMemberList(wide, token: w.hostSession.token) }
        // list signed by another key
        let forged = try await FakeHostForgery.list(workspace: w.ws, members: [(w.primaryID, World.all), (w.phoneID, ["look", "decide"])], seq: 2)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 401, code: .badSignature))) { try await relay.publishMemberList(forged, token: w.hostSession.token) }
        // revoked member
        try await relay.publishRevocation(try await w.primary.revoke(device: keys.deviceID))
        let withRevoked = try await w.host.memberList([(w.primaryID, World.all), (w.phoneID, ["look", "decide"]), (keys.deviceID, ["look"])], epoch: 1, listSeq: 2)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .revoked))) { try await relay.publishMemberList(withRevoked, token: w.hostSession.token) }
        // a device session is not a workspace session
        await #expect(throws: ClientError.adapter(.unauthenticated)) { try await relay.publishMemberList(withRevoked, token: w.phoneSession.token) }
        // a certificate of another person is other_person
        let other = SoftwareSigner()
        await relay.registerOwner(other.publicKey)
        let foreign = try FakeHostForgery.cert(by: other, for: DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey))
        await #expect(throws: RealmViolation.crossRealmCertificate) { try await relay.publishCertificate(foreign) }   // not a Demo authority: refused by realm
    }

    // MARK: Demo isolation (C1)

    @Test func testDemoRejectsExternalOriginBeforeRequest() async throws {
        let w = try await World.make()
        let before = await w.relay.requestsReceived
        // An external relay or a live context can never be paired with the in-process transport.
        let clock = TestClock()
        let liveCtx = try RealmContext.live(origin: "https://relay.example.org")
        let liveRelay = FakeRelay(testingContext: liveCtx, clock: clock, wall: clock)
        #expect(throws: TransportError.realm(.wrongTransport)) { try InProcessRelayTransport(context: liveCtx, relay: liveRelay) }
        #expect(throws: TransportError.realm(.wrongTransport)) { try InProcessRelayTransport(context: w.env.context, relay: liveRelay) }
        #expect(throws: TransportError.realm(.wrongTransport)) { try InProcessRelayTransport(context: liveCtx, relay: w.relay) }
        // A pairing link or card naming another origin is refused by the realm before anything is sent.
        for o in ["https://relay.example.org", "http://localhost:8080", "https://relay.demo.invalid:443", "ftp://relay.demo.invalid"] {
            #expect(throws: RealmViolation.self) { try w.env.context.admit(origin: o) }
        }
        #expect(throws: RealmViolation.crossRealmRecord) { try w.env.context.admit(realm: .live) }
        // The Demo store must be a Demo layout.
        let liveLayout = try tempLayout(realm: "live")
        await #expect(throws: RealmViolation.wrongStore) {
            _ = try await DemoSetup.setup(layout: liveLayout, custody: w.custody, clock: clock, wall: clock)
        }
        #expect(await w.relay.requestsReceived == before)
        #expect(await liveRelay.requestsReceived == 0)
        // Demo's host cannot be built in a live context.
        let primary = FakePrimary(capability: DemoCapabilityForTests.mint(), wall: clock, entropy: SystemEntropy())
        #expect(throws: RealmViolation.wrongStore) {
            _ = try FakeHost(capability: DemoCapabilityForTests.mint(), context: liveCtx, primary: primary, wall: clock, entropy: SystemEntropy())
        }
    }

    @Test func testDemoCertificateCannotEnterLiveRealm() async throws {
        let w = try await World.make()
        let clock = TestClock()
        // A live realm never accepts a certificate whose owner is a Demo authority, even one that verifies perfectly.
        let live = try RealmContext.live(origin: "https://relay.example.org", pinnedOwner: nil)
        #expect(throws: RealmViolation.crossRealmCertificate) {
            _ = try live.admitCertificate(w.phoneCert, ownerKey: w.primary.publicKey, nowMs: clock.nowMs)
        }
        let pinned = try RealmContext.live(origin: "https://relay.example.org", pinnedOwner: SoftwareSigner().publicKey)
        #expect(throws: RealmViolation.crossRealmCertificate) {
            _ = try pinned.admitCertificate(w.phoneCert, ownerKey: w.primary.publicKey, nowMs: clock.nowMs)
        }
        // A live-context relay refuses to publish it, and with it any grant, card key or list entry.
        let liveRelay = FakeRelay(testingContext: live, clock: clock, wall: clock)
        await liveRelay.registerOwner(w.primary.publicKey)
        await #expect(throws: RealmViolation.crossRealmCertificate) { try await liveRelay.publishCertificate(w.phoneCert) }
        #expect(await liveRelay.hasCertificate(w.phoneID) == false)
        // And the Demo context takes only Demo authorities: a certificate from a non-Demo person fails there.
        let outsider = SoftwareSigner()
        let foreign = try FakeHostForgery.cert(by: outsider, for: w.phone)
        #expect(throws: RealmViolation.crossRealmCertificate) { _ = try w.env.context.admitCertificate(foreign, ownerKey: outsider.publicKey, nowMs: clock.nowMs) }
        // Demo accepts its own.
        let c = try w.env.context.admitCertificate(w.phoneCert, ownerKey: w.primary.publicKey, nowMs: w.clock.nowMs)
        #expect(c.deviceID == w.phoneID)
        // Device keys are per realm: the live realm in the same vault has none, and creating it gives different keys.
        #expect(w.custody.status(realm: .live) == .missing)
        let liveIdentity = try w.custody.create(realm: .live)
        #expect(liveIdentity.publicKeys.sig != w.env.device.publicKeys.sig)
        #expect(Identifiers.deviceID(liveIdentity.publicKeys.sig) != w.phoneID)
    }

    // MARK: fetch routes and the card key

    @Test func cardGrantAndCardKeyAreFetchedByTheMemberOnly() async throws {
        let w = try await World.make()
        let c = RelayClient(transport: w.transport)
        let card = try await c.card(workspace: w.ws, session: w.phoneSession)
        let verified = try Card.verify(card, ownerKey: w.primary.publicKey)
        #expect(verified.workspace == w.ws && verified.relayURL == "https://relay.demo.invalid" && verified.cardSeq == 1)
        let ck = try await c.cardKey(workspace: w.ws, cardSequence: 1, session: w.phoneSession)
        #expect(ck.device == w.phoneID && ck.workspace == w.ws && ck.cardSeq == 1)
        let key = try CardKeyWrap.open(sealed: ck.sealed, device: w.env.device.kx, deviceID: w.phoneID, workspace: w.ws, cardSeq: 1)
        let part = try Card.openSealedPart(of: verified, ck: key)
        #expect(part.name == "Laptop" && !Card.hostedMarker(card: verified, sealedPart: part).marker)
        // Grants verify with WSK and open with the device key only.
        let grants = try await c.grants(workspace: w.ws, session: w.phoneSession)
        let g = try WKGrant.open(grants[0], wsk: w.host.wskPublic, workspace: w.ws, device: w.phoneID, deviceKey: w.env.device.kx)
        #expect(g.epoch == 1)
        // Missing wrap and unknown sequence are clean 404s; a malformed sequence is a 400.
        await #expect(throws: ClientError.adapter(.notFound)) { _ = try await c.cardKey(workspace: w.ws, cardSequence: 2, session: w.phoneSession) }
        for q in ["card_seq=0", "card_seq=01", "card_seq=4294967296", "card_seq=", ""] {
            let raw = try WireRequest(method: "GET", target: "/mobile/host-api/0/workspaces/\(w.ws.hex)/card-key" + (q.isEmpty ? "" : "?" + q),
                                      headers: ["Orch-Host-API": "0", "Authorization": "Bearer " + w.phoneSession.token], clientAddress: "a")
            #expect(try await w.relay.send(raw).status == 400, "\(q)")
        }
        // A workspace the device is not in.
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .notEligible))) {
            _ = try await c.card(workspace: ID16.fresh(9), session: w.phoneSession)
        }
        // Exact reply shape of card-key.
        let raw = try await w.transport.cardKey(workspaceID: w.ws, cardSequence: 1, session: w.phoneSession)
        #expect(Set(try json(raw).keys) == ["host_api", "workspace_id", "device_id", "card_seq", "sealed"])
    }

    @Test func noGrantOrCardKeyForAnUncertifiedDevice() async throws {
        let w = try await World.make()
        let keys = DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .notEligible))) {
            try await w.relay.putCardKeyWrap(device: keys.deviceID, cardSeq: 1, sealed: try await w.host.cardKeyWrap(for: keys), token: w.hostSession.token)
        }
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .notEligible))) {
            try await w.relay.putGrant(try await w.host.grant(for: keys, epoch: 1), token: w.hostSession.token)
        }
        #expect(await w.relay.hasGrant(workspace: w.ws, device: keys.deviceID, epoch: 1) == false)
        #expect(await w.relay.hasCardKeyWrap(workspace: w.ws, device: keys.deviceID, cardSeq: 1) == false)
        // A revoked device gets none after revocation either.
        try await w.relay.publishCertificate(try await w.primary.certify(keys, label: "X", scopesMax: ["look"]))
        try await w.relay.publishRevocation(try await w.primary.revoke(device: keys.deviceID))
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .revoked))) {
            try await w.relay.putGrant(try await w.host.grant(for: keys, epoch: 1), token: w.hostSession.token)
        }
        // A card regression is stale_card.
        let again = try await w.host.card()
        await #expect(throws: ClientError.relay(RelayRefusal(status: 409, code: .staleCard))) { try await w.relay.publishCard(again) }
    }
}
