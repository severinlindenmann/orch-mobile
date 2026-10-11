import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
@testable import OrchProtocol

@Suite struct RetentionTests {
    /// Any request prunes; this one issues no challenge and opens no session.
    func ping(_ w: World) async throws {
        _ = try await w.relay.send(WireRequest(method: "GET", target: "/v2/nowhere", headers: [:], clientAddress: "a"))
    }

    @Test func expiredBodiesAndEmptyBoxesAreDroppedNotJustHidden() async throws {
        let w = try await World.make()
        let rid = ID16.fresh(0x51), route = BridgeRoute(workspaceID: w.ws, requestID: rid)
        #expect(try await w.transport.bridgePost(try w.envelope(rid: rid), route: route, session: w.phoneSession).status == 202)
        let rig = HostRig()
        let resp = try w.sealedResponse(rig: rig, rid: rid, seq: 0, flags: [.last])
        #expect(try await w.transport.bridgePost(resp, route: route, session: w.hostSession).status == 202)
        let n0 = await w.relay.storedBodyCount(), m0 = await w.relay.mailboxCount()
        #expect(n0 == 2 && m0 == 1)
        // Just inside the lifetime: still retained.
        w.clock.advance(milliseconds: 59_999)
        try await ping(w)
        #expect(await w.relay.storedBodyCount() == 2)
        // At the lifetime: the next request of any kind prunes them, and the box with them.
        w.clock.advance(milliseconds: 1)
        try await ping(w)
        let bodies = await w.relay.storedBodyCount(), boxes = await w.relay.mailboxCount()
        #expect(bodies == 0 && boxes == 0)
    }

    @Test func aBoxIdleSinceItsLastBodyExpiredIsPrunedWhileANewerOneStays() async throws {
        let w = try await World.make()
        let a = ID16.fresh(0x52), b = ID16.fresh(0x53)
        _ = try await w.transport.bridgePost(try w.envelope(rid: a), route: BridgeRoute(workspaceID: w.ws, requestID: a), session: w.phoneSession)
        w.clock.advance(milliseconds: 40_000)
        _ = try await w.transport.bridgePost(try w.envelope(rid: b, seq: 2), route: BridgeRoute(workspaceID: w.ws, requestID: b), session: w.phoneSession)
        w.clock.advance(milliseconds: 20_000)             // a is 60 s old, b is 20 s old
        try await ping(w)
        let bodies = await w.relay.storedBodyCount(), boxes = await w.relay.mailboxCount()
        #expect(bodies == 1 && boxes == 1)
    }

    @Test func idlePollsDoNotKeepABoxAlive() async throws {
        let w = try await World.make()
        let rid = ID16.fresh(0x54), route = BridgeRoute(workspaceID: w.ws, requestID: rid)
        _ = try await w.transport.bridgePost(try w.envelope(rid: rid), route: route, session: w.phoneSession)
        for _ in 0..<5 { w.clock.advance(milliseconds: 12_000); _ = try await w.transport.bridgePoll(route: route, after: nil, session: w.phoneSession) }
        // 60 s since receipt: polling never refreshed it.
        let bodies = await w.relay.storedBodyCount(), boxes = await w.relay.mailboxCount()
        #expect(bodies == 0 && boxes == 0)
    }

    @Test func rateWindowsSessionsAndChallengesAreBoundedToo() async throws {
        let w = try await World.make()
        // Pairing posts from many addresses: one window each, gone a minute later.
        for i in 0..<20 {
            let rid = ID16.fresh(UInt8(60 + i)), offer = ID16.fresh(0x70)
            let env = try w.envelope(rid: rid, epoch: 0, stream: offer)
            _ = try await w.relay.send(WireRequest(method: "POST", target: "/v2/workspaces/\(w.ws.hex)/pair/\(offer.hex)/\(rid.hex)",
                                                   headers: [:], body: env, clientAddress: "203.0.113.\(i)"))
        }
        #expect(await w.relay.rateWindowCount() >= 20)
        w.clock.advance(milliseconds: 60_001)
        try await ping(w)
        #expect(await w.relay.rateWindowCount() == 0)
        // Sessions older than 15 minutes are gone from storage, not merely refused.
        #expect(await w.relay.sessionCount() == 2)
        w.clock.advance(milliseconds: 15 * 60_000)
        try await ping(w)
        #expect(await w.relay.sessionCount() == 0)
        // Unanswered challenges: kept briefly (a late login still gets `expired`), then dropped.
        for _ in 0..<10 { _ = try await w.transport.challenge() }
        #expect(await w.relay.challengeCount() == 10)
        w.clock.advance(milliseconds: 60_000 + 5 * 60_000)
        try await ping(w)
        #expect(await w.relay.challengeCount() == 0)
    }
}

@Suite struct EnvelopeLimitTests {
    /// Payload bytes that make a whole envelope exactly `total` bytes.
    func payload(_ w: World, total: Int) throws -> Int { total - (try w.envelope(rid: ID16.fresh(1), payload: 0).count) }

    @Test func aRequestOfExactlyMaxRequestIsQueuedAndOneByteMoreIsRefused() async throws {
        let w = try await World.make()
        let n = try payload(w, total: Bridge.maxRequest)
        let ridA = ID16.fresh(0x81), ridB = ID16.fresh(0x82)
        let exact = try w.envelope(rid: ridA, payload: n)
        #expect(exact.count == Bridge.maxRequest)
        #expect(try await w.transport.bridgePost(exact, route: BridgeRoute(workspaceID: w.ws, requestID: ridA), session: w.phoneSession).status == 202)
        let over = try w.envelope(rid: ridB, payload: n + 1)
        #expect(over.count == Bridge.maxRequest + 1)
        let r = try await w.transport.bridgePost(over, route: BridgeRoute(workspaceID: w.ws, requestID: ridB), session: w.phoneSession)
        #expect(r.status == 400 && errorCode(r) == "too_large")          // bounded ORB2 posts: 400 too_large (section 19.6)
        // The host sees exactly the one request, byte for byte.
        let pending = try await w.relay.pendingRequests(workspace: w.ws, token: w.hostSession.token)
        #expect(pending.count == 1 && pending[0].envelope == exact)
    }

    @Test func aResponseChunkOfExactlyMaxChunkPassesTheRelayAndTheDevicesCheckAndOneByteMoreFailsBoth() async throws {
        let w = try await World.make()
        let rig = HostRig()
        let rid = ID16.fresh(0x83), route = BridgeRoute(workspaceID: w.ws, requestID: rid)
        #expect(try await w.postRequest(rid: rid).status == 202)
        let base = try w.sealedResponse(rig: rig, rid: rid, seq: 0, flags: [.last], dataBytes: 0).count
        let exact = try w.sealedResponse(rig: rig, rid: rid, seq: 0, flags: [.last], dataBytes: Bridge.maxChunk - base)
        #expect(exact.count == Bridge.maxChunk)
        #expect(try await w.transport.bridgePost(exact, route: route, session: w.hostSession).status == 202)
        // Through the relay and back: the device's section 8.8 check accepts the chunk it polled.
        let polled = try chunkList(try await w.transport.bridgePoll(route: route, after: nil, session: w.phoneSession))
        #expect(polled.count == 1 && polled[0].envelope == exact)
        guard case .accept = w.check(polled[0].envelope, rig: rig, rid: rid, index: 0, last: true) else { Issue.record("exact-limit chunk must verify"); return }
        // One byte more: the relay refuses it, and the device's check would drop it for size.
        let ridB = ID16.fresh(0x84)
        let over = try w.sealedResponse(rig: rig, rid: ridB, seq: 0, flags: [.last], dataBytes: Bridge.maxChunk - base + 1)
        #expect(over.count == Bridge.maxChunk + 1)
        let r = try await w.transport.bridgePost(over, route: BridgeRoute(workspaceID: w.ws, requestID: ridB), session: w.hostSession)
        #expect(r.status == 400 && errorCode(r) == "too_large")          // bounded ORB2 posts: 400 too_large (section 19.6)
        #expect(w.check(over, rig: rig, rid: ridB, index: 0, last: true) == .drop(.size))
        let ridC = ID16.fresh(0x85)
        #expect(try chunkList(try await w.transport.bridgePoll(route: BridgeRoute(workspaceID: w.ws, requestID: ridC), after: nil, session: w.phoneSession)).isEmpty)
    }
}
