import CryptoKit
import Foundation

/// A signed object (section 2.4): `{"o": <object>, "sig": <b64u>}` with exactly those two keys,
/// `sig = Sign(key, label(kind) || cj(o))`. The signature covers the re-serialised canonical form, never the received
/// bytes.
public struct SignedObject: Equatable, Sendable {
    public let object: [String: JSONValue]
    public let signature: Data

    public init(object: [String: JSONValue], signature: Data) {
        self.object = object; self.signature = signature
    }

    /// Builds and signs. `object` must carry `v: 2`, `suite: 2` and a `kind`.
    public static func sign(_ object: [String: JSONValue], label: String, signer: some Signer) throws -> SignedObject {
        guard object["v"] == .int(2), object["suite"] == .int(Int64(Suite2.id)), object["kind"]?.string != nil else {
            throw Refusal.malformed
        }
        let sig = try Signature.sign(signer, label: label, message: try canonicalJSON(.object(object)))
        return SignedObject(object: object, signature: sig)
    }

    /// The wire form `{"o": ..., "sig": ...}`.
    public var json: JSONValue { .object(["o": .object(object), "sig": .string(B64U.encode(signature))]) }

    /// Shape check only: exactly the keys `o` and `sig`, `o` an object, `sig` a canonical 64-byte b64u string.
    public static func parse(_ v: JSONValue) throws -> SignedObject {
        guard let m = v.object, Set(m.keys) == ["o", "sig"], let o = m["o"]?.object,
              let s = m["sig"]?.string, let sig = B64U.decode(s, length: Suite2.signatureLength) else { throw Refusal.malformed }
        return SignedObject(object: o, signature: sig)
    }

    /// Section 2.4 order: `v`, `suite` and `kind` first, then the signature. Returns the object on success.
    /// Throws `Refusal.malformed` for a wrong `v`/`suite`/`kind` and `Refusal.badSignature` for a bad signature.
    public func verify(kind: String, label: String, key: SigningPublicKey) throws -> [String: JSONValue] {
        guard object["v"] == .int(2), object["suite"] == .int(Int64(Suite2.id)), object["kind"] == .string(kind) else {
            throw Refusal.malformed
        }
        guard let msg = try? canonicalJSON(.object(object)),
              Signature.verify(key, signature: signature, label: label, message: msg) else { throw Refusal.badSignature }
        return object
    }
}

/// Field-reading helpers for exact-field-set checks.
extension Dictionary where Key == String, Value == JSONValue {
    func hasExactly(_ keys: Set<String>) -> Bool { Set(self.keys) == keys }
    func id16(_ k: String) -> ID16? { self[k]?.string.flatMap { ID16(hex: $0) } }
    func b64u(_ k: String, length: Int? = nil) -> Data? { self[k]?.string.flatMap { B64U.decode($0, length: length) } }
}

/// The closed list of scopes (section 6.1): a non-empty prefix of look, decide, operate, type; or exactly one
/// `drop:<space_id hex>`.
public enum Scopes {
    public static let order = ["look", "decide", "operate", "type"]

    public static func isValid(_ scopes: [String]) -> Bool {
        if scopes.count == 1, scopes[0].hasPrefix("drop:"), ID16(hex: String(scopes[0].dropFirst(5))) != nil { return true }
        return !scopes.isEmpty && scopes == Array(order.prefix(scopes.count))
    }
}

/// A verified device certificate (section 6.1).
public struct DeviceCertificate: Equatable, Sendable {
    public let deviceID: ID16
    public let personID: ID16
    public let signingKey: SigningPublicKey
    public let agreementKey: AgreementPublicKey
    public let labelSealed: Data
    public let createdMs: Int64
    public let expiresMs: Int64?
    public let scopesMax: [String]
    public var isScopedAgent: Bool { scopesMax.first?.hasPrefix("drop:") == true }
    public var identity: Identity { Identity(deviceID: deviceID, personID: personID) }

    /// Who a certificate names; what a revocation is checked against.
    public struct Identity: Equatable, Sendable {
        public let deviceID: ID16
        public let personID: ID16
        public init(deviceID: ID16, personID: ID16) { self.deviceID = deviceID; self.personID = personID }
    }

    static let fields: Set<String> = ["v", "suite", "kind", "device_id", "person_id", "dk_sig_pub", "dk_kx_pub",
                                      "label_sealed", "created_ms", "expires_ms", "scopes_max"]

    /// Verifies a certificate signed by `personKey`. Refusals as section 6.1: `cert_invalid` (bad signature or field
    /// set, an id not of its key, bad scopes, `created_ms > now + 300 s`), `cert_expired` (`now >= expires_ms`),
    /// `revoked`.
    public static func verify(_ signed: JSONValue, personKey: SigningPublicKey, nowMs: Int64,
                              revoked: Set<ID16> = []) throws -> DeviceCertificate {
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(signed).verify(kind: "device_cert", label: Label.sigDeviceCert, key: personKey) }
        catch { throw Refusal.certInvalid }
        guard o.hasExactly(fields),
              let sigPub = o.b64u("dk_sig_pub", length: Suite2.publicKeyLength).flatMap({ try? SigningPublicKey(x963: $0) }),
              let kxPub = o.b64u("dk_kx_pub", length: Suite2.publicKeyLength).flatMap({ try? AgreementPublicKey(x963: $0) }),
              let labelSealed = o.b64u("label_sealed"),
              let deviceID = o.id16("device_id"), let personID = o.id16("person_id"),
              deviceID == Identifiers.deviceID(sigPub), personID == Identifiers.personID(personKey),
              let scopeValues = o["scopes_max"]?.array,
              case let scopes = scopeValues.compactMap(\.string), scopes.count == scopeValues.count, Scopes.isValid(scopes),
              let created = o["created_ms"]?.int, let expiresValue = o["expires_ms"]
        else { throw Refusal.certInvalid }
        var expires: Int64?
        if !expiresValue.isNull {
            guard let e = expiresValue.int, e > created else { throw Refusal.certInvalid }
            expires = e
        }
        let cert = DeviceCertificate(deviceID: deviceID, personID: personID, signingKey: sigPub, agreementKey: kxPub,
                                     labelSealed: labelSealed, createdMs: created, expiresMs: expires, scopesMax: scopes)
        if cert.isScopedAgent && expires == nil { throw Refusal.certInvalid }   // a scoped agent always expires (D15)
        if created > nowMs + Suite2.skewMs { throw Refusal.certInvalid }
        if let e = expires, nowMs >= e { throw Refusal.certExpired }
        if revoked.contains(deviceID) { throw Refusal.revoked }
        return cert
    }
}

/// A verified revocation (section 6.2).
public struct Revocation: Equatable, Sendable {
    public static let reasons: Set<String> = ["lost", "retired", "compromised"]
    public let personID: ID16
    public let deviceID: ID16
    public let revokedMs: Int64
    public let reason: String

    /// `bad_signature` for a bad signature or field set, `malformed` for another person id than the key's, a reason
    /// outside the list or a bad `revoked_ms`, `other_person` when `cert` (the identity in the device's certificate)
    /// is missing or names another person or device.
    public static func verify(_ signed: JSONValue, personKey: SigningPublicKey, cert: DeviceCertificate.Identity?) throws -> Revocation {
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(signed).verify(kind: "revocation", label: Label.sigRevocation, key: personKey) }
        catch { throw Refusal.badSignature }
        guard o.hasExactly(["v", "suite", "kind", "person_id", "device_id", "revoked_ms", "reason"]) else { throw Refusal.badSignature }
        guard let person = o.id16("person_id"), person == Identifiers.personID(personKey),
              let reason = o["reason"]?.string, reasons.contains(reason),
              let revoked = o["revoked_ms"]?.int, let device = o.id16("device_id") else { throw Refusal.malformed }
        guard let cert, cert.personID == person, cert.deviceID == device else { throw Refusal.otherPerson }
        return Revocation(personID: person, deviceID: device, revokedMs: revoked, reason: reason)
    }
}

/// Questions and decisions (section 13).
public enum Decisions {
    /// `content_hash = H("orch/v2/question|" || cj({question_id, ticket, text, options}))` (32 bytes).
    public static func contentHash(of content: JSONValue) throws -> Data {
        Data(SHA256.hash(data: Data(Label.hQuestion.utf8) + (try canonicalJSON(content))))
    }

    /// `"orch/v2/sig/decision|" || cj({workspace_id, question_id, content_hash, decision_id, answer})`
    public static func signedBytes(workspace: ID16, questionID: ID16, contentHash: Data, decisionID: ID16,
                                   answer: JSONValue) throws -> Data {
        let body: JSONValue = ["workspace_id": .string(workspace.hex), "question_id": .string(questionID.hex),
                               "content_hash": .string(B64U.encode(contentHash)), "decision_id": .string(decisionID.hex),
                               "answer": answer]
        return Data(Label.sigDecision.utf8) + (try canonicalJSON(body))
    }

    /// The bridge op `{"op":"decision", ...}` with a detached device signature.
    public static func makeOp(workspace: ID16, questionID: ID16, contentHash: Data, decisionID: ID16, answer: JSONValue,
                              signer: some Signer) throws -> JSONValue {
        let bytes = try signedBytes(workspace: workspace, questionID: questionID, contentHash: contentHash,
                                    decisionID: decisionID, answer: answer)
        let sig = try signer.rawSignature(over: bytes)
        return ["op": "decision", "decision_id": .string(decisionID.hex), "question_id": .string(questionID.hex),
                "content_hash": .string(B64U.encode(contentHash)), "answer": answer, "sig": .string(B64U.encode(sig))]
    }

    /// Host side: field set -> `malformed`, then the signature with the sender's `dk_sig` -> `bad_signature`.
    public static func verifyOp(_ meta: JSONValue, workspace: ID16, deviceKey: SigningPublicKey) throws {
        guard let m = meta.object, m.hasExactly(["op", "decision_id", "question_id", "content_hash", "answer", "sig"]),
              m["op"] == "decision", let decisionID = m.id16("decision_id"), let questionID = m.id16("question_id"),
              let hash = m.b64u("content_hash", length: 32), let sig = m.b64u("sig", length: Suite2.signatureLength),
              let answer = m["answer"] else { throw Refusal.malformed }
        guard let bytes = try? signedBytes(workspace: workspace, questionID: questionID, contentHash: hash,
                                           decisionID: decisionID, answer: answer),
              Signature.verify(deviceKey, signature: sig, message: bytes) else { throw Refusal.badSignature }
    }
}
