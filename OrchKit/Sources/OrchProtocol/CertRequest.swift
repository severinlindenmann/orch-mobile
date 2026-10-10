import CryptoKit
import Foundation

/// The keys a new device asks its owner's primary device to certify (section 8.4). No host nonce: anything the host
/// chooses could be ground against the 30-bit code.
public struct CertRequestInner: Equatable, Sendable {
    public let deviceID: ID16
    public let dkSig: SigningPublicKey
    public let dkKx: AgreementPublicKey
    public let label: String
    public let scopesMax: [String]
    public let offerID: ID16

    public init(deviceID: ID16, dkSig: SigningPublicKey, dkKx: AgreementPublicKey, label: String, scopesMax: [String], offerID: ID16) {
        self.deviceID = deviceID; self.dkSig = dkSig; self.dkKx = dkKx; self.label = label; self.scopesMax = scopesMax; self.offerID = offerID
    }

    static let fields: Set<String> = ["device_id", "dk_sig_pub", "dk_kx_pub", "label", "scopes_max", "offer_id"]
    static let maxBytes = 4096

    var json: JSONValue {
        ["device_id": .string(deviceID.hex), "dk_sig_pub": .string(B64U.encode(dkSig.x963)), "dk_kx_pub": .string(B64U.encode(dkKx.x963)),
         "label": .string(label), "scopes_max": .array(scopesMax.map { .string($0) }), "offer_id": .string(offerID.hex)]
    }

    /// Exact field set, valid keys, `device_id` derived from `dk_sig_pub`, valid scopes: otherwise `malformed`.
    static func parse(_ plaintext: Data) throws -> CertRequestInner {
        guard let v = try? StrictJSON.parse(plaintext, maxBytes: maxBytes), let o = v.object, o.hasExactly(fields),
              let id = o.id16("device_id"), let offer = o.id16("offer_id"), let label = o["label"]?.string,
              let sig = o.b64u("dk_sig_pub", length: Suite2.publicKeyLength).flatMap({ try? SigningPublicKey(x963: $0) }),
              let kx = o.b64u("dk_kx_pub", length: Suite2.publicKeyLength).flatMap({ try? AgreementPublicKey(x963: $0) }),
              let raw = o["scopes_max"]?.array, case let scopes = raw.compactMap(\.string), scopes.count == raw.count,
              Scopes.isValid(scopes), id == Identifiers.deviceID(sig)
        else { throw Refusal.malformed }
        return CertRequestInner(deviceID: id, dkSig: sig, dkKx: kx, label: label, scopesMax: scopes, offerID: offer)
    }
}

/// What the primary device remembers across cert requests (section 8.4): ids it has seen, the one open request per
/// workspace, rejected and signed requests, and the challenges it issued. A value type: persist it between calls.
public struct PrimaryLedger: Equatable, Sendable {
    public struct OpenRequest: Equatable, Sendable { public let requestID: ID16, expiresMs: Int64 }

    struct Accepted: Equatable, Sendable {
        let workspace: ID16, person: ID16, expiresMs: Int64
        let inner: CertRequestInner
    }

    public private(set) var seen: Set<ID16> = []
    public private(set) var open: [ID16: OpenRequest] = [:]
    public private(set) var signed: Set<ID16> = []
    public private(set) var rejected: Set<ID16> = []
    var accepted: [ID16: Accepted] = [:]
    public private(set) var challenges: [ID16: [String: JSONValue]] = [:]

    public init() {}

    /// A workspace's request is open while it is unexpired and neither signed nor rejected, so an expired or rejected
    /// request never blocks the next one.
    public func openRequest(workspace: ID16, nowMs: Int64) -> ID16? {
        guard let e = open[workspace], nowMs < e.expiresMs, !signed.contains(e.requestID), !rejected.contains(e.requestID) else { return nil }
        return e.requestID
    }

    /// The human rejected the code: nothing is ever signed for this request.
    public mutating func reject(requestID: ID16) {
        rejected.insert(requestID)
        for (ws, e) in open where e.requestID == requestID { open[ws] = nil }
    }

    /// The primary draws `primary_nonce` (32 CSPRNG bytes) only now, after the keys reached it, and keeps the challenge as
    /// the only thing it will ever certify for this request. Built from the stored request, never from caller input.
    package mutating func issueChallenge(requestID: ID16, primaryNonce: Data, primary: some Signer, nowMs: Int64) throws -> SignedObject {
        guard let a = accepted[requestID] else { throw Refusal.unknownRequest }
        guard nowMs < a.expiresMs else { throw Refusal.expired }
        guard primaryNonce.count == 32 else { throw CryptoFailure.invalidLength }
        guard Identifiers.personID(primary.publicKey) == a.person else { throw Refusal.otherPerson }
        guard challenges[requestID] == nil else { throw Refusal.replayed }
        guard !signed.contains(requestID) else { throw Refusal.alreadySigned }
        guard !rejected.contains(requestID) else { throw Refusal.rejected }
        let o: [String: JSONValue] = [
            "v": 2, "suite": 2, "kind": "cert_challenge", "request_id": .string(requestID.hex), "workspace_id": .string(a.workspace.hex),
            "person_id": .string(a.person.hex), "device_id": .string(a.inner.deviceID.hex),
            "dk_sig_pub": .string(B64U.encode(a.inner.dkSig.x963)), "dk_kx_pub": .string(B64U.encode(a.inner.dkKx.x963)),
            "primary_nonce": .string(B64U.encode(primaryNonce)), "expires_ms": .int(a.expiresMs)]
        let s = try CertChallenge.sign(o, primary: primary)
        challenges[requestID] = o
        return s
    }

    /// After the human confirmed the code: certifies exactly the keys of the primary's own stored challenge, once, only
    /// while unexpired and not rejected. `createdMs` is the primary's clock. A primary never makes a drop-scoped
    /// certificate this way (section 8.4): `scopesMax` must be a non-empty prefix of the four scopes.
    package mutating func signCertificate(requestID: ID16, labelSealed: Data, createdMs: Int64, expiresMs: Int64?, scopesMax: [String],
                                          primary: some Signer) throws -> SignedObject {
        guard let ch = challenges[requestID], let ws = ch.id16("workspace_id"), let device = ch.id16("device_id"),
              let person = ch.id16("person_id"), let expires = ch["expires_ms"]?.int else { throw Refusal.unknownRequest }
        guard !signed.contains(requestID) else { throw Refusal.alreadySigned }
        guard !rejected.contains(requestID) else { throw Refusal.rejected }
        guard createdMs < expires else { throw Refusal.expired }
        guard Identifiers.personID(primary.publicKey) == person else { throw Refusal.otherPerson }
        guard Scopes.isValid(scopesMax), !scopesMax[0].bytesHasPrefix("drop:") else { throw Refusal.scopeExceeded }
        // never wider than what the stored request asked for (both are prefixes of the ordered scopes)
        guard let asked = accepted[requestID]?.inner.scopesMax, scopesMax.count <= asked.count else { throw Refusal.scopeExceeded }
        if let e = expiresMs, e <= createdMs { throw Refusal.malformed }
        let cert = try SignedObject.sign([
            "v": 2, "suite": 2, "kind": "device_cert", "device_id": .string(device.hex), "person_id": .string(person.hex),
            "dk_sig_pub": ch["dk_sig_pub"] ?? .null, "dk_kx_pub": ch["dk_kx_pub"] ?? .null,
            "label_sealed": .string(B64U.encode(labelSealed)), "created_ms": .int(createdMs),
            "expires_ms": expiresMs.map { .int($0) } ?? .null, "scopes_max": .array(scopesMax.map { .string($0) })],
                                         kind: .deviceCert, signer: primary)
        signed.insert(requestID)
        open[ws] = nil
        return cert
    }

    mutating func record(_ a: Accepted, requestID: ID16) {
        seen.insert(requestID)
        open[a.workspace] = OpenRequest(requestID: requestID, expiresMs: a.expiresMs)
        accepted[requestID] = a
    }
}

public enum CertRequest {
    static let fields: Set<String> = ["v", "suite", "kind", "request_id", "workspace_id", "person_id", "primary_device_id",
                                      "created_ms", "expires_ms", "sealed"]
    public static let lifetimeMs: Int64 = 600_000
    public static let maxSealedBytes = 8192

    public struct Accepted: Equatable, Sendable {
        public let requestID: ID16
        public let inner: CertRequestInner
        /// The card is client-hosted: the primary goes on but warns "this workspace runs on a machine that someone else
        /// administers".
        public let clientHostedWarning: Bool
    }

    /// What the owner's primary device checks before it draws its nonce (section 8.4, in the specified order).
    /// `card` is the workspace's verified card (its delegation already verified). The ledger changes only on success.
    package static func openAsPrimary(_ signed: JSONValue, card: VerifiedCard, myPerson: ID16, me: ID16, myKey: some KeyAgreer,
                                      ledger: inout PrimaryLedger, nowMs: Int64) throws -> Accepted {
        guard card.ownerPersonID == myPerson else { throw Refusal.otherPerson }
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(signed).verify(kind: .certRequest, key: card.wsk) } catch { throw Refusal.badSignature }
        guard o.hasExactly(fields), let reqID = o.id16("request_id"), let ws = o.id16("workspace_id"), let person = o.id16("person_id"),
              let primary = o.id16("primary_device_id"), let created = o["created_ms"]?.int, let expires = o["expires_ms"]?.int,
              let sealed = o.b64u("sealed"), sealed.count <= maxSealedBytes else { throw Refusal.malformed }
        guard ws == card.workspace else { throw Refusal.badSignature }
        guard primary == me, person == myPerson else { throw Refusal.notForThisDevice }
        let lower = saturatingAdd(created, -Suite2.skewMs)
        guard lower <= nowMs, nowMs < expires, expires.subtractingReportingOverflow(created).partialValue <= lifetimeMs,
              !expires.subtractingReportingOverflow(created).overflow else { throw Refusal.expired }
        guard !ledger.seen.contains(reqID) else { throw Refusal.replayed }
        guard ledger.openRequest(workspace: ws, nowMs: nowMs) == nil else { throw Refusal.requestOpen }
        let plain: Data
        do { plain = try Sealing.open(with: myKey, recipientID: me, purpose: .certRequest, object: reqID, epoch: 0, sealed: sealed) }
        catch { throw Refusal.malformed }
        let inner = try CertRequestInner.parse(plain)
        guard !inner.scopesMax[0].bytesHasPrefix("drop:") else { throw Refusal.scopeExceeded }   // agents enrol through section 6.4 only
        ledger.record(.init(workspace: ws, person: person, expiresMs: expires, inner: inner), requestID: reqID)
        return Accepted(requestID: reqID, inner: inner, clientHostedWarning: card.delegation.clientHosted)
    }

    /// Host side: the request to the primary's queue, signed by `WSK`, with `inner` sealed to the primary's `dk_kx`.
    package static func make(wsk: some Signer, requestID: ID16, workspace: ID16, person: ID16, primary: ID16, primaryKey: AgreementPublicKey,
                             inner: CertRequestInner, createdMs: Int64) throws -> SignedObject {
        let sealed = try Sealing.seal(to: primaryKey, recipientID: primary, purpose: .certRequest, object: requestID, epoch: 0,
                                      plaintext: canonicalJSON(inner.json))
        return try SignedObject.sign([
            "v": 2, "suite": 2, "kind": "cert_request", "request_id": .string(requestID.hex), "workspace_id": .string(workspace.hex),
            "person_id": .string(person.hex), "primary_device_id": .string(primary.hex), "created_ms": .int(createdMs),
            "expires_ms": .int(saturatingAdd(createdMs, lifetimeMs)), "sealed": .string(B64U.encode(sealed))],
                                     kind: .certRequest, signer: wsk)
    }
}

/// Why a phone dropped the primary's challenge (section 8.4 step 5). `notMyKey` raises the alarm.
public enum CertChallengeDrop: String, Error, Sendable, Equatable {
    case challengeSignature = "challenge_signature"
    case notForThisWorkspace = "not_for_this_workspace"
    case notMyKey = "not_my_key"
    case challengeExpired = "challenge_expired"
    public var raisesAlarm: Bool { self == .notMyKey }
}

public enum CertChallenge {
    static let fields: Set<String> = ["v", "suite", "kind", "request_id", "workspace_id", "person_id", "device_id", "dk_sig_pub",
                                      "dk_kx_pub", "primary_nonce", "expires_ms"]

    package static func sign(_ o: [String: JSONValue], primary: some Signer) throws -> SignedObject {
        try SignedObject.sign(o, kind: .certChallenge, signer: primary)
    }

    /// What the phone checks before it shows anything. Check the link's `pk_pin` against `pk` first (the pairing
    /// coordinator's job). Then: the signature with `pk` and the exact field set, the workspace and person, that the three
    /// device fields are the phone's own, and that `now < expires_ms`. Returns the challenge object and `cert_code`.
    public static func check(_ signed: JSONValue, pk: SigningPublicKey, workspace: ID16, device: ID16, dkSig: SigningPublicKey,
                             dkKx: AgreementPublicKey, nowMs: Int64) throws -> (object: [String: JSONValue], certCode: String) {
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(signed).verify(kind: .certChallenge, key: pk) } catch { throw CertChallengeDrop.challengeSignature }
        guard o.hasExactly(fields), o.b64u("primary_nonce", length: 32) != nil, let expires = o["expires_ms"]?.int,
              let ws = o.id16("workspace_id"), let person = o.id16("person_id"), let dev = o.id16("device_id"),
              let sig = o.b64u("dk_sig_pub"), let kx = o.b64u("dk_kx_pub"), o.id16("request_id") != nil
        else { throw CertChallengeDrop.challengeSignature }
        guard ws == workspace, person == Identifiers.personID(pk) else { throw CertChallengeDrop.notForThisWorkspace }
        guard dev == device, sig == dkSig.x963, kx == dkKx.x963 else { throw CertChallengeDrop.notMyKey }
        guard nowMs < expires else { throw CertChallengeDrop.challengeExpired }
        return (o, try Identifiers.certCode(challengeObject: .object(o)))
    }
}

/// Relay login (section 12.2): the bytes a client signs, and the relay's own check order.
public enum RelayAuth {
    public enum Kind: UInt8, Sendable { case device = 1, workspace = 2
        init?(wire: String) {
            if wire.bytesEqual("device") { self = .device } else if wire.bytesEqual("workspace") { self = .workspace } else { return nil }
        }
    }
    public static let challengeMs: Int64 = 60_000

    /// `"orch/v2/sig/relay-auth|" || suite || lp16(origin) || challenge (32) || u8(1 device | 2 workspace) || id (16)`.
    /// `origin` is the relay's own origin (ASCII, never one the client names).
    public static func signedBytes(origin: String, challenge: Data, kind: Kind, id: ID16) throws -> Data {
        guard challenge.count == 32, origin.utf8.allSatisfy({ $0 < 0x80 }), origin.utf8.count < 1 << 16 else { throw CryptoFailure.invalidLength }
        return Data(Label.sigRelayAuth.utf8) + Bytes.u8(Suite2.id) + Bytes.lp16(Data(origin.utf8)) + challenge + Bytes.u8(kind.rawValue) + id.bytes
    }

    package static func sign(_ signer: some Signer, origin: String, challenge: Data, kind: Kind, id: ID16) throws -> Data {
        let b = try signedBytes(origin: origin, challenge: challenge, kind: kind, id: id)
        let sig = try signer.rawSignature(over: b)
        guard sig.count == Suite2.signatureLength else { throw CryptoFailure.invalidLength }
        return sig
    }

    public struct Reply: Equatable, Sendable {
        public let status: Int
        public let error: String?
    }

    /// The relay's check (it is the relay's code; the fake relay uses it too). `challenges` maps an issued challenge to its
    /// `expires_ms` and is single use: removed whatever happens next. `origin` is the relay's own. `pub` comes from the
    /// certificate or card of `id`. Order: unknown_challenge, expired, malformed (unknown kind), bad_signature.
    public static func check(challenges: inout [Data: Int64], origin: String, challenge: Data, kind: String, id: ID16, signature: Data,
                             pub: SigningPublicKey, nowMs: Int64) -> Reply {
        guard let expires = challenges.removeValue(forKey: challenge) else { return Reply(status: 401, error: "unknown_challenge") }
        guard nowMs < expires else { return Reply(status: 401, error: "expired") }
        guard let k = Kind(wire: kind) else { return Reply(status: 400, error: "malformed") }
        guard let bytes = try? signedBytes(origin: origin, challenge: challenge, kind: k, id: id),
              Signature.verify(pub, signature: signature, message: bytes) else { return Reply(status: 401, error: "bad_signature") }
        return Reply(status: 200, error: nil)
    }
}
