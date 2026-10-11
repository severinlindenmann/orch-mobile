import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchProtocol
@testable import OrchFakeHost

/// Rotation through atomic membership publication (P3-D7, section 19.7): the host persists the key and the exact bytes before the
/// first send, resends only those bytes while the outcome is open, and discards them (and the uncommitted key) only on a refusal.
@Suite struct RotationPublicationTests {
    private func key(_ w: World, _ e: UInt32) async -> Data { await w.host.wkFor(e).withUnsafeBytes { Data($0) } }

    @Test(arguments: [false, true])
    func expiredSessionRecovers(resubmit: Bool) async throws {
        var limits = RelayLimits(); limits.sessionLifetimeMs = 1000
        let w = try await World.make(limits: limits)
        w.clock.advance(milliseconds: 1001)
        let remaining = [(w.phone, ["look", "decide"])]
        await #expect(throws: ClientError.relay(RelayRefusal(status: 401, code: .unauthenticated))) {
            try await w.host.rotate(remaining: remaining, relay: w.relay, session: w.hostSession)
        }
        // 401 says nothing about the body: the same bytes stay pending for the next session.
        let pending = try #require(await w.host.pendingPublicationState())
        #expect(pending.sent && pending.epoch == 2)
        let fresh = try await w.host.openSession(transport: w.transport)
        try await rotationRetry(w) {
            if resubmit { try await w.host.rotate(remaining: remaining, relay: w.relay, session: fresh) }
            else { _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: fresh) }
        }
        #expect(await w.host.rotationRequired == false)
        #expect(await w.host.epoch == 2)
        #expect(await w.host.pendingPublicationState() == nil)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.phoneID, epoch: 2))
    }

    /// The reply is lost after the commit: the retry resends the identical bytes, the relay answers its receipt, and the grant it
    /// stores is the one sealed first (a reseal would be `grant_conflict`).
    @Test func lostReplyResendsTheIdenticalBytes() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "PUT /v2/workspaces/\(w.ws.hex)/membership")
        await #expect(throws: TransportError.disconnected) {
            try await w.host.rotate(remaining: [(w.phone, ["look", "decide"])], relay: w.relay, session: w.hostSession)
        }
        let sent = try #require(await w.host.pendingPublicationState())
        #expect(sent.sent && sent.epoch == 2)
        #expect(await w.relay.memberListEpoch(workspace: w.ws) == 2)       // committed at the relay; the host does not know yet
        #expect(await w.host.epoch == 1)
        #expect(await w.host.rotationRequired)
        let committedKey = await key(w, 2)
        _ = try await rotationRetry(w) { try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }
        #expect(await w.host.epoch == 2)
        #expect(await w.host.rotationRequired == false)
        #expect(await key(w, 2) == committedKey)
        let grants = try await RelayClient(transport: w.transport).grants(workspace: w.ws, epoch: 2, session: w.phoneSession)
        let opened = try WKGrant.open(try #require(grants.first), wsk: w.host.wskPublic, workspace: w.ws, device: w.phoneID, deviceKey: w.env.device.kx)
        #expect(opened.wk.withUnsafeBytes { Data($0) } == committedKey)
    }

    /// Section 19.7: after a lost reply and a `stale_list` (the receipt is gone), the host reads the signed list and, when it is the
    /// one it sent, treats the publication as accepted.
    @Test func lostReplyThenStaleListReconcilesWithTheRelaysList() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "PUT /v2/workspaces/\(w.ws.hex)/membership")
        await #expect(throws: TransportError.disconnected) {
            try await w.host.rotate(remaining: [(w.phone, ["look", "decide"])], relay: w.relay, session: w.hostSession)
        }
        w.clock.advance(milliseconds: 7 * 86_400_000)                     // receipts last seven days, not refreshed
        let fresh = try await w.host.openSession(transport: w.transport)
        _ = try await rotationRetry(w) { try await w.host.pump(relay: w.relay, transport: w.transport, session: fresh) }
        #expect(await w.host.epoch == 2)
        #expect(await w.host.rotationRequired == false)
        #expect(await w.host.pendingPublicationState() == nil)
    }

    /// A newer list the host did not send: acceptance cannot be established, so it is surfaced (once), never assumed; the host then
    /// publishes a fresh sequence and epoch above the relay's list (section 19.7) instead of failing forever.
    @Test func staleListWithAnotherListIsAConflict() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let route = "PUT /v2/workspaces/\(w.ws.hex)/membership"
        faults.enqueue(.drop, at: .beforeMembershipPublication, routePrefix: route)
        await #expect(throws: TransportError.disconnected) {
            try await w.host.rotate(remaining: [(w.phone, ["look", "decide"])], relay: w.relay, session: w.hostSession)
        }
        // Someone holding WSK published list 2 meanwhile.
        try await w.publish(w.baseRoster, epoch: 1, listSeq: 2)
        await #expect(throws: MembershipPublicationError.conflict) {
            try await rotationRetry(w) { try await w.host.rotate(remaining: [(w.phone, ["look", "decide"])], relay: w.relay, session: w.hostSession) }
        }
        #expect(await w.host.pendingPublicationState() == nil)
        #expect(await w.host.rotationRequired)
        #expect(await w.host.epoch == 1)
        try await rotationRetry(w, milliseconds: 200) { _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }
        #expect(await w.host.rotationRequired == false)
        #expect(await w.host.epoch == 2)
        #expect(await w.relay.memberListSeq(workspace: w.ws) == 3)
    }

    /// C4: the host fails after persisting the body but before sending it. Those bytes never left: the slot is dropped, the
    /// key is kept, and the retry publishes the same epoch.
    @Test func crashBeforeSendRetriesTheSameEpochWithTheSameKey() async throws {
        let w = try await World.make()
        let calls = Counter()
        await w.host.setPublishHook { calls.bump(); if calls.value == 1 { throw TestCrash() } }
        await #expect(throws: TestCrash.self) {
            try await w.host.rotate(remaining: [(w.phone, ["look", "decide"])], relay: w.relay, session: w.hostSession)
        }
        #expect(await w.host.pendingPublicationState() == nil)
        #expect(await w.relay.memberListEpoch(workspace: w.ws) == 1)
        let kept = await key(w, 2)
        _ = try await rotationRetry(w) { try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }
        #expect(await w.host.epoch == 2 && calls.value == 2)
        #expect(await key(w, 2) == kept)
        #expect(await w.relay.memberListEpoch(workspace: w.ws) == 2)
    }

    /// C3: a member revoked at the host while the publication that still names it is in flight is not re-added to the local roster
    /// by that commit; the follow-up rotation publishes without it.
    @Test func memberRevokedDuringTheSendIsNotReAdded() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        faults.enqueue(.delay(.seconds(1)), at: .beforeMembershipPublication)
        let seen = RosterBox()
        await w.host.setPublishHook { await seen.record(await w.host.coreState().members[w.primaryID] != nil) }
        let rotation = Task {
            try await w.host.rotate(remaining: [(w.phone, ["look", "decide"]), (w.primary.deviceKeys, World.all)], relay: w.relay, session: w.hostSession)
        }
        while w.clock.sleeperCount == 0 { await Task.yield() }
        await w.host.markRevoked(w.primaryID)
        w.clock.advance(milliseconds: 1000)
        _ = try? await rotation.value
        if await w.host.rotationRequired {
            _ = try await rotationRetry(w) { try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }
        }
        #expect(await seen.values.count == 2)
        #expect(await seen.values.last == false)          // after the first commit the primary was not back in the roster
        #expect(await w.host.epoch == 3)
        #expect(await w.host.coreState().members[w.primaryID] == nil)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.primaryID, epoch: 3) == false)
    }

    /// I3: the relay refused the publication (a member was revoked while it was delayed). Nothing was committed and the relay saw
    /// the sealed grants, so the key is discarded: the retry publishes the same epoch (epochs never skip) under a fresh key.
    @Test func refusedPublicationNeverActivatesItsKey() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        faults.enqueue(.delay(.seconds(1)), at: .beforeMembershipPublication)
        let seen = KeyBox()
        await w.host.setPublishHook { await seen.set(await w.host.wkFor(2).withUnsafeBytes { Data($0) }) }
        let rotation = Task {
            try await w.host.rotate(remaining: [(w.phone, ["look", "decide"]), (w.primary.deviceKeys, World.all)], relay: w.relay, session: w.hostSession)
        }
        while w.clock.sleeperCount == 0 { await Task.yield() }
        try await w.relay.publishRevocation(try await w.primary.revoke(device: w.primaryID))
        w.clock.advance(milliseconds: 1000)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .revoked))) { try await rotation.value }
        #expect(await w.host.pendingPublicationState() == nil)
        #expect(await w.relay.memberListEpoch(workspace: w.ws) == 1)
        await w.host.setPublishHook(nil)
        _ = try await rotationRetry(w) { try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }
        #expect(await w.host.epoch == 2)
        #expect(await w.host.rotationRequired == false)
        let refused = try #require(await seen.value)
        #expect(await key(w, 2) != refused)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.primaryID, epoch: 2) == false)
        let grants = try await RelayClient(transport: w.transport).grants(workspace: w.ws, epoch: 2, session: w.phoneSession)
        let opened = try WKGrant.open(try #require(grants.first), wsk: w.host.wskPublic, workspace: w.ws, device: w.phoneID, deviceKey: w.env.device.kx)
        #expect(opened.wk.withUnsafeBytes { Data($0) } != refused)
    }

    @Test func publicationRetriesBackOff() async throws {
        let w = try await World.make()
        let calls = Counter()
        await w.host.setPublishHook { calls.bump(); throw TestCrash() }
        await #expect(throws: TestCrash.self) {
            try await w.host.rotate(remaining: [(w.phone, ["look"])], relay: w.relay, session: w.hostSession)
        }
        let retry = Task { try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }
        guard await eventually("retry sleeper", { w.clock.sleeperCount == 1 }) else { retry.cancel(); return }
        #expect(calls.value == 1)
        w.clock.advance(milliseconds: 99)
        #expect(calls.value == 1 && w.clock.sleeperCount == 1)
        w.clock.advance(milliseconds: 1)
        _ = try await retry.value
        #expect(calls.value == 2)
    }

    /// There is no rotation-abandon route or label (P3-D7).
    @Test func noRotationAbandonRoute() async throws {
        let w = try await World.make()
        let r = try await w.relay.send(WireRequest(method: "POST", target: "/v2/workspaces/\(w.ws.hex)/rotation-abandon",
                                                   headers: ["authorization": "Bearer \(w.hostSession.token)"],
                                                   body: canonicalJSON(["epoch": 2]), clientAddress: "198.51.100.7"))
        #expect(r.status == 404)
    }
}

private actor KeyBox {
    var value: Data?
    func set(_ d: Data) { if value == nil { value = d } }
}

private actor RosterBox {
    var values: [Bool] = []
    func record(_ v: Bool) { values.append(v) }
}
