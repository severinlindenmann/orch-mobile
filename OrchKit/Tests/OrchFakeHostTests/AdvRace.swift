import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
@testable import OrchProtocol

/// The security review's interleavings, with the fixed behaviour asserted. Every one drives a fault delay (an `await` inside the
/// relay) and changes authoritative state while the request is suspended; the clock is injected, so the order is exact.
@Suite struct AdvRace {
    /// Bounded: a regression that stops requests reaching their delay fails the test instead of hanging CI.
    private func waitForSleepers(_ w: World, _ n: Int) async -> Bool {
        for _ in 0..<200_000 where w.clock.sleeperCount < n { await Task.yield() }
        if w.clock.sleeperCount >= n { return true }
        Issue.record("expected \(n) sleepers, saw \(w.clock.sleeperCount)")
        return false
    }

    @Test func aDeviceRemovedDuringADelayedPostIsRefusedAndNothingIsQueued() async throws {
        let faults = ScriptedFaults().enqueue(.delay(.seconds(5)), at: .beforeQueue, routePrefix: "POST bridge")
        let w = try await World.make(faults: faults)
        let rid = ID16.fresh(9)
        let env = try w.envelope(rid: rid)
        let (t, s) = (w.transport, w.phoneSession)
        let post = Task { try await t.bridgePost(env, route: BridgeRoute(workspaceID: w.ws, requestID: rid), session: s) }
        guard await waitForSleepers(w, 1) else { post.cancel(); return }
        // While the phone's request is suspended inside the actor, the host removes the phone (epoch 2, primary only).
        try await w.relay.putGrant(try await w.host.grant(for: w.primary.deviceKeys, epoch: 2), token: w.hostSession.token)
        try await w.relay.publishMemberList(try await w.host.memberList([(w.primaryID, World.all)], epoch: 2, listSeq: 2), token: w.hostSession.token)
        w.clock.advance(by: .seconds(5))
        let r = try await post.value
        #expect(r.status == 403 && errorCode(r) == "not_eligible")
        let boxes = await w.relay.liveMailboxCount(workspace: w.ws, device: w.phoneID), stored = await w.relay.storedBodyCount()
        #expect(boxes == 0 && stored == 0)
        #expect(try await w.relay.pendingRequests(workspace: w.ws, token: w.hostSession.token).isEmpty)
    }

    @Test func aDeviceRevokedDuringADelayedPostQueuesNothing() async throws {
        let faults = ScriptedFaults().enqueue(.delay(.seconds(5)), at: .beforeQueue, routePrefix: "POST bridge")
        let w = try await World.make(faults: faults)
        let rid = ID16.fresh(10)
        let env = try w.envelope(rid: rid)
        let (t, s) = (w.transport, w.phoneSession)
        let post = Task { try await t.bridgePost(env, route: BridgeRoute(workspaceID: w.ws, requestID: rid), session: s) }
        guard await waitForSleepers(w, 1) else { post.cancel(); return }
        try await w.relay.publishRevocation(try await w.primary.revoke(device: w.phoneID))
        w.clock.advance(by: .seconds(5))
        let r = try await post.value
        #expect(r.status == 401 || r.status == 403)                      // the session died with the revocation; either way not queued
        #expect(r.status != 202)
        let stored = await w.relay.storedBodyCount()
        #expect(stored == 0)
    }

    @Test func concurrentDelayedPostsRespectTheQuota() async throws {
        var lim = RelayLimits(); lim.maxLiveMailboxesPerDevice = 1
        let faults = ScriptedFaults().enqueue(.delay(.seconds(1)), at: .beforeQueue, routePrefix: "POST bridge", times: 5)
        let w = try await World.make(faults: faults, limits: lim)
        var tasks: [Task<WireReply, Error>] = []
        let (t, s) = (w.transport, w.phoneSession)
        for i in 0..<5 {
            let rid = ID16.fresh(UInt8(20 + i)); let e = try w.envelope(rid: rid)
            let ws = w.ws
            tasks.append(Task { try await t.bridgePost(e, route: BridgeRoute(workspaceID: ws, requestID: rid), session: s) })
        }
        guard await waitForSleepers(w, 5) else { tasks.forEach { $0.cancel() }; return }
        w.clock.advance(by: .seconds(1))
        var statuses: [Int] = []; for task in tasks { statuses.append(try await task.value.status) }
        #expect(statuses.filter { $0 == 202 }.count == 1 && statuses.filter { $0 == 429 }.count == 4)
        let boxes = await w.relay.liveMailboxCount(workspace: w.ws, device: w.phoneID), stored = await w.relay.storedBodyCount()
        #expect(boxes == 1 && stored == 1)
    }

    @Test func concurrentDelayedPairingPostsRespectTheRateBudget() async throws {
        var lim = RelayLimits(); lim.pairPostsPerMinutePerWorkspace = 2
        let faults = ScriptedFaults().enqueue(.delay(.seconds(1)), at: .beforeQueue, routePrefix: "POST pair", times: 4)
        let w = try await World.make(faults: faults, limits: lim)
        let offer = ID16.fresh(0x77)
        var tasks: [Task<WireReply, Error>] = []
        let relay = w.relay
        for i in 0..<4 {
            let rid = ID16.fresh(UInt8(40 + i))
            let env = try w.envelope(rid: rid, seq: 1, epoch: 0, stream: offer)
            let target = "/mobile/host-api/0/workspaces/\(w.ws.hex)/pair/\(offer.hex)/\(rid.hex)"
            tasks.append(Task { try await relay.send(WireRequest(method: "POST", target: target, headers: ["Orch-Host-API": "0"], body: env, clientAddress: "198.51.100.7")) })
        }
        guard await waitForSleepers(w, 4) else { tasks.forEach { $0.cancel() }; return }
        w.clock.advance(by: .seconds(1))
        var statuses: [Int] = []; for task in tasks { statuses.append(try await task.value.status) }
        #expect(statuses.filter { $0 == 202 }.count == 2 && statuses.filter { $0 == 429 }.count == 2)
    }

    @Test func aDelayedHostResponseCannotRepopulateARevokedDevicesMailbox() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let rid = ID16.fresh(0x34)
        let rig = HostRig()
        let resp = try w.sealedResponse(rig: rig, rid: rid, seq: 0, flags: [.last])
        faults.enqueue(.delay(.seconds(3)), at: .beforeQueue, routePrefix: "POST bridge")
        let (t, s, ws) = (w.transport, w.hostSession, w.ws)
        let post = Task { try await t.bridgePost(resp, route: BridgeRoute(workspaceID: ws, requestID: rid), session: s) }
        guard await waitForSleepers(w, 1) else { post.cancel(); return }
        // The phone is revoked while the host's response is in flight (the revoked device is still in the last list).
        try await w.relay.publishRevocation(try await w.primary.revoke(device: w.phoneID))
        w.clock.advance(by: .seconds(3))
        let r = try await post.value
        #expect(r.status == 403 && errorCode(r) == "revoked")
        let stored = await w.relay.storedBodyCount(), boxes = await w.relay.mailboxCount()
        #expect(stored == 0 && boxes == 0)
    }

    @Test func aResetDuringADelayedPostStoresNothingAndTheCallerSeesAStaleGeneration() async throws {
        let faults = ScriptedFaults().enqueue(.delay(.seconds(5)), at: .beforeQueue, routePrefix: "POST bridge")
        let w = try await World.make(faults: faults)
        let rid = ID16.fresh(0x33)
        let env = try w.envelope(rid: rid)
        let (t, s, ws) = (w.transport, w.phoneSession, w.ws)
        let post = Task { try await t.bridgePost(env, route: BridgeRoute(workspaceID: ws, requestID: rid), session: s) }
        guard await waitForSleepers(w, 1) else { post.cancel(); return }
        try await DemoSetup.reset(w.env, custody: w.custody, vaults: [w.vault])
        w.clock.advance(by: .seconds(5))
        await #expect(throws: TransportError.realm(.staleGeneration)) { _ = try await post.value }
        let stored = await w.relay.storedBodyCount(), sessions = await w.relay.sessionCount()
        #expect(stored == 0 && sessions == 0)
    }
}

private func waitForSleepers(_ w: World, _ n: Int) async -> Bool {
    for _ in 0..<200_000 where w.clock.sleeperCount < n { await Task.yield() }
    if w.clock.sleeperCount >= n { return true }
    Issue.record("expected \(n) sleepers, saw \(w.clock.sleeperCount)")
    return false
}

@Suite struct AdvGrant {
    @Test func grantAndCardKeyForAnotherPersonsDeviceAreRefusedAndStorageIsUnchanged() async throws {
        let w = try await World.make()
        let other = DemoSetup.makeAuthority(w.env)
        await w.relay.registerOwner(other.publicKey)
        try await w.relay.publishCertificate(try await other.certifyOwnDevice())
        let grantsBefore = await w.relay.grantCount(workspace: w.ws), wrapsBefore = await w.relay.cardKeyWrapCount(workspace: w.ws)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .otherPerson))) {
            try await w.relay.putGrant(try await w.host.grant(for: other.deviceKeys, epoch: 1), token: w.hostSession.token)
        }
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .otherPerson))) {
            try await w.relay.putCardKeyWrap(device: other.deviceID, cardSeq: 1, sealed: try await w.host.cardKeyWrap(for: other.deviceKeys), token: w.hostSession.token)
        }
        #expect(await w.relay.grantCount(workspace: w.ws) == grantsBefore)
        #expect(await w.relay.cardKeyWrapCount(workspace: w.ws) == wrapsBefore)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: other.deviceID, epoch: 1) == false)
    }

    @Test func aCertificateThatExpiredBetweenPublicationAndUploadGetsNothing() async throws {
        let w = try await World.make()
        let keys = DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey)
        try await w.relay.publishCertificate(try await w.primary.certify(keys, label: "Short", scopesMax: ["look"], lifetimeMs: 10_000))
        let grant = try await w.host.grant(for: keys, epoch: 1), wrap = try await w.host.cardKeyWrap(for: keys)
        // Within its life: accepted.
        w.clock.advance(milliseconds: 9_999)
        try await w.relay.putGrant(grant, token: w.hostSession.token)
        try await w.relay.putCardKeyWrap(device: keys.deviceID, cardSeq: 1, sealed: wrap, token: w.hostSession.token)
        // A second device, uploaded to after expiry: refused, nothing stored.
        let late = DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey)
        try await w.relay.publishCertificate(try await w.primary.certify(late, label: "Late", scopesMax: ["look"], lifetimeMs: 10_000))
        let lateGrant = try await w.host.grant(for: late, epoch: 1), lateWrap = try await w.host.cardKeyWrap(for: late)
        w.clock.advance(milliseconds: 10_000)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 400, code: .certExpired))) { try await w.relay.putGrant(lateGrant, token: w.hostSession.token) }
        await #expect(throws: ClientError.relay(RelayRefusal(status: 400, code: .certExpired))) {
            try await w.relay.putCardKeyWrap(device: late.deviceID, cardSeq: 1, sealed: lateWrap, token: w.hostSession.token)
        }
        #expect(await w.relay.hasGrant(workspace: w.ws, device: late.deviceID, epoch: 1) == false)
        #expect(await w.relay.hasCardKeyWrap(workspace: w.ws, device: late.deviceID, cardSeq: 1) == false)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: keys.deviceID, epoch: 1))
    }

    @Test func aCertificateThatExpiresDuringADelayedUploadIsRefused() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let keys = DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey)
        try await w.relay.publishCertificate(try await w.primary.certify(keys, label: "Short", scopesMax: ["look"], lifetimeMs: 10_000))
        let grant = try await w.host.grant(for: keys, epoch: 1)
        faults.enqueue(.delay(.seconds(20)), at: .beforeGrantPublication)
        let (relay, token) = (w.relay, w.hostSession.token)
        let upload = Task { try await relay.putGrant(grant, token: token) }
        guard await waitForSleepers(w, 1) else { upload.cancel(); return }
        w.clock.advance(by: .seconds(20))
        await #expect(throws: ClientError.relay(RelayRefusal(status: 400, code: .certExpired))) { try await upload.value }
        #expect(await w.relay.hasGrant(workspace: w.ws, device: keys.deviceID, epoch: 1) == false)
    }

    @Test func aDeviceRevokedDuringADelayedUploadGetsNoGrant() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let keys = DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey)
        try await w.relay.publishCertificate(try await w.primary.certify(keys, label: "N", scopesMax: ["look"]))
        let grant = try await w.host.grant(for: keys, epoch: 1)
        faults.enqueue(.delay(.seconds(2)), at: .beforeGrantPublication)
        let (relay, token) = (w.relay, w.hostSession.token)
        let upload = Task { try await relay.putGrant(grant, token: token) }
        guard await waitForSleepers(w, 1) else { upload.cancel(); return }
        try await w.relay.publishRevocation(try await w.primary.revoke(device: keys.deviceID))
        w.clock.advance(by: .seconds(2))
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .revoked))) { try await upload.value }
        #expect(await w.relay.hasGrant(workspace: w.ws, device: keys.deviceID, epoch: 1) == false)
    }
}
