import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchFakeHost
import OrchProtocol
@testable import OrchClient
@testable import OrchFakeHost
@testable import OrchProtocol

/// PR4: the primary's PK-signed `cert_rejection` over the relay's D(p) routes, relayed by the host, verified by the phone before it
/// shows "denied"; and the queue's canonical-object idempotency as the primary's client sees it.
@Suite struct PrimaryRejectionTests {
    /// Host approved, the primary's challenge is on the phone.
    static func toComparingPrimary() async throws -> PairHarness {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        try await h.hostApproves()
        _ = try await h.drive(until: isComparingPrimary)
        return h
    }

    @Test func aVerifiedPrimaryRejectionEndsAsDenied() async throws {
        let h = try await Self.toComparingPrimary()
        let p = try #require(await h.primary.openPrompts().first)
        try await h.primary.reject(request: p.requestID, relay: h.relay)
        #expect(await h.relay.certRequestState(p.requestID) == "rejected")
        #expect(try await h.drive(until: { $0.isTerminal }) == .denied)
        #expect(await h.host.pairingState(of: h.phoneID) == "rejected")
        #expect(await h.nothingFor(h.phoneID))
    }

    @Test func aRejectionNotSignedByThePinnedPKIsNeverBelieved() async throws {
        // a compromised host claims "the primary said no" with a rejection signed by a key of its own, once under the real pk_pub
        // (signature fails) and once with its own pk_pub (pin fails): the phone drops the answer and keeps waiting, then expires
        for ownPK in [false, true] {
            let h = try await Self.toComparingPrimary()
            let rid = try #require(await h.host.pairingRequestID(of: h.phoneID))
            let attacker = SoftwareSigner()
            let person = ownPK ? Identifiers.personID(attacker.publicKey) : h.primary.personID
            let forged = try CertRejection.sign(requestID: rid, workspace: h.host.workspace, person: person, primary: attacker)
            await h.host.forceRelayedRejection(device: h.phoneID, rejection: forged.json)
            let s = try await h.drive(steps: 30, until: { $0.isTerminal })
            #expect(!s.isTerminal, "ownPK \(ownPK): \(s)")
            #expect(try await h.drive(steps: 1200, until: { $0.isTerminal }) == .expired(.certification), "ownPK \(ownPK)")
        }
    }

    @Test func aRejectionOfAnotherWorkspaceIsDropped() async throws {
        let h = try await Self.toComparingPrimary()
        let rid = try #require(await h.host.pairingRequestID(of: h.phoneID))
        let other = try CertRejection.sign(requestID: rid, workspace: .random(), person: h.primary.personID, primary: h.primary.pkSigner)
        await h.host.forceRelayedRejection(device: h.phoneID, rejection: other.json)
        #expect(!(try await h.drive(steps: 30, until: { $0.isTerminal })).isTerminal)
    }

    @Test func aGenuineRejectionOfAnotherRequestRaisesTheAlarm() async throws {
        // PK-signed, this workspace, but not the request whose challenge the phone showed: a replayed old rejection
        let h = try await Self.toComparingPrimary()
        let stale = try CertRejection.sign(requestID: .random(), workspace: h.host.workspace, person: h.primary.personID, primary: h.primary.pkSigner)
        await h.host.forceRelayedRejection(device: h.phoneID, rejection: stale.json)
        let s = try await h.drive(until: { $0.isTerminal })
        guard case .alarm(let a) = s else { Issue.record("\(s)"); return }
        #expect(a.kind == .pinSubstitution)
    }

    @Test func theHostsOwnRejectionStaysARejection() async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        try await h.hostApproves()
        _ = try await h.drive(until: isComparingPrimary)
        try await h.host.rejectPairing(device: h.phoneID)
        #expect(try await h.drive(until: { $0.isTerminal }) == .rejected)
    }

    @Test func challengeAndRejectionResubmissionsAreIdempotent() async throws {
        let h = try await Self.toComparingPrimary()
        let p = try #require(await h.primary.openPrompts().first)
        let (client, session) = try await h.primary.primarySession(relay: h.relay)
        let stored = try #require(await h.relay.certRecord(p.requestID)?.challenge)
        // the same challenge again, and the same object re-signed: 200 (a resend after a lost reply is success)
        try await client.submitCertChallenge(stored, requestID: p.requestID, session: session)
        let o = try #require(stored.object?["o"]?.object)
        let resigned = try CertChallenge.sign(o, primary: h.primary.pkSigner).json
        #expect(resigned != stored)
        try await client.submitCertChallenge(resigned, requestID: p.requestID, session: session)
        // another challenge for the same request: 409 replayed
        var other = o; other["primary_nonce"] = .string(B64U.encode(Data(repeating: 9, count: 32)))
        await #expect(throws: ClientError.relay(RelayRefusal(status: 409, code: .replayed))) {
            try await client.submitCertChallenge(try CertChallenge.sign(other, primary: h.primary.pkSigner).json, requestID: p.requestID, session: session)
        }
        // a challenge the host signed (not PK): 401 bad_signature
        await #expect(throws: ClientError.relay(RelayRefusal(status: 401, code: .badSignature))) {
            try await client.submitCertChallenge(try CertChallenge.sign(other, primary: SoftwareSigner()).json, requestID: p.requestID, session: session)
        }
        // the rejection, then its re-signed twin (lost reply), both 200; the state does not move again
        let rej = try CertRejection.sign(requestID: p.requestID, workspace: h.host.workspace, person: h.primary.personID, primary: h.primary.pkSigner)
        try await client.submitCertRejection(rej.json, requestID: p.requestID, session: session)
        let again = try CertRejection.sign(requestID: p.requestID, workspace: h.host.workspace, person: h.primary.personID, primary: h.primary.pkSigner)
        try await client.submitCertRejection(again.json, requestID: p.requestID, session: session)
        #expect(await h.relay.certRecord(p.requestID)?.rejection == rej.json)
        #expect(await h.relay.certRequestState(p.requestID) == "rejected")
        // no rejection without the primary's device session
        let hostSession = try await h.host.openSession(transport: h.env.transport)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .notEligible))) {
            try await client.submitCertRejection(rej.json, requestID: p.requestID, session: hostSession)
        }
    }

    @Test func accountsComeFromInvitesAndRetriesAreIdempotent() async throws {
        let h = try await PairHarness.make(.firstTime)
        let pk = SoftwareSigner()
        let id = try h.config.context.deviceIdentity(custody: h.config.custody, createIfMissing: true)
        let keys = DemoKeys(id.publicKeys)
        let cert = try SignedObject.sign([
            "v": 2, "suite": 2, "kind": "device_cert", "device_id": .string(keys.deviceID.hex), "person_id": .string(Identifiers.personID(pk.publicKey).hex),
            "dk_sig_pub": .string(B64U.encode(keys.sig.x963)), "dk_kx_pub": .string(B64U.encode(keys.kx.x963)),
            "label_sealed": .string(B64U.encode(Data(repeating: 1, count: 40))), "created_ms": .int(h.clock.nowMs), "expires_ms": .null,
            "scopes_max": ["look"]], kind: .deviceCert, signer: pk).json
        let client = RelayClient(transport: h.env.transport)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .notEligible))) {
            _ = try await client.createAccount(invite: "FAKE-none", pkPub: pk.publicKey, deviceCert: cert, identity: id)
        }
        await h.relay.createInvite("FAKE-invite")
        let person = try await client.createAccount(invite: "FAKE-invite", pkPub: pk.publicKey, deviceCert: cert, identity: id)
        #expect(person == Identifiers.personID(pk.publicKey))
        #expect(await h.relay.accountKey(person) == pk.publicKey)
        // the invite is used up: a new request (fresh challenge) for the same person is refused
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .notEligible))) {
            _ = try await client.createAccount(invite: "FAKE-invite", pkPub: pk.publicKey, deviceCert: cert, identity: id)
        }
    }
}

/// Forwards everything to the in-process transport except `logout`, which never answers (a hostile or stalled relay), and can make
/// `grants` fail as a transport loss so a join keeps its session and retries.
final class HangingLogoutTransport: RelayTransport, @unchecked Sendable {
    let inner: any RelayTransport
    private let lock = NSLock()
    private var failGrants = false, logouts = 0
    var logoutsStarted: Int { lock.withLock { logouts } }
    func setFailGrants(_ v: Bool) { lock.withLock { failGrants = v } }
    init(_ inner: any RelayTransport) { self.inner = inner }
    var context: RealmContext { inner.context }
    func logout(session: RelaySession) async throws -> WireReply {
        lock.withLock { logouts += 1 }
        try await Task.sleep(for: .seconds(3600))          // real time: nothing on a lifecycle path may wait for this
        return try await inner.logout(session: session)
    }
    func challenge() async throws -> WireReply { try await inner.challenge() }
    func login(_ body: Data) async throws -> WireReply { try await inner.login(body) }
    func pairingPost(_ envelope: Data, route: PairRoute) async throws -> WireReply { try await inner.pairingPost(envelope, route: route) }
    func pairingPoll(route: PairRoute, after: UInt64?) async throws -> WireReply { try await inner.pairingPoll(route: route, after: after) }
    func bridgePost(_ envelope: Data, route: BridgeRoute, session: RelaySession) async throws -> WireReply { try await inner.bridgePost(envelope, route: route, session: session) }
    func bridgePoll(route: BridgeRoute, after: UInt64?, session: RelaySession) async throws -> WireReply { try await inner.bridgePoll(route: route, after: after, session: session) }
    func grants(workspaceID: ID16, epoch: UInt32?, session: RelaySession) async throws -> WireReply {
        if lock.withLock({ failGrants }) { throw TransportError.disconnected }
        return try await inner.grants(workspaceID: workspaceID, epoch: epoch, session: session)
    }
    func memberList(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try await inner.memberList(workspaceID: workspaceID, session: session) }
    func card(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try await inner.card(workspaceID: workspaceID, session: session) }
    func cardKey(workspaceID: ID16, cardSequence: UInt32, session: RelaySession) async throws -> WireReply {
        try await inner.cardKey(workspaceID: workspaceID, cardSequence: cardSequence, session: session)
    }
    func registerPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await inner.registerPush(body, session: session) }
    func unregisterPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await inner.unregisterPush(body, session: session) }
    func revocation(deviceID: ID16) async throws -> WireReply { try await inner.revocation(deviceID: deviceID) }
    func dropPut(objectID: ID16, ifMatch: UInt32, body: Data, session: RelaySession) async throws -> WireReply {
        try await inner.dropPut(objectID: objectID, ifMatch: ifMatch, body: body, session: session)
    }
    func dropList(_ query: Data, session: RelaySession) async throws -> WireReply { try await inner.dropList(query, session: session) }
    func dropGet(objectID: ID16, version: UInt32, part: DropPart, session: RelaySession) async throws -> WireReply {
        try await inner.dropGet(objectID: objectID, version: version, part: part, session: session)
    }
}

/// The join session's logout is fire-and-forget: ready and cancel complete while a logout hangs (security review of PR2, low).
@Suite(.timeLimit(.minutes(1))) struct JoinSessionLogoutTests {
    static func run(_ h: PairHarness, _ c: PairingCoordinator, steps: Int = 200, until: @Sendable (PairingState) -> Bool) async throws -> PairingState {
        for _ in 0..<steps {
            let s = await c.state
            if until(s) { return s }
            try await h.rig.pump(); await c.poll(); h.clock.advance(milliseconds: 1000)
        }
        return await c.state
    }

    static func joining(failGrants: Bool) async throws -> (PairHarness, PairingCoordinator, HangingLogoutTransport) {
        let h = try await PairHarness.make(.existingCert)
        let t = HangingLogoutTransport(h.env.transport)
        t.setFailGrants(failGrants)
        var cfg = h.config; cfg.transport = t
        let c = PairingCoordinator(cfg)
        try await h.rig.enrollExistingCertificate(into: cfg)
        _ = await c.start(link: try h.link(try await h.rig.newOffer()))
        _ = try await run(h, c, until: isComparingHost)
        try await h.host.approvePairing(device: h.phoneID, confirmedComparison: true, relay: h.relay, transport: h.env.transport)
        return (h, c, t)
    }

    @Test func readyDoesNotWaitForTheLogout() async throws {
        let (h, c, t) = try await Self.joining(failGrants: false)
        let s = try await Self.run(h, c, until: { $0.isTerminal })
        guard case .ready = s else { Issue.record("\(s)"); return }
        #expect(t.logoutsStarted <= 1)
        await c.logoutTask?.cancel()
    }

    @Test func cancelDoesNotWaitForTheLogout() async throws {
        let (h, c, t) = try await Self.joining(failGrants: true)
        let s = try await Self.run(h, c, steps: 30, until: { $0 == .joining })
        #expect(s == .joining, "\(s)")
        _ = try await Self.run(h, c, steps: 3, until: { _ in false })     // the join logs in, then its grants fetch fails: it keeps the session
        #expect(await c.state == .joining)
        await c.cancel()                                     // returns although the logout it starts never answers
        #expect(await c.state == .cancelled)
        let task = try #require(await c.logoutTask, "the join session existed and its logout was started")
        for _ in 0..<200 where t.logoutsStarted == 0 { await Task.yield() }
        #expect(t.logoutsStarted == 1)
        task.cancel()
    }
}
