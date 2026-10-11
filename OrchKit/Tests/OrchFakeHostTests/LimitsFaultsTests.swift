import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
@testable import OrchProtocol

@Suite struct LimitsFaultsTests {
    func pairPost(_ w: World, offer: ID16, rid: ID16, address: String = "198.51.100.7", seq: UInt64 = 1, ws: ID16? = nil) async throws -> WireReply {
        let env = try w.envelope(workspace: ws, rid: rid, seq: seq, epoch: 0, stream: offer)
        return try await w.relay.send(WireRequest(method: "POST", target: "/v2/workspaces/\((ws ?? w.ws).hex)/pair/\(offer.hex)/\(rid.hex)",
                                                  headers: [:], body: env, clientAddress: address))
    }

    func pairPoll(_ w: World, offer: ID16, rid: ID16, address: String = "198.51.100.7") async throws -> WireReply {
        try await w.relay.send(WireRequest(method: "GET", target: "/v2/workspaces/\(w.ws.hex)/pair/\(offer.hex)/\(rid.hex)",
                                           headers: [:], clientAddress: address))
    }

    // MARK: pairing route and limits

    @Test func pairingRouteChecksHeaderAndNeedsNoBearer() async throws {
        let w = try await World.make()
        let offer = ID16.fresh(0x71), rid = ID16.fresh(0x72)
        #expect(try await pairPost(w, offer: offer, rid: rid).status == 202)
        // route != header
        let env = try w.envelope(rid: rid, seq: 2, epoch: 0, stream: offer)
        func raw(_ target: String, body: Data) async throws -> WireReply {
            try await w.relay.send(WireRequest(method: "POST", target: target, headers: [:], body: body, clientAddress: "x"))
        }
        let base = "/v2/workspaces/\(w.ws.hex)/pair"
        #expect(try await raw("\(base)/\(ID16.fresh(0x73).hex)/\(rid.hex)", body: env).status == 400)          // offer != stream
        #expect(try await raw("\(base)/\(offer.hex)/\(ID16.fresh(0x74).hex)", body: env).status == 400)        // rid != header rid
        #expect(try await raw("/v2/workspaces/\(ID16.fresh(0x75).hex)/pair/\(offer.hex)/\(rid.hex)", body: env).status == 400)   // ws
        // epoch 1 on the pairing route; direction 2 without the host session; oversize (64 KiB)
        let e1 = try w.envelope(rid: rid, seq: 3, epoch: 1, stream: offer)
        #expect(try await raw("\(base)/\(offer.hex)/\(rid.hex)", body: e1).status == 400)
        let resp = try w.envelope(direction: .toDevice, rid: rid, seq: 0, epoch: 0, flags: [.last], stream: offer)
        #expect(try await raw("\(base)/\(offer.hex)/\(rid.hex)", body: resp).status == 401)         // a host answer needs W(g)
        let big = try w.envelope(rid: rid, seq: 4, epoch: 0, stream: offer, payload: 64 * 1024)
        #expect(big.count > 64 * 1024)
        #expect(try await raw("\(base)/\(offer.hex)/\(rid.hex)", body: big).status == 400)
        // unknown workspace
        let other = ID16.fresh(0x76)
        let unk = try await pairPost(w, offer: offer, rid: rid, ws: other)
        #expect(unk.status == 401 && errorCode(unk) == "unknown_workspace")
        // The host answers with its workspace session; the phone polls without a bearer and anyone with the ids can read ciphertext.
        let answer = try w.envelope(direction: .toDevice, rid: rid, seq: 0, epoch: 0, flags: [.last], stream: offer, signer: SoftwareSigner())
        let posted = try await w.transport.pairingPost(answer, route: PairRoute(workspaceID: w.ws, offerID: offer, requestID: rid))
        #expect(posted.status == 401 && errorCode(posted) == "unauthenticated")      // still no bearer: pairingPost sends none
        let bearer = try await w.relay.send(WireRequest(method: "POST", target: "\(base)/\(offer.hex)/\(rid.hex)",
                                                        headers: ["Authorization": "Bearer " + w.hostSession.token], body: answer, clientAddress: "h"))
        #expect(bearer.status == 202)
        let polled = try chunkList(try await w.transport.pairingPoll(route: PairRoute(workspaceID: w.ws, offerID: offer, requestID: rid), after: nil))
        #expect(polled.count == 1 && polled[0].idx == 0 && polled[0].last && polled[0].envelope == answer)
        #expect(try chunkList(try await w.transport.pairingPoll(route: PairRoute(workspaceID: w.ws, offerID: offer, requestID: rid), after: 0)).isEmpty)
        // The host sees the epoch-0 request.
        let pending = try await w.relay.pendingPairRequests(workspace: w.ws, offer: offer, token: w.hostSession.token)
        #expect(pending.count == 1 && pending[0].rid == rid)
        // A bad bearer on the pairing route is refused rather than treated as anonymous.
        let badBearer = try await w.relay.send(WireRequest(method: "POST", target: "\(base)/\(offer.hex)/\(rid.hex)", headers: ["Authorization": "Bearer zzz"],
                                                           body: try w.envelope(rid: rid, seq: 9, epoch: 0, stream: offer), clientAddress: "h"))
        #expect(badBearer.status == 401)
    }

    @Test func pairingPostLimitsPerWorkspaceAndPerAddress() async throws {
        var l = RelayLimits(); l.pairPostsPerMinutePerWorkspace = 5; l.pairPostsPerMinutePerAddress = 100
        let w = try await World.make(limits: l)
        let offer = ID16.fresh(0x81)
        for i in 0..<5 { #expect(try await pairPost(w, offer: offer, rid: ID16.fresh(UInt8(i + 1)), address: "a\(i)", seq: 1).status == 202) }
        let limited = try await pairPost(w, offer: offer, rid: ID16.fresh(0x20), address: "fresh")
        #expect(limited.status == 429 && errorCode(limited) == "rate_limited" && limited.header("Retry-After") == "5" && hostAPI(limited) == nil)
        #expect(HostAPI.failure(of: limited) == .relay(RelayRefusal(status: 429, code: .rateLimited, retryAfter: 5)))
        // A limited request stores nothing; the window frees on the injected clock, not the real one.
        #expect(try await w.relay.pendingPairRequests(workspace: w.ws, offer: offer, token: w.hostSession.token).count == 5)
        w.clock.advance(milliseconds: 59_999)
        #expect(try await pairPost(w, offer: offer, rid: ID16.fresh(0x21), address: "fresh").status == 429)
        w.clock.advance(milliseconds: 1)
        #expect(try await pairPost(w, offer: offer, rid: ID16.fresh(0x22), address: "fresh").status == 202)

        var l2 = RelayLimits(); l2.pairPostsPerMinutePerAddress = 4; l2.pairPostsPerMinutePerWorkspace = 100; l2.pairPollsPerMinutePerAddress = 3
        let w2 = try await World.make(limits: l2)
        for i in 0..<4 { #expect(try await pairPost(w2, offer: offer, rid: ID16.fresh(UInt8(i + 1)), address: "same").status == 202) }
        #expect(try await pairPost(w2, offer: offer, rid: ID16.fresh(0x30), address: "same").status == 429)
        #expect(try await pairPost(w2, offer: offer, rid: ID16.fresh(0x30), address: "other").status == 202)
        for _ in 0..<3 { #expect(try await pairPoll(w2, offer: offer, rid: ID16.fresh(1), address: "same").status == 200) }
        let pl = try await pairPoll(w2, offer: offer, rid: ID16.fresh(1), address: "same")
        #expect(pl.status == 429 && pl.header("retry-after") == "5")
        #expect(try await pairPoll(w2, offer: offer, rid: ID16.fresh(1), address: "other").status == 200)
        #expect(await w2.relay.rateLimited == 2)
    }

    @Test func defaultLimitsAreSixtyPostsAndOneTwentyPolls() {
        let l = RelayLimits()
        #expect(l.pairPostsPerMinutePerWorkspace == 60 && l.pairPostsPerMinutePerAddress == 60 && l.pairPollsPerMinutePerAddress == 120)
        #expect(l.retryAfterSeconds == 5 && l.maxPairEnvelope == 65_536 && l.sessionLifetimeMs == 900_000 && l.bodyLifetimeMs == 60_000)
    }

    @Test func anHonestTenMinutePairingRunNeverHitsALimit() async throws {
        // One phone: a pair_status POST and a GET every 5 s, plus an initial pair and resends, for 10 minutes,
        // sharing the workspace budget with a second honest phone and the address budget with the first.
        let w = try await World.make()
        let offer = ID16.fresh(0x91)
        var n: UInt8 = 0
        var posts = 0, polls = 0
        for second in stride(from: 0, to: 600, by: 5) {
            _ = second
            n &+= 1
            let rid = ID16(bytes: Data(repeating: n, count: 8) + Data(repeating: UInt8(posts & 0xff), count: 8))!
            #expect(try await pairPost(w, offer: offer, rid: rid).status == 202)
            #expect(try await pairPoll(w, offer: offer, rid: rid).status == 200)
            posts += 1; polls += 1
            w.clock.advance(milliseconds: 5_000)
        }
        #expect(posts == 120 && polls == 120)
        #expect(await w.relay.rateLimited == 0)
        // Even a 3x burst on top of the 5 s cadence fits the per-minute window (36/min vs 60).
        for i in 0..<24 { #expect(try await pairPost(w, offer: offer, rid: ID16.fresh(UInt8(200 + i % 50)), seq: UInt64(i + 2)).status == 202) }
        #expect(await w.relay.rateLimited == 0)
    }

    @Test func mailboxQuotaPerDeviceCountsLiveMailboxesOnly() async throws {
        var l = RelayLimits(); l.maxLiveMailboxesPerDevice = 3
        let w = try await World.make(limits: l)
        func post(_ n: UInt8) async throws -> WireReply {
            try await w.transport.bridgePost(try w.envelope(rid: ID16.fresh(n), seq: UInt64(n)), route: BridgeRoute(workspaceID: w.ws, requestID: ID16.fresh(n)), session: w.phoneSession)
        }
        for n in 1...3 { #expect(try await post(UInt8(n)).status == 202) }
        let over = try await post(4)
        #expect(over.status == 429 && errorCode(over) == "quota_exceeded" && over.header("retry-after") == "5")
        #expect(HostAPI.failure(of: over) == .relay(RelayRefusal(status: 429, code: .quotaExceeded, retryAfter: 5)))
        // A re-send into an existing mailbox does not count again.
        #expect(try await post(2).status == 202)
        #expect(await w.relay.liveMailboxCount(workspace: w.ws, device: w.phoneID) == 3)
        w.clock.advance(milliseconds: 60_000)                         // sealed bodies are gone, so is their quota
        #expect(try await post(4).status == 202)
    }

    // MARK: faults

    @Test func faultDropBeforeQueueLosesTheRequestCleanly() async throws {
        let faults = ScriptedFaults().enqueue(.drop, at: .beforeQueue)
        let w = try await World.make(faults: faults)
        let rid = ID16.fresh(0xA1)
        let route = BridgeRoute(workspaceID: w.ws, requestID: rid)
        let env = try w.envelope(rid: rid)
        await #expect(throws: TransportError.disconnected) { _ = try await w.transport.bridgePost(env, route: route, session: w.phoneSession) }
        #expect(try await w.relay.pendingRequests(workspace: w.ws, token: w.hostSession.token).isEmpty)
        #expect(try await w.transport.bridgePost(env, route: route, session: w.phoneSession).status == 202)       // the retry is the first delivery
        #expect(faults.remaining == 0)
    }

    @Test func faultDropAfterCommitKeepsTheRequestAndRetryIsIdempotent() async throws {
        let faults = ScriptedFaults().enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "POST /v2/workspaces")
        let w = try await World.make(faults: faults)
        let rid = ID16.fresh(0xA2)
        let route = BridgeRoute(workspaceID: w.ws, requestID: rid)
        let env = try w.envelope(rid: rid)
        await #expect(throws: TransportError.disconnected) { _ = try await w.transport.bridgePost(env, route: route, session: w.phoneSession) }
        #expect(try await w.relay.pendingRequests(workspace: w.ws, token: w.hostSession.token).count == 1)     // committed
        #expect(try await w.transport.bridgePost(env, route: route, session: w.phoneSession).status == 202)
        #expect(try await w.relay.pendingRequests(workspace: w.ws, token: w.hostSession.token).count == 1)     // byte-identical resend: still one
    }

    @Test func faultDuplicateStoresOnceButCountsTwiceAgainstTheLimiter() async throws {
        let faults = ScriptedFaults().enqueue(.duplicate, at: .beforeQueue)
        var l = RelayLimits(); l.pairPostsPerMinutePerWorkspace = 3
        let w = try await World.make(faults: faults, limits: l)
        let offer = ID16.fresh(0xA3)
        #expect(try await pairPost(w, offer: offer, rid: ID16.fresh(1)).status == 202)       // consumes 2 of 3
        #expect(try await w.relay.pendingPairRequests(workspace: w.ws, offer: offer, token: w.hostSession.token).count == 1)
        #expect(try await pairPost(w, offer: offer, rid: ID16.fresh(2)).status == 202)
        #expect(try await pairPost(w, offer: offer, rid: ID16.fresh(3)).status == 429)
    }

    @Test func faultDelayWaitsOnTheInjectedClock() async throws {
        let faults = ScriptedFaults().enqueue(.delay(.seconds(30)), at: .beforeQueue)
        let w = try await World.make(faults: faults)
        let rid = ID16.fresh(0xA4)
        let route = BridgeRoute(workspaceID: w.ws, requestID: rid)
        let env = try w.envelope(rid: rid)
        let t = w.transport, s = w.phoneSession
        let task = Task { try await t.bridgePost(env, route: route, session: s) }
        let clock = w.clock
        await eventually("the delayed post parks on the injected clock") { clock.sleeperCount == 1 }
        #expect(try await w.relay.pendingRequests(workspace: w.ws, token: w.hostSession.token).isEmpty)
        w.clock.advance(by: .seconds(29))
        await settleBriefly(yields: 20, minMs: 50)               // negative: a slow runner must not let the 29 s look like 30
        #expect(w.clock.sleeperCount == 1)
        w.clock.advance(by: .seconds(1))
        #expect(try await task.value.status == 202)
        #expect(try await w.relay.pendingRequests(workspace: w.ws, token: w.hostSession.token).count == 1)
    }

    @Test func pollFaultsDuplicateReorderCorruptAndDrop() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let rid = ID16.fresh(0xA5)
        let route = BridgeRoute(workspaceID: w.ws, requestID: rid)
        let rig = HostRig()
        var sent: [Data] = []
        for seq in 0..<3 {
            let e = try w.sealedResponse(rig: rig, rid: rid, seq: UInt64(seq), flags: seq == 2 ? [.last] : [])
            #expect(try await w.transport.bridgePost(e, route: route, session: w.hostSession).status == 202)
            sent.append(e)
        }
        func poll() async throws -> [HostAPI.Chunk] { try chunkList(try await w.transport.bridgePoll(route: route, after: nil, session: w.phoneSession)) }
        faults.enqueue(.duplicate, at: .pollDelivery)
        #expect(try await poll().map(\.idx) == [0, 0, 1, 1, 2, 2])
        faults.enqueue(.reorder, at: .pollDelivery)
        #expect(try await poll().map(\.idx) == [2, 1, 0])
        // An uncorrupted poll verifies first: every chunk is accepted by the device's section 8.8 check, in order.
        let clean = try await poll()
        for (i, c) in clean.enumerated() {
            guard case .accept = w.check(c.envelope, rig: rig, rid: rid, index: UInt64(i), last: c.last) else { Issue.record("chunk \(i) must verify"); return }
        }
        faults.enqueue(.corrupt, at: .pollDelivery)
        let c = try await poll()
        #expect(c[0].envelope != sent[0] && c[1].envelope == sent[1] && c[0].envelope.count == sent[0].count)
        // The relay cannot tell (it is still well-formed ORB2), but the host's signature no longer verifies: the device drops it.
        guard case .drop(.hostSignature) = w.check(c[0].envelope, rig: rig, rid: rid, index: 0, last: false) else {
            Issue.record("a corrupted chunk must fail the host signature check"); return
        }
        guard case .accept = w.check(c[1].envelope, rig: rig, rid: rid, index: 1, last: false) else { Issue.record("untouched chunk must verify"); return }
        faults.enqueue(.drop, at: .pollDelivery)
        await #expect(throws: TransportError.disconnected) { _ = try await poll() }
        #expect(try await poll().map(\.idx) == [0, 1, 2])           // nothing was consumed by any of this
        #expect(faults.remaining == 0)
    }

    @Test func faultBeforeMembershipPublicationCommitsNothing() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let keys = DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey)
        try await w.relay.publishCertificate(try await w.primary.certify(keys, label: "N", scopesMax: ["look"]))
        faults.enqueue(.drop, at: .beforeMembershipPublication)
        let roster = w.baseRoster + [(keys, ["look"])]
        await #expect(throws: TransportError.disconnected) { try await w.publish(roster, epoch: 1, listSeq: 2, wraps: [keys]) }
        #expect(await w.relay.hasGrant(workspace: w.ws, device: keys.deviceID, epoch: 1) == false)
        #expect(await w.relay.memberListSeq(workspace: w.ws) == 1)
        // The identical bytes again: committed once, list, grant and wrap together.
        try await w.publish(roster, epoch: 1, listSeq: 2, wraps: [keys])
        #expect(await w.relay.hasGrant(workspace: w.ws, device: keys.deviceID, epoch: 1))
        #expect(await w.relay.hasCardKeyWrap(workspace: w.ws, device: keys.deviceID, cardSeq: 1))
        #expect(await w.relay.memberListSeq(workspace: w.ws) == 2)
    }

    /// A reply lost after the commit (section 19.7): the exact bytes again answer the committed result before any freshness check,
    /// even once the card moved on and a member's certificate expired.
    @Test func lostMembershipReplyRetriesWithTheExactBytes() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let keys = DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey)
        try await w.relay.publishCertificate(try await w.primary.certify(keys, label: "N", scopesMax: ["look"], lifetimeMs: 60_000))
        let body = try await w.host.membershipBody(roster: w.baseRoster + [(keys, ["look"])], epoch: 1, listSeq: 2, wraps: [keys])
        faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "PUT /v2/workspaces/\(w.ws.hex)/membership")
        await #expect(throws: TransportError.disconnected) { try await w.host.sendMembership(body, relay: w.relay, session: w.hostSession) }
        #expect(await w.relay.memberListSeq(workspace: w.ws) == 2)
        w.clock.advance(milliseconds: 60_000)                // the new member's certificate has expired
        let r = try await w.host.sendMembership(body, relay: w.relay, session: w.hostSession)
        #expect(r.listSeq == 2 && r.epoch == 1)
        // Other bytes for the same sequence are not a retry.
        let other = try await w.host.membershipBody(roster: w.baseRoster, epoch: 1, listSeq: 2)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 409, code: .staleList))) {
            try await w.host.sendMembership(other, relay: w.relay, session: w.hostSession)
        }
    }

    // MARK: Demo reset scope

    @Test func resetErasesOnlyTheDemoRealm() async throws {
        let w = try await World.make()
        let live = try w.custody.create(realm: .live)
        try w.vault.put(Data([1]), for: SecretID(realm: .live, ws: ID16.fresh(1).hex, purpose: "wk"))
        try w.vault.put(Data([2]), for: SecretID(realm: .demo, ws: ID16.fresh(2).hex, purpose: "wk"))
        try await DemoSetup.reset(w.env, custody: w.custody, vaults: [w.vault])
        #expect(w.custody.status(realm: .demo) == .missing)
        #expect(w.custody.status(realm: .live) == .present)
        #expect(try w.custody.load(realm: .live).publicKeys.sig == live.publicKeys.sig)
        #expect(try w.vault.ids().allSatisfy { $0.realm == .live })
        // Fresh Demo keys after reset are not the old ones.
        let again = try await DemoSetup.setup(layout: tempLayout(), custody: w.custody, clock: w.clock, wall: w.clock)
        #expect(again.device.publicKeys.sig != w.env.device.publicKeys.sig)
        #expect(again.deviceID != w.phoneID)
    }
}
