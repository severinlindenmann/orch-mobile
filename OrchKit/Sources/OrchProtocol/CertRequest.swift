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
    /// The device's pairing-attempt nonce from its pair request, copied unchanged (32 lower-case hex; G3b P3-D28).
    public let attempt: String
    /// `dk_hash` of both keys (section 8.4).
    public var dkHash: Data { Identifiers.dkHash(sig: dkSig, kx: dkKx) }

    public init(deviceID: ID16, dkSig: SigningPublicKey, dkKx: AgreementPublicKey, label: String, scopesMax: [String], offerID: ID16, attempt: String) {
        self.deviceID = deviceID; self.dkSig = dkSig; self.dkKx = dkKx; self.label = label; self.scopesMax = scopesMax; self.offerID = offerID
        self.attempt = attempt
    }

    static let fields: Set<String> = ["device_id", "dk_sig_pub", "dk_kx_pub", "label", "scopes_max", "offer_id", "attempt"]
    static let maxBytes = 4096

    var json: JSONValue {
        ["device_id": .string(deviceID.hex), "dk_sig_pub": .string(B64U.encode(dkSig.x963)), "dk_kx_pub": .string(B64U.encode(dkKx.x963)),
         "label": .string(label), "scopes_max": .array(scopesMax.map { .string($0) }), "offer_id": .string(offerID.hex),
         "attempt": .string(attempt)]
    }

    /// Exact field set, valid keys, `device_id` derived from `dk_sig_pub`, valid scopes: otherwise `malformed`.
    static func parse(_ plaintext: Data) throws -> CertRequestInner {
        guard let v = try? StrictJSON.parse(plaintext, maxBytes: maxBytes), let o = v.object, o.hasExactly(fields),
              let id = o.id16("device_id"), let offer = o.id16("offer_id"), let label = o["label"]?.string,
              let sig = o.b64u("dk_sig_pub", length: Suite2.publicKeyLength).flatMap({ try? SigningPublicKey(x963: $0) }),
              let kx = o.b64u("dk_kx_pub", length: Suite2.publicKeyLength).flatMap({ try? AgreementPublicKey(x963: $0) }),
              let raw = o["scopes_max"]?.array, case let scopes = raw.compactMap(\.string), scopes.count == raw.count,
              Scopes.isValid(scopes), id == Identifiers.deviceID(sig), let attempt = o["attempt"]?.string, Identifiers.isAttempt(attempt)
        else { throw Refusal.malformed }
        return CertRequestInner(deviceID: id, dkSig: sig, dkKx: kx, label: label, scopesMax: scopes, offerID: offer, attempt: attempt)
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
            "person_id": .string(a.person.hex), "offer_id": .string(a.inner.offerID.hex), "attempt": .string(a.inner.attempt),
            "device_id": .string(a.inner.deviceID.hex),
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

    /// The human rejected the request on the primary (P3-D11): closes it like `reject(requestID:)` and returns the PK-signed
    /// `cert_rejection` the relay queue takes. Only for a request this primary accepted; never after it signed a certificate
    /// (`already_signed`). Asking again for a rejected request signs the identical object again (an idempotent resubmission).
    package mutating func signRejection(requestID: ID16, primary: some Signer) throws -> SignedObject {
        guard let a = accepted[requestID] else { throw Refusal.unknownRequest }
        guard !signed.contains(requestID) else { throw Refusal.alreadySigned }
        guard Identifiers.personID(primary.publicKey) == a.person else { throw Refusal.otherPerson }
        let s = try CertRejection.sign(requestID: requestID, workspace: a.workspace, person: a.person, offer: a.inner.offerID, attempt: a.inner.attempt,
                                       device: a.inner.deviceID, dkHash: a.inner.dkHash, expiresMs: a.expiresMs, primary: primary)
        reject(requestID: requestID)
        return s
    }

    mutating func record(_ a: Accepted, requestID: ID16) {
        seen.insert(requestID)
        open[a.workspace] = OpenRequest(requestID: requestID, expiresMs: a.expiresMs)
        accepted[requestID] = a
    }
}

public enum CertRequest {
    static let fields: Set<String> = ["v", "suite", "kind", "request_id", "workspace_id", "person_id", "primary_device_id",
                                      "offer_id", "attempt", "device_id", "dk_hash", "created_ms", "expires_ms", "sealed"]
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
              let sealed = o.b64u("sealed"), sealed.count <= maxSealedBytes,
              let clearOffer = o.id16("offer_id"), let clearAttempt = o["attempt"]?.string, Identifiers.isAttempt(clearAttempt),
              let clearDevice = o.id16("device_id"), let clearHash = o.b64u("dk_hash", length: 32) else { throw Refusal.malformed }
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
        // step 2.7 (G3b): the clear attempt binding the relay sees must be exactly the sealed inner's
        guard clearOffer == inner.offerID, clearAttempt.utf8.elementsEqual(inner.attempt.utf8), clearDevice == inner.deviceID,
              clearHash == inner.dkHash else { throw Refusal.malformed }
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
            "person_id": .string(person.hex), "primary_device_id": .string(primary.hex), "offer_id": .string(inner.offerID.hex),
            "attempt": .string(inner.attempt), "device_id": .string(inner.deviceID.hex), "dk_hash": .string(B64U.encode(inner.dkHash)),
            "created_ms": .int(createdMs),
            "expires_ms": .int(saturatingAdd(createdMs, lifetimeMs)), "sealed": .string(B64U.encode(sealed))],
                                     kind: .certRequest, signer: wsk)
    }
}

/// Why a phone dropped the primary's challenge (section 8.4 step 5, G3b order). `notMyKey` raises the alarm.
public enum CertChallengeDrop: String, Error, Sendable, Equatable {
    case challengeSignature = "challenge_signature"
    case notForThisWorkspace = "not_for_this_workspace"
    case notMyKey = "not_my_key"
    case staleAttempt = "stale_attempt"
    case notForThisPairing = "not_for_this_pairing"
    case challengeExpired = "challenge_expired"
    public var raisesAlarm: Bool { self == .notMyKey }
}

/// What the phone knows of its own pairing attempt when it judges a PK-signed object (G3b, P3-D28): the link's workspace and
/// offer, its current device and keys, its attempt nonce, the `(device_id, dk_hash)` of its own earlier attempts (kept at least
/// 10 minutes), and the `request_id` of a challenge it already accepted in this attempt.
public struct PairingAttemptContext: Sendable, Equatable {
    public var workspace: ID16
    public var offer: ID16
    public var device: ID16
    public var dkSig: SigningPublicKey
    public var dkKx: AgreementPublicKey
    public var attempt: String
    public var earlierAttempts: [EarlierAttempt]
    public var acceptedRequestID: ID16?

    public struct EarlierAttempt: Sendable, Equatable, Hashable {
        public let deviceID: ID16
        public let dkHash: Data
        public init(deviceID: ID16, dkHash: Data) { self.deviceID = deviceID; self.dkHash = dkHash }
    }

    public init(workspace: ID16, offer: ID16, device: ID16, dkSig: SigningPublicKey, dkKx: AgreementPublicKey, attempt: String,
                earlierAttempts: [EarlierAttempt], acceptedRequestID: ID16?) {
        self.workspace = workspace; self.offer = offer; self.device = device; self.dkSig = dkSig; self.dkKx = dkKx; self.attempt = attempt
        self.earlierAttempts = earlierAttempts; self.acceptedRequestID = acceptedRequestID
    }

    public var dkHash: Data { Identifiers.dkHash(sig: dkSig, kx: dkKx) }

    /// Step 4 of both checks when the object does not name this attempt's own device and keys: an expired object is silent
    /// (`expired`), one naming both the device id AND the key hash of an own earlier attempt is `stale_attempt`, anything else is
    /// foreign and raises the alarm (`not_my_key`). Both must match: an old signing key with another exchange key is foreign.
    func foreign(device: ID16, dkHash: Data, expired: Bool, expiredDrop: Error) -> Error {
        if expired { return expiredDrop }
        if earlierAttempts.contains(EarlierAttempt(deviceID: device, dkHash: dkHash)) { return CertChallengeDrop.staleAttempt }
        return CertChallengeDrop.notMyKey
    }
}

public enum CertChallenge {
    static let fields: Set<String> = ["v", "suite", "kind", "request_id", "workspace_id", "person_id", "offer_id", "attempt", "device_id",
                                      "dk_sig_pub", "dk_kx_pub", "primary_nonce", "expires_ms"]

    package static func sign(_ o: [String: JSONValue], primary: some Signer) throws -> SignedObject {
        try SignedObject.sign(o, kind: .certChallenge, signer: primary)
    }

    /// What the phone checks before it shows anything (section 8.4 step 5, G3b order), after the coordinator checked the link's
    /// `pk_pin` against `pk` (step 1): 2 the signature with `pk` and the exact field set (`challenge_signature`); 3 the workspace
    /// and person (`not_for_this_workspace`); 4 the device id and both keys are this attempt's own, else expired -> silent,
    /// own earlier attempt -> `stale_attempt`, otherwise `not_my_key` (alarm); 5 `attempt` and `offer_id` (`not_for_this_pairing`);
    /// 6 the `request_id` of a challenge already accepted in this attempt (`not_for_this_pairing`); 7 `now < expires_ms`
    /// (`challenge_expired`). Returns the challenge object and `cert_code`.
    public static func check(_ signed: JSONValue, pk: SigningPublicKey, attempt c: PairingAttemptContext, nowMs: Int64) throws
        -> (object: [String: JSONValue], certCode: String) {
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(signed).verify(kind: .certChallenge, key: pk) } catch { throw CertChallengeDrop.challengeSignature }
        guard o.hasExactly(fields), o.b64u("primary_nonce", length: 32) != nil, let expires = o["expires_ms"]?.int,
              let ws = o.id16("workspace_id"), let person = o.id16("person_id"), let dev = o.id16("device_id"), let rid = o.id16("request_id"),
              let offer = o.id16("offer_id"), let attempt = o["attempt"]?.string, Identifiers.isAttempt(attempt),
              let sig = o.b64u("dk_sig_pub", length: Suite2.publicKeyLength), let kx = o.b64u("dk_kx_pub", length: Suite2.publicKeyLength)
        else { throw CertChallengeDrop.challengeSignature }
        guard ws == c.workspace, person == Identifiers.personID(pk) else { throw CertChallengeDrop.notForThisWorkspace }
        guard dev == c.device, sig == c.dkSig.x963, kx == c.dkKx.x963 else {
            throw c.foreign(device: dev, dkHash: Identifiers.dkHash(sig: sig, kx: kx), expired: nowMs >= expires,
                            expiredDrop: CertChallengeDrop.challengeExpired)
        }
        guard attempt.utf8.elementsEqual(c.attempt.utf8), offer == c.offer else { throw CertChallengeDrop.notForThisPairing }
        if let seen = c.acceptedRequestID, seen != rid { throw CertChallengeDrop.notForThisPairing }
        guard nowMs < expires else { throw CertChallengeDrop.challengeExpired }
        return (o, try Identifiers.certCode(challengeObject: .object(o)))
    }
}

/// Why a phone does not attribute a `rejected` answer to the owner (section 8.3, G3b). Only `notMyKey` raises the alarm.
public enum CertRejectionDrop: String, Error, Sendable, Equatable {
    case notAPairingAnswer = "not_a_pairing_answer"
    case pkPin = "pk_pin"
    case rejectionSignature = "rejection_signature"
    case notForThisWorkspace = "not_for_this_workspace"
    case notMyKey = "not_my_key"
    case staleAttempt = "stale_attempt"
    case notForThisPairing = "not_for_this_pairing"
    case rejectionExpired = "rejection_expired"
    public var raisesAlarm: Bool { self == .notMyKey }
}

/// The primary's PK-signed rejection of a cert request (P3-D11, G3b P3-D28):
/// `{"o": {v, suite, kind: "cert_rejection", request_id, workspace_id, person_id, offer_id, attempt, device_id, dk_hash, expires_ms},
///   "sig": Sign(PK, "orch/v2/sig/cert-rejection|" || cj(o))}`. Only `PK` can sign one, and it names one attempt of one device.
public enum CertRejection {
    static let fields: Set<String> = ["v", "suite", "kind", "request_id", "workspace_id", "person_id", "offer_id", "attempt", "device_id",
                                      "dk_hash", "expires_ms"]

    package static func sign(requestID: ID16, workspace: ID16, person: ID16, offer: ID16, attempt: String, device: ID16, dkHash: Data,
                             expiresMs: Int64, primary: some Signer) throws -> SignedObject {
        try SignedObject.sign(["v": 2, "suite": 2, "kind": "cert_rejection", "request_id": .string(requestID.hex),
                               "workspace_id": .string(workspace.hex), "person_id": .string(person.hex), "offer_id": .string(offer.hex),
                               "attempt": .string(attempt), "device_id": .string(device.hex), "dk_hash": .string(B64U.encode(dkHash)),
                               "expires_ms": .int(expiresMs)],
                              kind: .certRejection, signer: primary)
    }

    public struct Verified: Equatable, Sendable {
        public let requestID: ID16
        public let workspace: ID16
        public let person: ID16
        public let offer: ID16
        public let attempt: String
        public let device: ID16
        public let dkHash: Data
        public let expiresMs: Int64
    }

    /// The signature under `pk` (`bad_signature`), then the exact field set and field shapes (`malformed`).
    public static func verify(_ signed: JSONValue, pk: SigningPublicKey) throws -> Verified {
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(signed).verify(kind: .certRejection, key: pk) }
        catch Refusal.malformed { throw Refusal.malformed }
        catch { throw Refusal.badSignature }
        guard o.hasExactly(fields), let rid = o.id16("request_id"), let ws = o.id16("workspace_id"), let person = o.id16("person_id"),
              let offer = o.id16("offer_id"), let attempt = o["attempt"]?.string, Identifiers.isAttempt(attempt),
              let device = o.id16("device_id"), let hash = o.b64u("dk_hash", length: 32), let expires = o["expires_ms"]?.int
        else { throw Refusal.malformed }
        return Verified(requestID: rid, workspace: ws, person: person, offer: offer, attempt: attempt, device: device, dkHash: hash, expiresMs: expires)
    }

    /// The relay's check against the stored request object (P3-D11 + P3-D28), in order: signature, field set (`malformed`),
    /// `person_id` = the request's and `person_id(pk)` (`other_person`), `workspace_id` (`other_workspace`), `request_id`
    /// (`not_for_this_device`), the request's `expires_ms` (`malformed`), then the clear attempt binding `offer_id`, `attempt`,
    /// `device_id`, `dk_hash` (`not_for_this_device`).
    public static func check(_ signed: JSONValue, pk: SigningPublicKey, request: [String: JSONValue]) throws -> Verified {
        let v = try verify(signed, pk: pk)
        guard v.person == Identifiers.personID(pk), v.person == request.id16("person_id") else { throw Refusal.otherPerson }
        guard v.workspace == request.id16("workspace_id") else { throw Refusal.otherWorkspace }
        guard v.requestID == request.id16("request_id") else { throw Refusal.notForThisDevice }
        guard v.expiresMs == request["expires_ms"]?.int else { throw Refusal.malformed }
        guard v.offer == request.id16("offer_id"), request["attempt"]?.string.map({ $0.utf8.elementsEqual(v.attempt.utf8) }) == true,
              v.device == request.id16("device_id"), v.dkHash == request.b64u("dk_hash", length: 32) else { throw Refusal.notForThisDevice }
        return v
    }

    /// The phone's check of a long-form `rejected` answer (section 8.3, G3b order), after the field set and `pk_pin` (step 1):
    /// 2 signature and exact fields (`rejection_signature`); 3 workspace and person (`not_for_this_workspace`); 4 device id and
    /// `dk_hash` are this attempt's own, else expired -> `rejection_expired`, own earlier attempt -> `stale_attempt`, otherwise
    /// `not_my_key` (alarm); 5 attempt and offer (`not_for_this_pairing`); 6 the accepted challenge's request id
    /// (`not_for_this_pairing`); 7 `now < expires_ms` (`rejection_expired`). Only a full pass is a denial by the owner.
    public static func checkOnPhone(_ signed: JSONValue, pk: SigningPublicKey, attempt c: PairingAttemptContext, nowMs: Int64) throws -> Verified {
        let v: Verified
        do { v = try verify(signed, pk: pk) } catch { throw CertRejectionDrop.rejectionSignature }
        guard v.workspace == c.workspace, v.person == Identifiers.personID(pk) else { throw CertRejectionDrop.notForThisWorkspace }
        guard v.device == c.device, v.dkHash == c.dkHash else {
            switch c.foreign(device: v.device, dkHash: v.dkHash, expired: nowMs >= v.expiresMs, expiredDrop: CertRejectionDrop.rejectionExpired) {
            case CertChallengeDrop.staleAttempt: throw CertRejectionDrop.staleAttempt
            case CertChallengeDrop.notMyKey: throw CertRejectionDrop.notMyKey
            default: throw CertRejectionDrop.rejectionExpired
            }
        }
        guard v.attempt.utf8.elementsEqual(c.attempt.utf8), v.offer == c.offer else { throw CertRejectionDrop.notForThisPairing }
        if let seen = c.acceptedRequestID, seen != v.requestID { throw CertRejectionDrop.notForThisPairing }
        guard nowMs < v.expiresMs else { throw CertRejectionDrop.rejectionExpired }
        return v
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
