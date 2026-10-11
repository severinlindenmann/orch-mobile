import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchStore
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

    /// A rejection of this pairing's attempt (by default the real one) signed by `signer`, with any binding field replaced.
    static func rejection(_ h: PairHarness, requestID: ID16? = nil, workspace: ID16? = nil, person: ID16? = nil, signer: SoftwareSigner? = nil,
                          offer: ID16? = nil, attempt: String? = nil, device: ID16? = nil, dkHash: Data? = nil, expiresMs: Int64? = nil) async throws -> JSONValue {
        let b = try #require(await h.host.pairingBinding(of: h.phoneID))
        let known = await h.host.pairingRequestID(of: h.phoneID)
        let rid = requestID ?? known ?? .random()
        let stored = await h.relay.certRecord(rid)?.expiresMs
        let exp = expiresMs ?? stored ?? h.clock.nowMs + CertRequest.lifetimeMs
        return try CertRejection.sign(requestID: rid, workspace: workspace ?? h.host.workspace, person: person ?? h.primary.personID,
                                      offer: offer ?? b.offer, attempt: attempt ?? b.attempt, device: device ?? h.phoneID, dkHash: dkHash ?? b.dkHash,
                                      expiresMs: exp, primary: signer ?? h.primary.pkSigner).json
    }

    @Test func aVerifiedPrimaryRejectionEndsAsDenied() async throws {
        let h = try await Self.toComparingPrimary()
        let p = try #require(await h.primary.openPrompts().first)
        try await h.primary.reject(request: p.requestID, relay: h.relay)
        #expect(await h.relay.certRequestState(p.requestID) == "rejected")
        #expect(try await h.drive(until: { $0.isTerminal }) == .denied(owner: h.primary.personID))
        #expect(await h.host.pairingState(of: h.phoneID) == "rejected")
        #expect(await h.nothingFor(h.phoneID))
    }

    @Test func aRejectionNotSignedByThePinnedPKIsNeverAttributed() async throws {
        // a compromised host claims "the owner said no" with a rejection signed by a key of its own, once under the real pk_pub
        // (rejection_signature) and once with its own pk_pub (pk_pin): an unattributed refusal, never "Denied by the owner", no alarm
        for ownPK in [false, true] {
            let h = try await Self.toComparingPrimary()
            let attacker = SoftwareSigner()
            let forged = try await Self.rejection(h, person: ownPK ? Identifiers.personID(attacker.publicKey) : nil, signer: attacker)
            await h.host.forceRelayedRejection(device: h.phoneID, rejection: forged)
            #expect(try await h.drive(until: { $0.isTerminal }) == .rejected, "ownPK \(ownPK)")
        }
    }

    @Test func aRejectionOfAnotherWorkspaceIsUnattributed() async throws {
        let h = try await Self.toComparingPrimary()
        await h.host.forceRelayedRejection(device: h.phoneID, rejection: try await Self.rejection(h, workspace: .random()))
        #expect(try await h.drive(until: { $0.isTerminal }) == .rejected)
    }

    @Test func aRejectionOfAnotherRequestAfterTheChallengeIsUnattributed() async throws {
        // PK-signed, this attempt, but not the request whose challenge the phone accepted (step 6): unattributed, no alarm
        let h = try await Self.toComparingPrimary()
        await h.host.forceRelayedRejection(device: h.phoneID, rejection: try await Self.rejection(h, requestID: .random()))
        #expect(try await h.drive(until: { $0.isTerminal }) == .rejected)
    }

    @Test func aRejectionOfAnotherAttemptOrOfferIsUnattributed() async throws {
        for c in 0..<2 {
            let h = try await Self.toComparingPrimary()
            let r = c == 0 ? try await Self.rejection(h, attempt: String(repeating: "f", count: 32)) : try await Self.rejection(h, offer: .random())
            await h.host.forceRelayedRejection(device: h.phoneID, rejection: r)
            #expect(try await h.drive(until: { $0.isTerminal }) == .rejected, "case \(c)")
        }
    }

    @Test func aRejectionForAForeignDeviceRaisesTheAlarm() async throws {
        let h = try await Self.toComparingPrimary()
        await h.host.forceRelayedRejection(device: h.phoneID, rejection: try await Self.rejection(h, device: .random()))
        let s = try await h.drive(until: { $0.isTerminal })
        guard case .alarm(let a) = s else { Issue.record("\(s)"); return }
        #expect(a.kind == .foreignRejection)
    }

    @Test func aRejectionOfThisAttemptBeforeAnyChallengeIsDeniedByTheOwner() async throws {
        // G3b: the attempt nonce and fresh keys bind the rejection to this attempt even before a challenge was seen (open -> rejected)
        let h = try await PairHarness.make(.primaryOffline)
        _ = try await h.startToHostCode()
        try await h.hostApproves()
        _ = try await h.drive(until: { if case .waitingPrimary = $0 { return true }; return false })
        await h.host.forceRelayedRejection(device: h.phoneID, rejection: try await Self.rejection(h))
        #expect(try await h.drive(until: { $0.isTerminal }) == .denied(owner: h.primary.personID))
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
        let rej = try await Self.rejection(h, requestID: p.requestID)
        try await client.submitCertRejection(rej, requestID: p.requestID, session: session)
        let again = try await Self.rejection(h, requestID: p.requestID)
        try await client.submitCertRejection(again, requestID: p.requestID, session: session)
        #expect(await h.relay.certRecord(p.requestID)?.rejection == rej)
        #expect(await h.relay.certRequestState(p.requestID) == "rejected")
        // no rejection without the primary's device session
        let hostSession = try await h.host.openSession(transport: h.env.transport)
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .notEligible))) {
            try await client.submitCertRejection(rej, requestID: p.requestID, session: hostSession)
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
    let loginGate = OpenGate()
    func challenge() async throws -> WireReply { try await inner.challenge() }
    func login(_ body: Data) async throws -> WireReply { await loginGate.pass(); return try await inner.login(body) }
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
        #expect(await c.joinSessionBinding() == nil, "ready drops the join session")
        await c.logoutTask?.cancel()
    }

    @Test func cancelDoesNotWaitForTheLogout() async throws {
        let (h, c, t) = try await Self.joining(failGrants: true)
        let s = try await Self.run(h, c, steps: 30, until: { $0 == .joining })
        #expect(s == .joining, "\(s)")
        _ = try await Self.run(h, c, steps: 3, until: { _ in false })     // the join logs in, then its grants fetch fails: it keeps the session
        #expect(await c.state == .joining)
        // audit fix: the cached session is bound to this device, workspace and pairing generation
        let b = try #require(await c.joinSessionBinding())
        #expect(b.device == h.phoneID && b.ws == h.host.workspace)
        await c.cancel()                                     // returns although the logout it starts never answers
        #expect(await c.state == .cancelled)
        let task = try #require(await c.logoutTask, "the join session existed and its logout was started")
        for _ in 0..<200 where t.logoutsStarted == 0 { await Task.yield() }
        #expect(t.logoutsStarted == 1)
        task.cancel()
    }
}

/// Regression tests of the PairingCoordinator binding audit (PR4).
@Suite struct PairingBindingAuditTests {
    @Test func anUnparsablePinnedChallengeNeverLetsACertificateThrough() async throws {
        // before: `if let ch = r.challenge?.object?["o"]?.object` skipped the certificate <-> challenge binding when the pinned
        // challenge could not be parsed; now that is a substitution alarm
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        try await h.hostApproves()
        _ = try await h.drive(until: isComparingPrimary)
        await h.coordinator.damagePinnedChallengeForTest(.string("damaged"))
        try await h.primaryApproves()
        let s = try await h.drive(until: { $0.isTerminal || $0 == .joining })
        guard case .alarm(let a) = s else { Issue.record("\(s)"); return }
        #expect(a.kind == .pinSubstitution)
    }

    @Test func aStoredCertificateOfAnotherThanThePinnedOwnerIsNeverPresented() async throws {
        // before: admission's `other_person` (thrown before any signature check) was mapped to "valid", so an unverified stored
        // certificate could be sent with a link that pins its stated owner; now it is never presented, and a forged one is corrupt
        let live = try RealmContext.live(origin: "https://relay.example.org", pinnedOwner: SoftwareSigner().publicKey)
        let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let custody = DefaultCustody.make(vault: vault)
        let index = try await WorkspaceIndex(layout: tempLayout(realm: "live"))
        let clock = TestClock()
        let relay = FakeRelay(testingContext: live, clock: clock, wall: clock)
        let transport = try RoutedRelayTransport(context: live, origin: live.origin, sender: relay, clientAddress: "x")
        let c = PairingCoordinator(PairingConfig(context: live, transport: transport, index: index, vault: vault, custody: custody, clock: clock,
                                                 wall: clock, deviceLabel: "Phone"))
        let id = try live.deviceIdentity(custody: custody, createIfMissing: true)
        let owner = SoftwareSigner(), keys = DemoKeys(id.publicKeys)
        func cert(_ signer: SoftwareSigner) throws -> JSONValue {
            try SignedObject.sign([
                "v": 2, "suite": 2, "kind": "device_cert", "device_id": .string(keys.deviceID.hex), "person_id": .string(Identifiers.personID(owner.publicKey).hex),
                "dk_sig_pub": .string(B64U.encode(keys.sig.x963)), "dk_kx_pub": .string(B64U.encode(keys.kx.x963)),
                "label_sealed": .string(B64U.encode(Data(repeating: 1, count: 40))), "created_ms": .int(clock.nowMs), "expires_ms": .null,
                "scopes_max": ["look"]], kind: .deviceCert, signer: signer).json
        }
        try await c.storeCertificate(try cert(owner), owner: owner.publicKey)
        #expect(await c.storedCertificateIsPresentable() == false)
        try await c.storeCertificate(try cert(SoftwareSigner()), owner: owner.publicKey)        // not signed by the stated owner
        #expect(await c.storedCertificateIsPresentable() == nil)
    }
}

/// PR #45 review follow-ups.
@Suite(.timeLimit(.minutes(1))) struct PairingReviewFollowUpTests {
    @Test func aDeniedAnswerWithoutAPinnedSasNonceIsARegression() async throws {
        let h = try await PrimaryRejectionTests.toComparingPrimary()
        await h.coordinator.clearSasNonceForTest()
        await h.host.forceRelayedRejection(device: h.phoneID, rejection: try await PrimaryRejectionTests.rejection(h))
        let s = try await h.drive(until: { $0.isTerminal })
        guard case .alarm(let a) = s else { Issue.record("\(s)"); return }
        #expect(a.kind == .regression)
    }

    @Test func anUnparsablePinnedChallengeOnDeniedRaisesTheAlarm() async throws {
        let h = try await PrimaryRejectionTests.toComparingPrimary()
        await h.coordinator.damagePinnedChallengeForTest(.string("damaged"))
        await h.host.forceRelayedRejection(device: h.phoneID, rejection: try await PrimaryRejectionTests.rejection(h))
        let s = try await h.drive(until: { $0.isTerminal })
        guard case .alarm(let a) = s else { Issue.record("\(s)"); return }
        #expect(a.kind == .pinSubstitution)
    }

    @Test func aTokenOpenedAfterACancelIsLoggedOut() async throws {
        let h = try await PairHarness.make(.existingCert)
        let t = HangingLogoutTransport(h.env.transport)
        var cfg = h.config; cfg.transport = t
        let c = PairingCoordinator(cfg)
        try await h.rig.enrollExistingCertificate(into: cfg)
        _ = await c.start(link: try h.link(try await h.rig.newOffer()))
        _ = try await JoinSessionLogoutTests.run(h, c, until: isComparingHost)
        try await h.host.approvePairing(device: h.phoneID, confirmedComparison: true, relay: h.relay, transport: h.env.transport)
        _ = try await JoinSessionLogoutTests.run(h, c, until: { $0 == .joining })
        t.loginGate.close()
        let poller = Task { await c.poll() }                 // the join is now inside openDeviceSession, held at login
        for _ in 0..<2000 where t.loginGate.entered == 0 { await Task.yield() }
        #expect(t.loginGate.entered == 1)
        await c.cancel()
        t.loginGate.open()
        await poller.value
        for _ in 0..<2000 where t.logoutsStarted == 0 { await Task.yield() }
        #expect(t.logoutsStarted == 1, "the superseded login's token is logged out")
        #expect(await c.joinSessionBinding() == nil)
        await c.logoutTask?.cancel()
    }
}
