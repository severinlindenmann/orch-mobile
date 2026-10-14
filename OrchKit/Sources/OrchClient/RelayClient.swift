import Foundation
import OrchCustody
import OrchProtocol

/// Typed calls over any `RelayTransport`: login (section 12.2) and the verified-later fetches. It decodes the adapter
/// wrappers strictly and maps failures; it verifies no signature (that is the coordinator's job) and holds no keys.
public struct RelayClient: Sendable {
    public let transport: any RelayTransport
    public init(transport: any RelayTransport) { self.transport = transport }

    /// A session and its expiry. The bearer is redacted from every textual rendering.
    public struct Opened: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let session: RelaySession
        public let expiresMs: Int64
        public var description: String { "Opened(session: <redacted>, expiresMs: \(expiresMs))" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["expiresMs": expiresMs], displayStyle: .struct) }
    }

    /// challenge, sign with the device's `dk_sig`, login. The login is bound to this transport: the signed origin is
    /// `transport.context.origin` (never a caller-supplied or relay-named one), and the identity must carry the transport's
    /// realm. Both are checked before the first request, so a Demo key cannot sign a live origin and a live key cannot sign
    /// for Demo through any transport, including one that merely forwards to another.
    public func openDeviceSession(identity: DeviceIdentity, deviceID: ID16) async throws -> Opened {
        try transport.context.admit(identity: identity)
        guard Identifiers.deviceID(identity.sig.publicKey) == deviceID else { throw TransportError.invalidArgument }
        return try await openSession(kind: .device, id: deviceID, signer: identity.sig)
    }

    package func openSession(kind: RelayAuth.Kind, id: ID16, signer: some Signer) async throws -> Opened {
        let context = transport.context
        do { try context.generation?.check(); try context.admit(origin: context.origin) }
        catch let v as RealmViolation { throw TransportError.realm(v) }
        let ch = try HostAPI.challenge(try HostAPI.expect(try await transport.challenge()))
        let sig = try RelayAuth.sign(signer, origin: context.origin, challenge: ch.challenge, kind: kind, id: id)
        let reply = try await transport.login(HostAPI.loginBody(challenge: ch.challenge, kind: kind, id: id, signature: sig))
        let l = try HostAPI.login(try HostAPI.expect(reply))
        return Opened(session: l.session, expiresMs: l.expiresMs)
    }

    public func grants(workspace: ID16, epoch: UInt32? = nil, session: RelaySession) async throws -> [JSONValue] {
        try HostAPI.grants(try HostAPI.expect(try await transport.grants(workspaceID: workspace, epoch: epoch, session: session)))
    }

    public func memberList(workspace: ID16, session: RelaySession) async throws -> JSONValue {
        try HostAPI.memberList(try HostAPI.expect(try await transport.memberList(workspaceID: workspace, session: session)))
    }

    public func card(workspace: ID16, session: RelaySession) async throws -> JSONValue {
        try HostAPI.card(try HostAPI.expect(try await transport.card(workspaceID: workspace, session: session)))
    }

    public func cardKey(workspace: ID16, cardSequence: UInt32, session: RelaySession) async throws -> HostAPI.CardKey {
        try HostAPI.cardKey(try HostAPI.expect(try await transport.cardKey(workspaceID: workspace, cardSequence: cardSequence, session: session)))
    }

    // MARK: the primary device's queue (P3-D11)

    /// Open requests addressed to this (primary) device. Each is unverified here; the primary runs section 8.4 step 2 on it.
    public func certRequests(person: ID16, wait: Int? = nil, session: RelaySession) async throws -> [JSONValue] {
        try HostAPI.certRequests(try HostAPI.expect(try await transport.certRequests(person: person, wait: wait, session: session)))
    }

    /// Posts the primary's PK-signed `cert_challenge`. The relay answers 200 `{}` both for the first submission and for a
    /// resubmission of the identical canonical object (re-signed or not), so a resend after a lost reply is success; any other
    /// challenge for the request is 409 `replayed` and thrown.
    public func submitCertChallenge(_ signed: JSONValue, requestID: ID16, session: RelaySession) async throws {
        let body = try canonicalJSON(.object(["challenge": signed]))
        try HostAPI.empty(try HostAPI.expect(try await transport.postCertChallenge(requestID: requestID, body, session: session)))
    }

    /// Posts the primary's PK-signed `cert_rejection`; idempotent like `submitCertChallenge` (200 on an identical resubmission).
    public func submitCertRejection(_ signed: JSONValue, requestID: ID16, session: RelaySession) async throws {
        let body = try canonicalJSON(.object(["rejection": signed]))
        try HostAPI.empty(try HostAPI.expect(try await transport.postCertRejection(requestID: requestID, body, session: session)))
    }

    /// `POST /v2/accounts` (P3-D3): the invite, the account key, the first device certificate (signed by that key) and a login
    /// signature of this device over a fresh relay challenge, bound to the transport's origin. Returns the person id, which must
    /// be `person_id(pkPub)`. The exact same request again (after a lost reply) is answered 200 by digest.
    public func createAccount(invite: String, pkPub: SigningPublicKey, deviceCert: JSONValue, identity: DeviceIdentity) async throws -> ID16 {
        let context = transport.context
        try context.admit(identity: identity)
        let device = Identifiers.deviceID(identity.sig.publicKey)
        let ch = try HostAPI.challenge(try HostAPI.expect(try await transport.challenge()))
        let sig = try RelayAuth.sign(identity.sig, origin: context.origin, challenge: ch.challenge, kind: .device, id: device)
        let body = try canonicalJSON(["invite": .string(invite), "pk_pub": .string(B64U.encode(pkPub.x963)), "device_cert": deviceCert,
                                      "challenge": .string(B64U.encode(ch.challenge)), "sig": .string(B64U.encode(sig))])
        let person = try HostAPI.account(try HostAPI.expect(try await transport.createAccount(body)))
        guard person == Identifiers.personID(pkPub) else { throw ClientError.badReply }
        return person
    }

    /// The page walk is bounded: a relay that keeps returning `next` cannot make the client loop.
    public static let maxRevocationPages = 8

    /// Every PK-signed revocation record of `device` made by `person` (the pinned owner), fetched without a session (a revoked
    /// device has none; the record is public). Walks `?after=<next>` for at most `maxRevocationPages` pages and collects every pair
    /// whose `person_id` is `person` (a relay can hold several records for one pair; the caller verifies each under the pinned
    /// person key and acts on any that verifies). The relay's `provenance` labels are ignored. The records are unverified. No such
    /// pair on the walk is a relay `not_found`.
    public func revocations(device: ID16, person: ID16) async throws -> [JSONValue] {
        var after: String?
        var found: [JSONValue] = []
        for _ in 0..<Self.maxRevocationPages {
            let page = try HostAPI.revocationPage(try HostAPI.expect(try await transport.revocation(deviceID: device, after: after, limit: nil)))
            found += page.pairs.filter { $0.personID == person }.map(\.revocation)
            guard let next = page.next, next != after else { break }
            after = next
        }
        if found.isEmpty { throw ClientError.relay(RelayRefusal(status: 404, code: .notFound)) }
        return found
    }

    /// The first record of `revocations(device:person:)`; use `revocations` when the caller verifies, so a forged first record
    /// cannot hide a genuine later one.
    public func revocation(device: ID16, person: ID16) async throws -> JSONValue {
        try await revocations(device: device, person: person)[0]
    }
}
