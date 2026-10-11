import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchProtocol
@testable import OrchFakeHost

/// Q10 (one WK per epoch, ever) on the host side of membership publication: what a refusal burns and what it does not.
@Suite struct Q10HostTests {
    private func newDevice(_ w: World, certify: Bool = true) async throws -> DemoKeys {
        let keys = DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey)
        if certify { try await w.relay.publishCertificate(try await w.primary.certify(keys, label: "Q10", scopesMax: ["look"])) }
        return keys
    }

    /// `stale_card` says only the wraps were wrong: the same signed list and grants go again with fixed wraps, and nothing is burned.
    @Test func staleCardResendsTheSameListWithoutBurningTheEpoch() async throws {
        let w = try await World.make()
        let keys = try await newDevice(w)
        let ws = w.ws
        await w.relay.seed { r in r.workspaces[ws]!.card!.cardSeq = 2 }          // the relay's card moved on; the host's wraps are seq 1
        let before = await w.host.wkFor(1).withUnsafeBytes { Data($0) }
        try await w.host.publishMembership(roster: w.baseRoster + [(keys, ["look"])], epoch: 1, wraps: [keys], relay: w.relay, session: w.hostSession)
        #expect(await w.relay.memberListSeq(workspace: w.ws) == 2)
        #expect(await w.relay.memberListEpoch(workspace: w.ws) == 1)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: keys.deviceID, epoch: 1))
        #expect(await w.relay.hasCardKeyWrap(workspace: w.ws, device: keys.deviceID, cardSeq: 1) == false)
        #expect(await w.host.epoch == 1)
        #expect(await w.host.relayEpochFloor == 0)
        #expect(await w.host.rotationRequired == false)
        #expect(await w.host.wkFor(1).withUnsafeBytes { Data($0) } == before)
    }

    /// A same-epoch addition refused because the new member is revoked: the relay saw a grant of the CURRENT WK sealed to it, so the
    /// host raises the gate and the next pump rotates (without that device).
    @Test func sameEpochAdditionRefusedAsRevokedForcesARotation() async throws {
        let w = try await World.make()
        let keys = try await newDevice(w)
        try await w.relay.publishRevocation(try await w.primary.revoke(device: keys.deviceID))
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .revoked))) {
            try await w.host.publishMembership(roster: w.baseRoster + [(keys, ["look"])], epoch: 1, wraps: [], relay: w.relay, session: w.hostSession)
        }
        #expect(await w.host.rotationRequired)
        #expect(await w.host.epoch == 1)
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        #expect(await w.host.rotationRequired == false)
        #expect(await w.host.epoch == 2)
        #expect(await w.relay.memberListEpoch(workspace: w.ws) == 2)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: keys.deviceID, epoch: 2) == false)
    }

    /// The same refusal for a member whose certificate is merely missing (`cert_invalid`) forces the rotation too.
    @Test func sameEpochAdditionRefusedAsCertInvalidForcesARotation() async throws {
        let w = try await World.make()
        let ghost = try await newDevice(w, certify: false)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 400, code: .certInvalid))) {
            try await w.host.publishMembership(roster: w.baseRoster + [(ghost, ["look"])], epoch: 1, wraps: [], relay: w.relay, session: w.hostSession)
        }
        #expect(await w.host.rotationRequired)
    }

    /// Liveness regression (formerly a known gap): a hostile relay answers `stale_list` and replays the host's own refused (still
    /// WSK-signed) list. Before Q10 the replay raised the host's floors above the epoch it had just discarded, so every retry chased
    /// the replayed list. Now a refusal burns its epoch and raises the floors itself: the replay is not newer than anything the host
    /// used, the floors stay the host's own, and the next publication commits at floor + 1. The relay never sees two lists at one
    /// epoch with different keys, and the phone follows to the committed epoch.
    @Test func hostileReplayOfTheRefusedListDoesNotRunTheFloorAway() async throws {
        let w = try await World.make()
        let ghost = try await newDevice(w, certify: false)
        let refusedRoster = w.baseRoster + [(ghost, ["look"])]
        await #expect(throws: ClientError.relay(RelayRefusal(status: 400, code: .certInvalid))) {
            try await w.host.publishMembership(roster: refusedRoster, epoch: 2, wraps: [], relay: w.relay, session: w.hostSession)
        }
        #expect(await w.host.relayEpochFloor == 2)
        #expect(await w.host.listSeq == 2)
        #expect(await w.host.epoch == 1)
        let burned = await w.host.wkFor(2).withUnsafeBytes { Data($0) }
        // The hostile relay now claims list_seq 3 and serves the host's refused epoch-2 list.
        let replay = try await w.host.memberList(refusedRoster.map { ($0.0.deviceID, $0.1) }, epoch: 2, listSeq: 2)
        let ws = w.ws
        await w.relay.seed { r in r.workspaces[ws]!.listJSON = replay; r.workspaces[ws]!.listSeq = 3 }
        await #expect(throws: MembershipPublicationError.conflict) {
            try await w.host.rotate(remaining: w.baseRoster, relay: w.relay, session: w.hostSession)
        }
        // only the host's own publications set its floors: epoch 3 (the one just refused as stale) and list_seq 3
        #expect(await w.host.relayEpochFloor == 3)
        #expect(await w.host.listSeq == 3)
        _ = try await rotationRetry(w) { try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }
        #expect(await w.host.rotationRequired == false)
        #expect(await w.host.epoch == 4)
        #expect(await w.relay.memberListEpoch(workspace: w.ws) == 4)
        #expect(await w.host.wkFor(2).withUnsafeBytes { Data($0) } == burned)          // never resealed
        let phone = try await w.makePhone()
        #expect(try await phone.session.currentEpoch() == 4)
    }

    /// A same-epoch addition refused for ANY reason (here `scope_exceeded`) carried a grant of the current WK to a device that is not a
    /// committed member: the gate goes up and the next pump rotates.
    @Test func anyRefusedSameEpochAdditionForcesARotation() async throws {
        let w = try await World.make()
        let keys = try await newDevice(w)                                   // certified for ["look"] only
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .scopeExceeded))) {
            try await w.host.publishMembership(roster: w.baseRoster + [(keys, ["look", "decide"])], epoch: 1, wraps: [], relay: w.relay, session: w.hostSession)
        }
        #expect(await w.host.rotationRequired)
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        #expect(await w.host.epoch == 2)
        #expect(await w.relay.memberListEpoch(workspace: w.ws) == 2)
    }

    /// A deterministic refusal must not burn epochs forever: after `maxConsecutiveBurns` refused publications the host raises its
    /// publication alarm and stops sending (no request reaches the relay any more).
    @Test func consecutiveBurnsStopAtTheAlarm() async throws {
        let w = try await World.make()
        let keys = try await newDevice(w)
        // a rotation whose roster asks more than the certificate allows: refused (scope_exceeded) on every attempt
        await #expect(throws: (any Error).self) {
            try await w.host.rotate(remaining: [(keys, ["look", "decide"])], relay: w.relay, session: w.hostSession)
        }
        for _ in 0..<(FakeHost.maxConsecutiveBurns + 3) {
            _ = try await rotationRetry(w, milliseconds: 1_600) { try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }
        }
        #expect(await w.host.publicationAlarm == .burnLimit)
        #expect(await w.host.relayEpochFloor == UInt32(FakeHost.maxConsecutiveBurns) + 1)
        #expect(await w.relay.memberListEpoch(workspace: w.ws) == 1)
        let sent = await w.relay.requestsReceived
        _ = try await rotationRetry(w, milliseconds: 1_600) { try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }
        #expect(await w.relay.requestsReceived - sent <= 1)                 // at most the host's own inbox read; no publication
    }

    /// orch-29 host liveness: the next rotation goes to `min(EHW + 1, committed + 2^16)`; when the clamp stops it, the host raises the
    /// alarm, keeps the gate up and sends nothing (no publication, nothing burned).
    @Test func anEpochGapOfTwoToTheSixteenAlarmsInsteadOfBurning() async throws {
        let w = try await World.make()
        await w.host.setRelayEpochFloorForTests(1 + MemberList.maxEpochStep)
        let sent = await w.relay.requestsReceived
        await #expect(throws: MembershipPublicationError.alarm) {
            try await w.host.rotate(remaining: w.baseRoster, relay: w.relay, session: w.hostSession)
        }
        #expect(await w.host.relayEpochFloor == 1 + MemberList.maxEpochStep)   // nothing was sealed or burned
        #expect(await w.host.publicationAlarm == .epochGap)
        #expect(await w.host.rotationRequired)                                   // the gate stays up
        #expect(await w.relay.requestsReceived == sent)
        // the largest step the clamp allows still publishes
        let w2 = try await World.make()
        await w2.host.setRelayEpochFloorForTests(MemberList.maxEpochStep)
        try await w2.host.rotate(remaining: w2.baseRoster, relay: w2.relay, session: w2.hostSession)
        #expect(await w2.host.epoch == 1 + MemberList.maxEpochStep)
    }

    /// Security regression (#48 delta): a relay answers `bad_epoch` to a rotation whose roster still names device Y, so it saw Y's
    /// grant of that epoch's WK. Y is then removed. The retry must not reuse that epoch or key: it goes to a new epoch under a new
    /// WK, so Y's key cannot open anything sealed after its removal.
    @Test func aBadEpochRefusalBurnsTheEpochSoARemovedDeviceCannotReadTheRetry() async throws {
        let w = try await World.make()
        let y = try await newDevice(w)
        try await w.host.publishMembership(roster: w.baseRoster + [(y, ["look"])], epoch: 1, wraps: [], relay: w.relay, session: w.hostSession)
        // the hostile relay claims a higher epoch for one attempt, so it answers bad_epoch after seeing the body (and Y's grant)
        let ws = w.ws
        await w.relay.seed { r in r.workspaces[ws]!.epoch = 5 }
        await #expect(throws: ClientError.relay(RelayRefusal(status: 409, code: .badEpoch))) {
            try await w.host.rotate(remaining: w.baseRoster + [(y, ["look"])], relay: w.relay, session: w.hostSession)
        }
        let seenByY = await w.host.wkFor(2).withUnsafeBytes { Data($0) }       // sealed to Y in the refused body
        await w.relay.seed { r in r.workspaces[ws]!.epoch = 1 }
        #expect(await w.host.relayEpochFloor == 2)
        // Y leaves; the retry publishes without it
        _ = try await rotationRetry(w) { try await w.host.rotate(remaining: w.baseRoster, relay: w.relay, session: w.hostSession) }
        #expect(await w.host.epoch == 3)
        #expect(await w.relay.memberListEpoch(workspace: w.ws) == 3)
        #expect(await w.host.wkFor(3).withUnsafeBytes { Data($0) } != seenByY)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: y.deviceID, epoch: 3) == false)
    }
}

extension FakeHost {
    func setRelayEpochFloorForTests(_ e: UInt32) { relayEpochFloor = e }
}
