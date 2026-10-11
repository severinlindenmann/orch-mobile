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
