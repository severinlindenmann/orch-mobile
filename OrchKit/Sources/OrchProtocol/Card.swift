import CryptoKit
import Foundation

/// `https://<lower-case host>[:port]` with no path and no trailing slash; for development only `http://localhost`,
/// `http://127.0.0.1` or `http://[::1]` with an optional port (section 7.1). Byte-exact, same shape as the reference's
/// regular expression.
public enum RelayURL {
    public static func isValid(_ s: String) -> Bool {
        let u = Array(s.utf8)
        func isHostChar(_ c: UInt8) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) }
        func validPort(_ p: ArraySlice<UInt8>) -> Bool {
            guard p.count >= 1, p.count <= 5, p.first != 0x30, p.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return false }
            return Int(String(decoding: p, as: UTF8.self))! <= 65535
        }
        func splitPort(_ rest: ArraySlice<UInt8>) -> (host: ArraySlice<UInt8>, port: ArraySlice<UInt8>?)? {
            if rest.first == UInt8(ascii: "[") {            // only [::1]
                guard let close = rest.firstIndex(of: UInt8(ascii: "]")) else { return nil }
                let host = rest[rest.startIndex...close], after = rest[(close + 1)...]
                if after.isEmpty { return (host, nil) }
                guard after.first == UInt8(ascii: ":") else { return nil }
                return (host, after.dropFirst())
            }
            if let colon = rest.firstIndex(of: UInt8(ascii: ":")) { return (rest[rest.startIndex..<colon], rest[(colon + 1)...]) }
            return (rest, nil)
        }
        let https = Array("https://".utf8), http = Array("http://".utf8)
        if u.starts(with: https) {
            guard let (host, port) = splitPort(u[https.count...]), !host.isEmpty, host.first != UInt8(ascii: "[") else { return false }
            guard isHostChar(host.first!), isHostChar(host.last!),
                  host.allSatisfy({ isHostChar($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }) else { return false }
            // no empty labels; and, by the WHATWG "ends in a number" rule, the LAST label must not be all digits or a 0x hex
            // number (2130706433, 0x7f000001, 1.2.3.4, 127.1, 0177.0.0.1 are IPv4 spellings). Other labels may look numeric
            // (123.example.com is a DNS name). Punycode (xn--) labels are accepted; a UI shows the ASCII host, never IDN-decoded.
            let labels = host.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
            if labels.contains(where: { $0.isEmpty }) { return false }
            let last = labels[labels.count - 1]
            if last.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) { return false }
            if last.starts(with: Array("0x".utf8)), last.dropFirst(2).allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) { return false }
            return port.map(validPort) ?? true
        }
        if u.starts(with: http) {
            guard let (host, port) = splitPort(u[http.count...]) else { return false }
            let allowed = ["localhost", "127.0.0.1", "[::1]"].map { Array($0.utf8) }
            guard allowed.contains(where: { Array(host) == $0 }) else { return false }
            return port.map(validPort) ?? true
        }
        return false
    }
}

/// The one-time workspace delegation, signed by the owner's `PK` (section 7.1). It never changes.
public struct WorkspaceDelegation: Equatable, Sendable {
    public let workspace: ID16
    public let wsk: SigningPublicKey
    public let ownerPersonID: ID16
    public let clientHosted: Bool
    public let issuedMs: Int64
    /// The signed object, kept for byte-exact comparison (`delegation_changed`).
    public let object: [String: JSONValue]

    static let fields: Set<String> = ["v", "suite", "kind", "workspace_id", "wsk_pub", "owner_person_id", "client_hosted", "issued_ms"]

    /// `bad_signature` (bad signature), `malformed` (v/suite/kind or field set), `other_person` (owner is not the key's).
    public static func verify(_ signed: JSONValue, ownerKey: SigningPublicKey) throws -> WorkspaceDelegation {
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(signed).verify(kind: .wsDelegation, key: ownerKey) }
        catch let r as Refusal where r == .badSignature { throw r }
        catch { throw Refusal.badSignature }
        guard o.hasExactly(fields), let ws = o.id16("workspace_id"),
              let wsk = o.b64u("wsk_pub", length: Suite2.publicKeyLength).flatMap({ try? SigningPublicKey(x963: $0) }),
              let owner = o.id16("owner_person_id"), let hosted = o["client_hosted"]?.bool, let issued = o["issued_ms"]?.int
        else { throw Refusal.malformed }
        guard owner == Identifiers.personID(ownerKey) else { throw Refusal.otherPerson }
        return WorkspaceDelegation(workspace: ws, wsk: wsk, ownerPersonID: owner, clientHosted: hosted, issuedMs: issued, object: o)
    }

    package static func sign(workspace: ID16, wsk: SigningPublicKey, clientHosted: Bool, issuedMs: Int64, owner: some Signer) throws -> SignedObject {
        try SignedObject.sign(["v": 2, "suite": 2, "kind": "ws_delegation", "workspace_id": .string(workspace.hex),
                               "wsk_pub": .string(B64U.encode(wsk.x963)), "owner_person_id": .string(Identifiers.personID(owner.publicKey).hex),
                               "client_hosted": .bool(clientHosted), "issued_ms": .int(issuedMs)],
                              kind: .wsDelegation, signer: owner)
    }
}

/// A card that passed every check of section 7.1 (delegation, card signature, `sealed_hash`). The sealed part is still
/// closed: open it with `Card.openSealedPart` after unwrapping `CK`.
public struct VerifiedCard: Equatable, Sendable {
    public let delegation: WorkspaceDelegation
    public let workspace: ID16
    public let wsk: SigningPublicKey
    public let wxk: AgreementPublicKey
    public let wxkVersion: UInt32
    public let ownerPersonID: ID16
    public let relayURL: String
    public let cardSeq: UInt32
    public let issuedMs: Int64
    public let sealedHash: Data
    public let ckCommit: Data
    public let sealed: Data
    /// The signed `o`.
    public let object: [String: JSONValue]

    /// `H(cj(o))`, computed once at verification; a card whose object cannot be canonicalised is refused there (fail closed).
    public let objectDigest: Data
    /// `H(cj(o))`, or nil when `o` cannot be canonicalised (callers refuse).
    public static func digest(_ o: [String: JSONValue]) -> Data? { (try? canonicalJSON(.object(o))).map { Data(SHA256.hash(data: $0)) } }

    /// What a phone or relay keeps to judge the next card against.
    public var head: Card.Head {
        Card.Head(workspace: workspace, ownerPersonID: ownerPersonID, wsk: wsk, wxk: wxk, wxkVersion: wxkVersion, cardSeq: cardSeq,
                  delegationObject: delegation.object, objectDigest: objectDigest)
    }
}

/// The card's sealed part: `{name, description, capabilities, hosted_by}` (exactly these).
public struct CardSealedPart: Equatable, Sendable {
    public let name: String
    public let description: String
    public let capabilities: [String]
    public let hostedBy: String?
    public init(name: String, description: String, capabilities: [String], hostedBy: String?) {
        self.name = name; self.description = description; self.capabilities = capabilities; self.hostedBy = hostedBy
    }
    var json: JSONValue {
        ["name": .string(name), "description": .string(description), "capabilities": .array(capabilities.map { .string($0) }),
         "hosted_by": hostedBy.map { .string($0) } ?? .null]
    }
}

/// What a reader shows about who runs the workspace (section 7.1, "Showing the marker").
public struct HostedMarker: Equatable, Sendable {
    public let marker: Bool
    public let hostedBy: String?

    public static let unknownName = "(unknown)"

    /// The `PK`-signed `client_hosted` flag decides whether the marker is shown; the sealed `hosted_by` only supplies the
    /// name. A host can only add the warning, never remove it: a name without the flag still shows the marker.
    public static func decide(delegationClientHosted: Bool, hostedBy: String?) -> HostedMarker {
        guard delegationClientHosted || hostedBy != nil else { return HostedMarker(marker: false, hostedBy: nil) }
        if let n = hostedBy, !n.isEmpty { return HostedMarker(marker: true, hostedBy: n) }
        return HostedMarker(marker: true, hostedBy: unknownName)
    }
}

public enum Card {
    static let fields: Set<String> = ["v", "suite", "kind", "workspace_id", "wsk_pub", "wxk_pub", "wxk_version", "owner_person_id",
                                      "relay_url", "card_seq", "issued_ms", "sealed_hash", "ck_commit"]
    public static let maxSealedBytes = 64 * 1024

    /// `H("orch/v2/card-key-commit|" || workspace_id || u32(card_seq) || CK)`
    public static func ckCommit(workspace: ID16, cardSeq: UInt32, ck: SymmetricKey) -> Data {
        Data(SHA256.hash(data: Data(Label.hCardKeyCommit.utf8) + workspace.bytes + Bytes.u32(cardSeq) + ck.rawBytes))
    }

    static func sealedAAD(workspace: ID16, cardSeq: UInt32) -> Data {
        Data(Label.aadCard.utf8) + Bytes.u8(Suite2.id) + workspace.bytes + Bytes.u32(cardSeq)
    }

    /// Section 7.1, what the relay, orch-publish, a peer and the phone check, in order: shape, suite, keys, URL, integers,
    /// `other_person`, the delegation (`bad_signature`/`malformed`/`other_person`), `delegation_mismatch`, the card
    /// signature and `sealed_hash` (`bad_signature`).
    public static func verify(_ card: JSONValue, ownerKey: SigningPublicKey) throws -> VerifiedCard {
        guard let m = card.object, m.hasExactly(["delegation", "o", "sig", "sealed"]), let o = m["o"]?.object, o.allKeysASCII,
              o.hasExactly(fields), o["v"] == .int(2), o["kind"] == .string("card") else { throw Refusal.malformed }
        guard o["suite"] == .int(Int64(Suite2.id)) else {
            throw o["suite"]?.int != nil ? Refusal.wrongSuite : Refusal.malformed
        }
        guard let ws = o.id16("workspace_id"),
              let wsk = o.b64u("wsk_pub", length: Suite2.publicKeyLength).flatMap({ try? SigningPublicKey(x963: $0) }),
              let wxk = o.b64u("wxk_pub", length: Suite2.publicKeyLength).flatMap({ try? AgreementPublicKey(x963: $0) }),
              let url = o["relay_url"]?.string, RelayURL.isValid(url),
              let wxkVersion = o.positiveU32("wxk_version"), let seq = o.positiveU32("card_seq"),
              let issued = o["issued_ms"]?.int, issued >= 0,
              let commit = o.b64u("ck_commit", length: 32), let sealedHash = o.b64u("sealed_hash", length: 32),
              let sealedText = m["sealed"]?.string, let sealed = B64U.decode(sealedText), sealed.count <= maxSealedBytes,
              let ownerID = o.id16("owner_person_id"), let sigText = m["sig"]?.string,
              let sig = B64U.decode(sigText, length: Suite2.signatureLength)
        else { throw Refusal.malformed }
        guard ownerID == Identifiers.personID(ownerKey) else { throw Refusal.otherPerson }
        let d = try WorkspaceDelegation.verify(m["delegation"] ?? .null, ownerKey: ownerKey)
        guard d.workspace == ws, d.wsk == wsk, d.ownerPersonID == ownerID else { throw Refusal.delegationMismatch }
        _ = try SignedObject(object: o, signature: sig).verify(kind: .card, key: wsk)
        guard sealedHash == Data(SHA256.hash(data: sealed)) else { throw Refusal.badSignature }
        return VerifiedCard(delegation: d, workspace: ws, wsk: wsk, wxk: wxk, wxkVersion: wxkVersion, ownerPersonID: ownerID,
                            relayURL: url, cardSeq: seq, issuedMs: issued, sealedHash: sealedHash, ckCommit: commit, sealed: sealed, object: o,
                            objectDigest: try VerifiedCard.digest(o) ?? { throw Refusal.malformed }())
    }

    /// Update rules (section 7.1), for the relay and for the phone ("never accept a lower card sequence"). `previous` is
    /// the last accepted card, or nil for the first.
    public struct Head: Equatable, Sendable {
        public let workspace: ID16, ownerPersonID: ID16
        public let wsk: SigningPublicKey
        public let wxk: AgreementPublicKey
        public let wxkVersion: UInt32, cardSeq: UInt32
        public let delegationObject: [String: JSONValue]
        /// `H(cj(o))` of the accepted card: a same-sequence card with other content is a conflict.
        public let objectDigest: Data
        public init(workspace: ID16, ownerPersonID: ID16, wsk: SigningPublicKey, wxk: AgreementPublicKey, wxkVersion: UInt32,
                    cardSeq: UInt32, delegationObject: [String: JSONValue], objectDigest: Data) {
            self.objectDigest = objectDigest
            self.workspace = workspace; self.ownerPersonID = ownerPersonID; self.wsk = wsk; self.wxk = wxk
            self.wxkVersion = wxkVersion; self.cardSeq = cardSeq; self.delegationObject = delegationObject
        }
    }

    /// Relay publication rules (section 7.1 "Update rules"): strictly increasing `card_seq`, `wxk_version` rising by exactly 1
    /// with a different key. Not for a phone: a phone reconnecting sees the same card again and may have missed rotations;
    /// it uses `checkSnapshot`.
    public static func checkRelayUpdate(previous: Head?, next: VerifiedCard) throws {
        guard let p = previous else { return }
        guard next.workspace == p.workspace, next.ownerPersonID == p.ownerPersonID else { throw Refusal.otherWorkspace }
        guard next.wsk == p.wsk else { throw Refusal.wskChanged }
        guard let a = try? canonicalJSON(.object(next.delegation.object)), let b = try? canonicalJSON(.object(p.delegationObject)),
              a == b else { throw Refusal.delegationChanged }
        // P3-D4: the same verified card (same canonical object, so the same `sealed_hash` and `ck_commit`) is an idempotent retry;
        // other content under the same sequence stays `stale_card`.
        if next.objectDigest == p.objectDigest { return }
        guard next.cardSeq > p.cardSeq else { throw Refusal.staleCard }
        if next.wxkVersion == p.wxkVersion {
            guard next.wxk == p.wxk else { throw Refusal.wxkChangedWithoutVersion }
        } else if next.wxkVersion != p.wxkVersion &+ 1 || next.wxk == p.wxk || p.wxkVersion == UInt32.max {
            throw Refusal.badWxkVersion
        }
    }

    /// What a device does with a card it fetched, given the last card it accepted (`known`, nil on first contact or late join).
    /// It keeps the identity pins (workspace, owner, `WSK`, delegation byte for byte), accepts the identical card again
    /// (reconnect) and any forward jump (missed rotations), and refuses rollback and conflicting content under one sequence.
    /// `WXK` must change exactly when `wxk_version` rises, never fall back.
    public static func checkSnapshot(known: Head?, next: VerifiedCard) throws {
        guard let k = known else { return }
        guard next.workspace == k.workspace, next.ownerPersonID == k.ownerPersonID else { throw Refusal.otherWorkspace }
        guard next.wsk == k.wsk else { throw Refusal.wskChanged }
        guard let a = try? canonicalJSON(.object(next.delegation.object)), let b = try? canonicalJSON(.object(k.delegationObject)),
              a == b else { throw Refusal.delegationChanged }
        if next.cardSeq < k.cardSeq { throw Refusal.staleCard }
        if next.cardSeq == k.cardSeq {
            guard next.objectDigest == k.objectDigest else { throw Refusal.conflictingSnapshot }
            return
        }
        if next.wxkVersion < k.wxkVersion { throw Refusal.badWxkVersion }
        if next.wxkVersion == k.wxkVersion {
            guard next.wxk == k.wxk else { throw Refusal.wxkChangedWithoutVersion }
        } else if next.wxk == k.wxk {
            throw Refusal.badWxkVersion
        }
    }

    /// Checks `CK` against the signed `ck_commit` (constant time), then opens and strictly parses the sealed part.
    /// A wrong key fails here and never falls back to a plaintext name.
    public static func openSealedPart(of card: VerifiedCard, ck: SymmetricKey) throws -> CardSealedPart {
        let want = ckCommit(workspace: card.workspace, cardSeq: card.cardSeq, ck: ck)
        var diff: UInt8 = 0
        for (x, y) in zip(want, card.ckCommit) { diff |= x ^ y }
        guard diff == 0, want.count == card.ckCommit.count else { throw CryptoFailure.authenticationFailed }
        let key = KDF.kCard(ck: ck, workspace: card.workspace, cardSeq: card.cardSeq)
        let pt = try ZeroNonceGCM.open(key: key, blob: card.sealed, aad: sealedAAD(workspace: card.workspace, cardSeq: card.cardSeq))
        guard let v = try? StrictJSON.parse(pt, maxBytes: maxSealedBytes), let o = v.object,
              o.hasExactly(["name", "description", "capabilities", "hosted_by"]),
              let name = o["name"]?.string, let desc = o["description"]?.string, let caps = o["capabilities"]?.array,
              let hosted = o["hosted_by"], hosted.isNull || hosted.string != nil
        else { throw Refusal.malformed }
        let capStrings = caps.compactMap(\.string)
        guard capStrings.count == caps.count else { throw Refusal.malformed }
        return CardSealedPart(name: name, description: desc, capabilities: capStrings, hostedBy: hosted.string)
    }

    /// The hosted marker for a verified card and its opened sealed part.
    public static func hostedMarker(card: VerifiedCard, sealedPart: CardSealedPart) -> HostedMarker {
        HostedMarker.decide(delegationClientHosted: card.delegation.clientHosted, hostedBy: sealedPart.hostedBy)
    }

    // MARK: host side (package)

    /// `AES-256-GCM(HKDF(CK, "", "orch/v2/card|ws|seq"), zero nonce, cj(part), aad)`
    package static func sealPart(_ part: CardSealedPart, ck: SymmetricKey, workspace: ID16, cardSeq: UInt32) throws -> Data {
        try ZeroNonceGCM.seal(key: KDF.kCard(ck: ck, workspace: workspace, cardSeq: cardSeq), plaintext: canonicalJSON(part.json),
                              aad: sealedAAD(workspace: workspace, cardSeq: cardSeq))
    }

    /// A card signed by `WSK` alone; `sealed_hash` and `ck_commit` are derived here.
    package static func make(delegation: SignedObject, workspace: ID16, wxk: AgreementPublicKey, wxkVersion: UInt32, owner: ID16,
                             relayURL: String, cardSeq: UInt32, issuedMs: Int64, sealed: Data, ck: SymmetricKey,
                             wsk: some Signer) throws -> JSONValue {
        let o: [String: JSONValue] = [
            "v": 2, "suite": 2, "kind": "card", "workspace_id": .string(workspace.hex),
            "wsk_pub": .string(B64U.encode(wsk.publicKey.x963)), "wxk_pub": .string(B64U.encode(wxk.x963)),
            "wxk_version": .int(Int64(wxkVersion)), "owner_person_id": .string(owner.hex), "relay_url": .string(relayURL),
            "card_seq": .int(Int64(cardSeq)), "issued_ms": .int(issuedMs),
            "sealed_hash": .string(B64U.encode(Data(SHA256.hash(data: sealed)))),
            "ck_commit": .string(B64U.encode(ckCommit(workspace: workspace, cardSeq: cardSeq, ck: ck)))]
        let signed = try SignedObject.sign(o, kind: .card, signer: wsk)
        return ["delegation": delegation.json, "o": .object(o), "sig": .string(B64U.encode(signed.signature)),
                "sealed": .string(B64U.encode(sealed))]
    }
}

/// The card key `CK` sealed to a device (purpose `card`, object = workspace, epoch = card_seq, no extra; section 5.3 and
/// host-api v0). Not sender-authenticated: the card's `ck_commit` binds the recovered key.
public enum CardKeyWrap {
    package static func open(sealed: Data, device: some KeyAgreer, deviceID: ID16, workspace: ID16, cardSeq: UInt32) throws -> SymmetricKey {
        let ck = try Sealing.open(with: device, recipientID: deviceID, purpose: .card, object: workspace, epoch: cardSeq, sealed: sealed)
        guard ck.count == 32 else { throw Refusal.malformed }
        return SymmetricKey(data: ck)
    }

    package static func seal(ck: SymmetricKey, to device: AgreementPublicKey, deviceID: ID16, workspace: ID16, cardSeq: UInt32) throws -> Data {
        try Sealing.seal(to: device, recipientID: deviceID, purpose: .card, object: workspace, epoch: cardSeq, plaintext: ck.rawBytes)
    }
}
