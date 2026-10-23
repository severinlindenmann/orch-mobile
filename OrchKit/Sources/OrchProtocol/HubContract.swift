import CryptoKit
import Foundation

// The phone's side of the orch hub contract (orch-hub `docs/protocol.md` sections 2, 4.1, 5, 6.2 to 6.4). Pure functions, no I/O, no clock:
// every check takes `nowMs` and the verifier's dev mode explicitly. Reference implementation: orch-hub `orch_hub.contract.hub` and
// `.channelapi`; vectors: `vectors_hub.json` (replayed by `HubVectorTests`).

/// Whether this build is a dev verifier (V3: the app is a dev verifier from a compile-time flag, never from a link, a card or a reply).
/// A release build is a real verifier: it refuses every `dev: true` object and every loopback or plain-http link.
public enum HubBuild {
    #if DEBUG
    public static let isDev = true
    #else
    public static let isDev = false
    #endif
}

/// Identifiers and fingerprints of the hub contract (protocol 2.3, 6.4).
public enum HubIdentifiers {
    /// `hub_id = H("orch/v2/id/hub|" || suite || hk_root_pub)[0:16]`, lower-case hex.
    public static func hubID(root: SigningPublicKey) -> String {
        Hex.encode(Data(SHA256.hash(data: Data(Label.hHubID.utf8) + Bytes.u8(Suite2.id) + root.x963)).prefix(16))
    }

    /// `channel_id = H("orch/v2/id/channel|" || suite || channel_key_pub)[0:16]`, lower-case hex.
    public static func channelID(key: SigningPublicKey) -> String {
        Hex.encode(Data(SHA256.hash(data: Data(Label.hHubChannelID.utf8) + Bytes.u8(Suite2.id) + key.x963)).prefix(16))
    }

    /// What the person compares with the admin console: the hub id in 8 groups of 4 (protocol 6.4).
    public static func fingerprint(hubID: String) -> String? {
        guard Hex.decode(hubID, length: 16) != nil else { return nil }
        let u = Array(hubID)
        return stride(from: 0, to: 32, by: 4).map { String(u[$0..<$0 + 4]) }.joined(separator: " ")
    }

    /// `b64u(H("orch/v2/hub-session-ref|" || token))`: names a pairing session inside `hub.channel_auth` without the token itself.
    public static func sessionRef(token: String) throws -> String {
        let t = Data(token.utf8)
        guard !t.isEmpty, t.count <= 256, t.allSatisfy({ $0 < 0x80 }) else { throw Refusal.malformed }
        return B64U.encode(Data(SHA256.hash(data: Data(Label.hHubSessionRef.utf8) + t)))
    }
}

/// A parsed pairing link (protocol 6.4): `orch://hub-pair/<authority>#h1.<hub_id>.<user_id>.<code>`. `hubID` is the phone's pin.
/// The pairing code is a secret: it never appears in a description, a mirror or a log.
public struct HubPairLink: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// `https://<authority>`, or plain `http://<authority>` for a loopback host (dev build only).
    public let api: String
    public let hubID: String
    public let userID: String
    package let code: String

    public var description: String { "HubPairLink(api: \(api), hub: \(hubID), <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["api": api, "hubID": hubID], displayStyle: .struct) }

    static let prefix = "orch://hub-pair/"
    static let maxBytes = 512
    static let loopback: Set<String> = ["localhost", "127.0.0.1", "[::1]"]

    /// Strict (every deviation is `malformed`): ASCII, at most 512 bytes, lower-case host, port 1 to 65535 without a leading zero, no
    /// userinfo, path, query or second `#`, exactly `h1` and lower-case hex. A loopback host (plain http) only when `devMode`.
    package static func parse(_ text: String, devMode: Bool) throws -> HubPairLink {
        let u = Array(text.utf8)
        guard u.count <= maxBytes, u.allSatisfy({ $0 < 0x80 }), text.utf8.starts(with: prefix.utf8) else { throw Refusal.malformed }
        let rest = Array(u.dropFirst(prefix.utf8.count))
        guard let hash = rest.firstIndex(of: 0x23) else { throw Refusal.malformed }
        let authority = String(decoding: rest[..<hash], as: UTF8.self)
        let fragment = String(decoding: rest[(hash + 1)...], as: UTF8.self)
        guard let host = parseAuthority(authority), let frag = parseFragment(fragment) else { throw Refusal.malformed }
        let isLoopback = loopback.contains(host)
        if isLoopback && !devMode { throw Refusal.malformed }
        return HubPairLink(api: (isLoopback ? "http://" : "https://") + authority, hubID: frag.hub, userID: frag.user, code: frag.code)
    }

    /// The host of a valid authority (`host[:port]`), or nil. `[::1]` needs a port.
    static func parseAuthority(_ a: String) -> String? {
        let parts = a.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var host: String, port: String?
        if a.hasPrefix("[") {
            guard a.hasPrefix("[::1]:") else { return nil }
            host = "[::1]"; port = String(a.dropFirst(6))
        } else {
            guard parts.count <= 2 else { return nil }
            host = parts[0]; port = parts.count == 2 ? parts[1] : nil
            guard validHost(host) else { return nil }
        }
        if let p = port {
            let d = Array(p.utf8)
            guard (1...5).contains(d.count), d[0] != 0x30, d.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int(p), n >= 1, n <= 65535
            else { return nil }
        }
        return host
    }

    /// Dot-separated labels `[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?`: lower case, no empty label (so no trailing dot), ASCII only.
    static func validHost(_ h: String) -> Bool {
        let labels = h.utf8.split(separator: 0x2E, omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        func alnum(_ c: UInt8) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) }
        return labels.allSatisfy { l in
            guard (1...63).contains(l.count), let f = l.first, let e = l.last, alnum(f), alnum(e) else { return false }
            return l.allSatisfy { alnum($0) || $0 == 0x2D }
        }
    }

    static func parseFragment(_ f: String) -> (hub: String, user: String, code: String)? {
        let p = f.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 4, p[0] == "h1", Hex.decode(p[1], length: 16) != nil, Hex.decode(p[2], length: 16) != nil else { return nil }
        let c = p[3].split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard c.count == 3, c.allSatisfy({ $0.utf8.count == 4 && Hex.decode($0, length: 2) != nil }) else { return nil }
        return (p[1], p[2], p[3])
    }
}

/// A hub card this verifier has verified and holds (protocol 5). Persist `signed` and re-verify it on load; never trust a stored copy.
public struct HeldHubCard: Sendable, Equatable {
    public let hubID: String
    public let hkRootPub: SigningPublicKey
    package let hkOpPub: SigningPublicKey
    public let opCertID: String
    public let opSeq: Int64
    public let cardSeq: Int64
    public let relayURL: String?
    /// The card as received, `{o, op_cert, sig}`.
    public let signed: JSONValue
}

/// A verified `hub.channel_cert` (protocol 6.2).
public struct HubChannelCert: Sendable, Equatable {
    public let hubID: String
    public let channelID: String
    public let userID: String
    public let keyPub: SigningPublicKey
    public let factor: String
    public let issuedMs: Int64
    public let expiresMs: Int64
    public let opCertID: String
    public let signed: JSONValue
}

/// The `hub.channel_register` challenge the hub opened for this phone, after the phone checked every field against what it expects.
/// Only `HubVerifier.checkRegistrationChallenge` makes one, so `HubChannelSigner.register` can sign nothing else.
public struct HubRegistrationChallenge: Sendable, Equatable {
    package let object: [String: JSONValue]
    public let userID: String
    public let keyPub: SigningPublicKey
    public let expiresMs: Int64
    package init(object: [String: JSONValue], userID: String, keyPub: SigningPublicKey, expiresMs: Int64) {
        self.object = object; self.userID = userID; self.keyPub = keyPub; self.expiresMs = expiresMs
    }
}

/// The verifier of the hub contract: real in a release build, dev in a debug build. The mode is fixed at compile time
/// (`HubBuild.isDev`); only package-internal callers (tests) choose it.
public struct HubVerifier: Sendable {
    public let devMode: Bool
    public static let clockSkewMs: Int64 = 300_000
    public static let challengeTTLMs: Int64 = 120_000

    public init() { devMode = HubBuild.isDev }
    package init(devMode: Bool) { self.devMode = devMode }

    public func parseLink(_ text: String) throws -> HubPairLink { try HubPairLink.parse(text, devMode: devMode) }

    // MARK: generic signed objects (protocol 2.2)

    typealias Obj = [String: JSONValue]
    typealias Check = @Sendable (JSONValue) -> Bool

    static let header: Set<String> = ["v", "suite", "kind", "hv"]

    /// Envelope and header: exactly `{o, sig}` plus `extra`; `kind` (`malformed`), `suite` (`wrong_suite`), `v` and `hv` (`malformed`);
    /// the whole value must be canonicalisable.
    static func envelope(_ signed: JSONValue, kind: String, extra: Set<String> = []) throws -> Obj {
        guard let m = signed.object, m.hasExactly(Set(["o", "sig"]).union(extra)), let o = m["o"]?.object, o.allKeysASCII,
              o["kind"] == .string(kind) else { throw Refusal.malformed }
        guard o["suite"] == .int(Int64(Suite2.id)) else { throw Refusal.wrongSuite }
        guard o["v"] == .int(2), o["hv"] == .int(0), (try? canonicalJSON(signed)) != nil else { throw Refusal.malformed }
        return o
    }

    static func checkSignature(_ signed: JSONValue, label: String, key: SigningPublicKey) throws {
        guard let o = signed.object?["o"], let s = signed.object?["sig"]?.string, let sig = B64U.decode(s, length: Suite2.signatureLength),
              let msg = try? canonicalJSON(o) else { throw Refusal.malformed }
        guard Signature.verify(key, signature: sig, label: label, message: msg) else { throw Refusal.badSignature }
    }

    static func checkFields(_ o: Obj, _ spec: [String: Check]) throws {
        guard Set(o.keys) == header.union(spec.keys) else { throw Refusal.malformed }
        for (k, ok) in spec where !ok(o[k] ?? .null) { throw Refusal.malformed }
    }

    static let hex16: Check = { $0.string.flatMap { Hex.decode($0, length: 16) } != nil }
    static let pub: Check = { $0.string.flatMap { B64U.decode($0, length: 65) }.flatMap { try? SigningPublicKey(x963: $0) } != nil }
    static let agreementPub: Check = { $0.string.flatMap { B64U.decode($0, length: 65) }.flatMap { try? AgreementPublicKey(x963: $0) } != nil }
    static let b64u32: Check = { $0.string.flatMap { B64U.decode($0, length: 32) } != nil }
    static func intMin(_ lo: Int64) -> Check { { ($0.int ?? Int64.min) >= lo } }
    static let bool: Check = { $0.bool != nil }
    static func oneOf(_ vals: String...) -> Check { { v in v.string.map { s in vals.contains { $0.bytesEqual(s) } } ?? false } }
    /// `https://<host>[:port]`, or plain `http://` for a loopback host (protocol 6.4 `origin`, 5 `relay_url`).
    static func isHubURL(_ s: String) -> Bool {
        guard s.utf8.allSatisfy({ $0 >= 0x21 && $0 < 0x7F }) else { return false }
        func digits(_ p: Substring) -> Bool { (1...5).contains(p.utf8.count) && p.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
        /// Splits `host[:port]`; `[::1]` keeps its brackets.
        func split(_ r: Substring) -> (host: Substring, ok: Bool) {
            if r.hasPrefix("[::1]") {
                let tail = r.dropFirst(5)
                return ("[::1]", tail.isEmpty || (tail.hasPrefix(":") && digits(tail.dropFirst())))
            }
            let p = r.split(separator: ":", omittingEmptySubsequences: false)
            return (p[0], p.count == 1 || (p.count == 2 && digits(p[1])))
        }
        if s.hasPrefix("https://") {
            let (h, ok) = split(Substring(s.dropFirst(8)))
            return ok && (1...253).contains(h.utf8.count)
                && h.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2D }
        }
        if s.hasPrefix("http://") {
            let (h, ok) = split(Substring(s.dropFirst(7)))
            return ok && ["localhost", "127.0.0.1", "[::1]"].contains(String(h))
        }
        return false
    }

    func checkDev(_ o: Obj) throws {
        if o["dev"] == .bool(true) && !devMode { throw Refusal.devRefused }
        if o["dev"] == .bool(false) && devMode { throw Refusal.devMismatch }
    }

    static func certTime(_ o: Obj, nowMs: Int64, issued: String = "issued_ms") throws {
        guard let iss = o[issued]?.int, let exp = o["expires_ms"]?.int else { throw Refusal.malformed }
        if exp <= iss || iss > saturatingAdd(nowMs, clockSkewMs) { throw Refusal.certInvalid }
        if nowMs >= exp { throw Refusal.certExpired }
    }

    // MARK: op certificate and card (protocol 4.1, 5)

    func verifyOpCert(_ signed: JSONValue, root: SigningPublicKey, nowMs: Int64, revoked: Set<String>) throws -> Obj {
        let o = try Self.envelope(signed, kind: "hub.op_cert")
        try Self.checkSignature(signed, label: Label.sigHubOpCert, key: root)
        try Self.checkFields(o, ["hub_id": Self.hex16, "cert_id": Self.hex16, "op_seq": Self.intMin(1), "hk_op_pub": Self.pub,
                                 "issued_ms": Self.intMin(0), "expires_ms": Self.intMin(1), "dev": Self.bool])
        guard o["hub_id"]?.string == HubIdentifiers.hubID(root: root) else { throw Refusal.otherHub }
        try checkDev(o)
        try Self.certTime(o, nowMs: nowMs)
        if let id = o["cert_id"]?.string, revoked.contains(id) { throw Refusal.revoked }
        return o
    }

    /// Protocol 5 steps 1 to 6 (and 7 against `held`). `pinnedRoot` is the pin (the link's `hub_id` has been checked against the root by
    /// the caller through `checkPin`); with a pin, another root is `other_hub` before anything else about the card is read.
    public func verifyCard(_ card: JSONValue, nowMs: Int64, pinnedRoot: SigningPublicKey? = nil, revokedOpCerts: Set<String> = [],
                           held: HeldHubCard? = nil) throws -> HeldHubCard {
        let o = try Self.envelope(card, kind: "hub.card", extra: ["op_cert"])
        guard let rootText = o["hk_root_pub"]?.string, let rootBytes = B64U.decode(rootText, length: Suite2.publicKeyLength),
              let root = try? SigningPublicKey(x963: rootBytes) else { throw Refusal.malformed }
        if let pinnedRoot, pinnedRoot != root { throw Refusal.otherHub }
        guard o["hub_id"]?.string == HubIdentifiers.hubID(root: root) else { throw Refusal.hubIDMismatch }
        guard let opCertJSON = card.object?["op_cert"] else { throw Refusal.malformed }
        let op = try verifyOpCert(opCertJSON, root: root, nowMs: nowMs, revoked: revokedOpCerts)
        guard let opText = op["hk_op_pub"]?.string, let opBytes = B64U.decode(opText, length: Suite2.publicKeyLength),
              let hkOp = try? SigningPublicKey(x963: opBytes) else { throw Refusal.malformed }
        try Self.checkSignature(card, label: Label.sigHubCard, key: hkOp)
        try Self.checkFields(o, ["hub_id": Self.hex16, "hk_root_pub": Self.pub, "hxk_pub": Self.agreementPub,
                                 "relay_url": { $0.isNull || ($0.string.map(Self.isHubURL) ?? false) }, "tls_spki_sha256": Self.b64u32,
                                 "card_seq": Self.intMin(1), "issued_ms": Self.intMin(0), "dev": Self.bool])
        try checkDev(o)
        guard let issued = o["issued_ms"]?.int, let cardSeq = o["card_seq"]?.int, let opSeq = op["op_seq"]?.int,
              let certID = op["cert_id"]?.string, let hubID = o["hub_id"]?.string else { throw Refusal.malformed }
        if issued > saturatingAdd(nowMs, Self.clockSkewMs) { throw Refusal.certInvalid }
        if let held {
            if root != held.hkRootPub { throw Refusal.otherHub }
            if opSeq < held.opSeq || (opSeq == held.opSeq && certID != held.opCertID) { throw Refusal.staleOpCert }
            if opSeq == held.opSeq {
                if cardSeq < held.cardSeq { throw Refusal.staleCard }
                if cardSeq == held.cardSeq, (try? canonicalJSON(card)) != (try? canonicalJSON(held.signed)) { throw Refusal.staleCard }
            }
        }
        return HeldHubCard(hubID: hubID, hkRootPub: root, hkOpPub: hkOp, opCertID: certID, opSeq: opSeq, cardSeq: cardSeq,
                           relayURL: o["relay_url"]?.string, signed: card)
    }

    /// Objects signed by `HK_op` under the held card (protocol 6.1 rules): revoked, envelope, signature, fields, `hub_id`, `op_cert_id`, dev.
    func underCard(_ signed: JSONValue, kind: String, label: String, fields: [String: Check], held: HeldHubCard, revoked: Set<String>) throws -> Obj {
        if revoked.contains(held.opCertID) { throw Refusal.revoked }
        let o = try Self.envelope(signed, kind: kind)
        try Self.checkSignature(signed, label: label, key: held.hkOpPub)
        try Self.checkFields(o, fields)
        guard o["hub_id"]?.string == held.hubID else { throw Refusal.otherHub }
        guard o["op_cert_id"]?.string == held.opCertID else { throw Refusal.staleOpCert }
        try checkDev(o)
        return o
    }

    /// The hub's signed API origin (protocol 6.4, L2B-1): verified under the pinned card BEFORE any password is sent; `origin` must be
    /// exactly the link's API origin, else `other_origin` (a phishing host can relay the object, but it names the real origin).
    public func verifyAPIOrigin(_ signed: JSONValue, held: HeldHubCard, linkAPI: String, nowMs: Int64,
                                revokedOpCerts: Set<String> = []) throws -> String {
        let o = try underCard(signed, kind: "hub.api_origin", label: Label.sigHubAPIOrigin,
                              fields: ["hub_id": Self.hex16, "op_cert_id": Self.hex16,
                                       "origin": { $0.string.map(Self.isHubURL) ?? false }, "issued_ms": Self.intMin(0), "dev": Self.bool],
                              held: held, revoked: revokedOpCerts)
        guard let iss = o["issued_ms"]?.int, let origin = o["origin"]?.string else { throw Refusal.malformed }
        if iss > saturatingAdd(nowMs, Self.clockSkewMs) { throw Refusal.certInvalid }
        if origin.hasPrefix("http://") && !devMode { throw Refusal.malformed }
        guard origin.bytesEqual(linkAPI) else { throw Refusal.otherOrigin }
        return origin
    }

    /// Protocol 6.2: under the held card, `channel_id` of `key_pub`, times.
    public func verifyChannelCert(_ signed: JSONValue, held: HeldHubCard, nowMs: Int64, revokedOpCerts: Set<String> = []) throws -> HubChannelCert {
        let o = try underCard(signed, kind: "hub.channel_cert", label: Label.sigHubChannelCert,
                              fields: ["hub_id": Self.hex16, "op_cert_id": Self.hex16, "channel_id": Self.hex16, "user_id": Self.hex16,
                                       "key_pub": Self.pub, "factor": Self.oneOf("se-unlocked", "passkey", "password+totp"),
                                       "issued_ms": Self.intMin(0), "expires_ms": Self.intMin(1), "dev": Self.bool],
                              held: held, revoked: revokedOpCerts)
        guard let kp = o["key_pub"]?.string.flatMap({ B64U.decode($0, length: 65) }), let key = try? SigningPublicKey(x963: kp),
              let cid = o["channel_id"]?.string, let uid = o["user_id"]?.string, let factor = o["factor"]?.string,
              let iss = o["issued_ms"]?.int, let exp = o["expires_ms"]?.int else { throw Refusal.malformed }
        guard cid == HubIdentifiers.channelID(key: key) else { throw Refusal.certInvalid }
        try Self.certTime(o, nowMs: nowMs)
        return HubChannelCert(hubID: held.hubID, channelID: cid, userID: uid, keyPub: key, factor: factor, issuedMs: iss, expiresMs: exp,
                              opCertID: held.opCertID, signed: signed)
    }

    // MARK: registration (protocol 6.3, design B1 step 5)

    /// The phone's check of the challenge `register/begin` returned, BEFORE it signs anything: it is the exact `hub.channel_register` object
    /// for this hub (the pin), the signed-in user, kind `phone` and gate `pairing-code`, our own key, the answer's `challenge_id` as nonce,
    /// valid for at most 120 s (plus skew) and not yet expired, and carries this build's dev marker. The hub's wording is never signed.
    public func checkRegistrationChallenge(_ challenge: JSONValue, challengeID: String, hubID: String, userID: String, ownKey: SigningPublicKey,
                                           nowMs: Int64) throws -> HubRegistrationChallenge {
        guard let o = challenge.object, o.allKeysASCII, (try? canonicalJSON(challenge)) != nil else { throw Refusal.malformed }
        try Self.checkFields(o, ["hub_id": Self.hex16, "user_id": Self.hex16, "channel_kind": Self.oneOf("phone", "browser"), "key_pub": Self.pub,
                                 "attestation": Self.oneOf("pairing-code", "session"), "nonce": Self.b64u32, "expires_ms": Self.intMin(1),
                                 "dev": Self.bool])
        guard o["kind"] == "hub.channel_register", o["suite"] == .int(Int64(Suite2.id)), o["v"] == .int(2), o["hv"] == .int(0)
        else { throw Refusal.malformed }
        guard o["hub_id"]?.string == hubID else { throw Refusal.otherHub }
        guard let uid = o["user_id"]?.string, uid == userID else { throw Refusal.otherUser }
        guard o["channel_kind"] == "phone", o["attestation"] == "pairing-code" else { throw Refusal.factorMismatch }
        guard o["key_pub"]?.string == B64U.encode(ownKey.x963), o["nonce"]?.string == challengeID, let exp = o["expires_ms"]?.int
        else { throw Refusal.challengeInvalid }
        guard exp > nowMs, exp <= saturatingAdd(saturatingAdd(nowMs, Self.challengeTTLMs), Self.clockSkewMs) else { throw Refusal.challengeInvalid }
        try checkDev(o)
        return HubRegistrationChallenge(object: o, userID: uid, keyPub: ownKey, expiresMs: exp)
    }
}
