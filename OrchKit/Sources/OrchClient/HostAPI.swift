import Foundation
import OrchProtocol

/// Relay HTTP v2 adapter (protocol-v2 section 19): route spelling, strict JSON bodies and refusal mapping. There is no
/// adapter version: no `host_api` field and no `Orch-Host-API` header on the relay wire. (The `host_api: 0` field inside
/// bridge-tunnelled HOST views, `/v2/snapshot` and friends, is a different thing and is unchanged.)
public enum HostAPI {
    public static let base = "/v2"
    /// Protocol section 19: the relay sends at most 4 MiB per response on every route.
    public static let maxJSONBytes = 4 << 20

    // MARK: requests

    /// A request or reply body: the exact field set, canonical (`cj`), nothing added.
    public static func json(_ fields: [String: JSONValue] = [:]) -> Data {
        (try? canonicalJSON(.object(fields))) ?? Data()
    }

    /// A decimal with no sign, no leading zero and no more than 64 bits: the only spelling a cursor takes on the wire.
    public static func decimal(_ v: UInt64) -> String { String(v) }

    public static func parseDecimal(_ s: String) -> UInt64? {
        let u = Array(s.utf8)
        guard !u.isEmpty, u.count <= 20, u.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), u.count == 1 || u[0] != 0x30 else { return nil }
        return UInt64(s)
    }

    // MARK: replies

    /// Strict (section 2.3) parse of a relay JSON body: an object. Throws `ClientError.badReply`.
    public static func object(_ body: Data) throws -> [String: JSONValue] {
        guard let v = try? StrictJSON.parse(body, maxBytes: maxJSONBytes), let o = v.object, o.allKeysASCII2 else {
            throw ClientError.badReply
        }
        return o
    }

    /// The body is an object with exactly these fields (section 19.6: field sets are exact).
    static func exact(_ body: Data, _ keys: Set<String>) throws -> [String: JSONValue] {
        let o = try object(body)
        guard Set(o.keys) == keys else { throw ClientError.badReply }
        return o
    }

    public struct Challenge: Equatable, Sendable { public let challenge: Data; public let expiresMs: Int64 }
    public static func challenge(_ body: Data) throws -> Challenge {
        let o = try exact(body, ["challenge", "expires_ms"])
        guard let c = o["challenge"]?.string.flatMap({ B64U.decode($0, length: 32) }), let e = o["expires_ms"]?.int else { throw ClientError.badReply }
        return Challenge(challenge: c, expiresMs: e)
    }

    public struct Login: Equatable, Sendable { public let session: RelaySession; public let expiresMs: Int64 }
    public static func login(_ body: Data) throws -> Login {
        let o = try exact(body, ["token", "expires_ms"])
        guard let t = o["token"]?.string, !t.isEmpty, let e = o["expires_ms"]?.int else { throw ClientError.badReply }
        return Login(session: RelaySession(token: t), expiresMs: e)
    }

    public static func loginBody(challenge: Data, kind: RelayAuth.Kind, id: ID16, signature: Data) -> Data {
        json(["challenge": .string(B64U.encode(challenge)), "kind": .string(kind == .device ? "device" : "workspace"),
              "id": .string(id.hex), "sig": .string(B64U.encode(signature))])
    }

    public struct Chunk: Equatable, Sendable {
        public let id: ID16
        /// At most 2^53-1: it travels as a JSON integer.
        public let idx: UInt64
        public let last: Bool
        public let stream: Bool
        public let envelope: Data
    }

    /// `{"chunks":[...]}`. An empty list means nothing available, never approval or refusal.
    public static func chunks(_ body: Data) throws -> [Chunk] {
        let o = try exact(body, ["chunks"])
        guard let list = o["chunks"]?.array else { throw ClientError.badReply }
        return try list.map { c in
            guard let m = c.object, Set(m.keys) == ["id", "idx", "last", "stream", "envelope"], let id = m["id"]?.string.flatMap({ ID16(hex: $0) }),
                  let idx = m["idx"]?.int, idx >= 0, let last = m["last"]?.bool, let stream = m["stream"]?.bool,
                  let env = m["envelope"]?.string.flatMap({ B64U.decode($0) }) else { throw ClientError.badReply }
            return Chunk(id: id, idx: UInt64(idx), last: last, stream: stream, envelope: env)
        }
    }

    public static func grants(_ body: Data) throws -> [JSONValue] {
        guard let a = try exact(body, ["grants"])["grants"]?.array else { throw ClientError.badReply }
        return a
    }

    public static func memberList(_ body: Data) throws -> JSONValue {
        guard let v = try exact(body, ["member_list"])["member_list"] else { throw ClientError.badReply }
        return v
    }

    public static func card(_ body: Data) throws -> JSONValue {
        guard let v = try exact(body, ["card"])["card"] else { throw ClientError.badReply }
        return v
    }

    /// One held `(person, revocation)` pair of a device id. `provenance` is the relay's own label, never a decision input.
    public struct RevocationPair: Equatable, Sendable {
        public enum Provenance: String, Sendable { case registry, chain, feed }
        public let personID: ID16
        public let reason: String
        /// The signed revocation record, unverified: the caller verifies it under the pinned person key.
        public let revocation: JSONValue
        public let provenance: Provenance
    }

    /// `GET /v2/devices/{d}/revocation`: `{"pairs": [...], "next": cursor|null}`; `next` is opaque and goes back as `after`.
    public struct RevocationPage: Equatable, Sendable {
        public let pairs: [RevocationPair]
        public let next: String?
    }

    public static func revocationPage(_ body: Data) throws -> RevocationPage {
        let o = try exact(body, ["pairs", "next"])
        guard let list = o["pairs"]?.array, list.count <= 32 else { throw ClientError.badReply }
        let pairs = try list.map { e -> RevocationPair in
            guard let m = e.object, Set(m.keys) == ["person_id", "reason", "revocation", "provenance"],
                  let person = m["person_id"]?.string.flatMap({ ID16(hex: $0) }), let reason = m["reason"]?.string,
                  let rev = m["revocation"], rev.object != nil,
                  let prov = m["provenance"]?.string.flatMap({ RevocationPair.Provenance(rawValue: $0) }) else { throw ClientError.badReply }
            return RevocationPair(personID: person, reason: reason, revocation: rev, provenance: prov)
        }
        let next: String?
        switch o["next"] {
        case .some(.null): next = nil
        case .some(.string(let s)) where !s.isEmpty && s.utf8.count <= 512: next = s
        default: throw ClientError.badReply
        }
        return RevocationPage(pairs: pairs, next: next)
    }

    /// `{"requests": [signed cert_request]}` (unverified: the primary checks each one, section 8.4 step 2).
    public static func certRequests(_ body: Data) throws -> [JSONValue] {
        guard let a = try exact(body, ["requests"])["requests"]?.array else { throw ClientError.badReply }
        return a
    }

    /// `{"person_id": hex}`.
    public static func account(_ body: Data) throws -> ID16 {
        guard let p = try exact(body, ["person_id"])["person_id"]?.string.flatMap({ ID16(hex: $0) }) else { throw ClientError.badReply }
        return p
    }

    /// An empty success body, exactly `{}`.
    public static func empty(_ body: Data) throws {
        guard try exact(body, []).isEmpty else { throw ClientError.badReply }
    }

    public struct CardKey: Equatable, Sendable { public let workspace: ID16, device: ID16; public let cardSeq: UInt32; public let sealed: Data }
    public static func cardKey(_ body: Data) throws -> CardKey {
        let o = try exact(body, ["workspace_id", "device_id", "card_seq", "sealed"])
        guard let ws = o["workspace_id"]?.string.flatMap({ ID16(hex: $0) }), let dev = o["device_id"]?.string.flatMap({ ID16(hex: $0) }),
              let seq = o["card_seq"]?.int, seq >= 1, seq <= Int64(UInt32.max), let sealed = o["sealed"]?.string.flatMap({ B64U.decode($0) })
        else { throw ClientError.badReply }
        return CardKey(workspace: ws, device: dev, cardSeq: UInt32(seq), sealed: sealed)
    }

    // MARK: errors

    /// Maps a non-2xx reply: a section 14 relay refusal (`{"error": code, ...}` with its documented fields only and a status
    /// that code may carry) or `badReply`. Sealed host refusals never come through here.
    public static func failure(of reply: WireReply) -> ClientError {
        // The relay is a FastAPI app: a route it does not have answers `{"detail":"Not Found"}`, not a section 14 refusal. That is
        // "no such route" (the same meaning a missing resource has), not a malformed reply.
        if reply.status == 404, let v = try? StrictJSON.parse(reply.body, maxBytes: maxJSONBytes), let o = v.object,
           o.count == 1, o["detail"]?.string == "Not Found" { return .relay(RelayRefusal(status: 404, code: .notFound)) }
        guard let v = try? StrictJSON.parse(reply.body, maxBytes: maxJSONBytes), let o = v.object, o.allKeysASCII2,
              let code = o["error"]?.string,
              let r = RelayRefusal(status: reply.status, code: code, fields: o, retryAfter: retryAfter(reply)) else { return .badReply }
        return .relay(r)
    }

    /// `Retry-After` as a strict decimal of delta-seconds (no sign, no leading zero, no whitespace beyond what the header
    /// parser already trimmed, no HTTP-date), clamped to 1...3600. Anything else is "no hint", never a negative or huge wait.
    static func retryAfter(_ reply: WireReply) -> Int? {
        // `retry-after` must stay in `HTTP1ResponseParser.strictRepeats` (a conflicting repeat is refused); the test
        // `everyWireHeaderTheClientReadsIsAStrictRepeat` lists every wire header the client reads.
        guard let h = reply.header("retry-after"), let v = parseDecimal(h) else { return nil }
        return Int(min(max(v, 1), 3600))
    }

    /// 2xx body, or the mapped failure.
    public static func expect(_ reply: WireReply, status: Int = 200) throws -> Data {
        guard reply.status == status else { throw failure(of: reply) }
        return reply.body
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    var allKeysASCII2: Bool { keys.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { $0 < 0x80 } } }
}

/// Protocol section 14 relay and orch-publish HTTP codes, with section 19.6's additions. Unsigned: a relay can say anything,
/// so none of these is ever evidence of a host decision (a relay `revoked` only triggers fetching the signed record).
/// Parsing and mapping only: what the client DOES on each code (membership, cert rejection, bridge 202/429 handling) is
/// built in later changes.
public struct RelayRefusal: Error, Equatable, Sendable {
    public enum Code: String, Sendable, CaseIterable {
        case malformed, wrongSuite = "wrong_suite", certInvalid = "cert_invalid", certExpired = "cert_expired"
        case delegationMismatch = "delegation_mismatch", tooLarge = "too_large"
        case badSignature = "bad_signature", staleTimestamp = "stale_timestamp", unknownWorkspace = "unknown_workspace"
        case replay, unknownChallenge = "unknown_challenge", expired, unauthenticated
        case revoked, otherPerson = "other_person", scopeExceeded = "scope_exceeded", notEligible = "not_eligible"
        case notForThisDevice = "not_for_this_device"
        case notFound = "not_found"
        case otherWorkspace = "other_workspace", wskChanged = "wsk_changed", delegationChanged = "delegation_changed"
        case staleCard = "stale_card", wxkChangedWithoutVersion = "wxk_changed_without_version", badWxkVersion = "bad_wxk_version"
        case staleList = "stale_list", badEpoch = "bad_epoch", rotationRequired = "rotation_required", missingGrant = "missing_grant"
        /// Q10: a list at the relay's current epoch with another `wk_commit` (409; relay G2b).
        case wkCommitChanged = "wk_commit_changed"
        case alreadyClaimed = "already_claimed", versionConflict = "version_conflict"
        case accountExists = "account_exists", certConflict = "cert_conflict", grantConflict = "grant_conflict"
        case wrapConflict = "wrap_conflict", ridConflict = "rid_conflict", retryExhausted = "retry_exhausted"
        case chunkConflict = "chunk_conflict", staleEpoch = "stale_epoch", holderConflict = "holder_conflict", fenced
        case requestOpen = "request_open", replayed, alreadySigned = "already_signed"
        case preconditionRequired = "precondition_required"
        case rateLimited = "rate_limited", quotaExceeded = "quota_exceeded", overloaded
    }
    public let status: Int
    public let code: Code
    /// `Retry-After` in whole seconds (429 and 503 only), clamped to 1...3600; nil when absent or not integer delta-seconds.
    public let retryAfter: Int?
    /// The unsigned `stale_epoch` hint (`epoch`). A hint only: never trusted as a host refusal.
    public let epoch: UInt32?
    /// `version_conflict`: the stored version (`current`). `stale_timestamp`: the relay clock (`server_ms`).
    public let current: UInt32?
    public let serverMs: Int64?
    /// `already_claimed`: the claiming workspace, nil when the relay sent null.
    public let claimedBy: ID16?

    public init(status: Int, code: Code, retryAfter: Int? = nil, epoch: UInt32? = nil, current: UInt32? = nil, serverMs: Int64? = nil, claimedBy: ID16? = nil) {
        self.status = status; self.code = code; self.retryAfter = retryAfter; self.epoch = epoch
        self.current = current; self.serverMs = serverMs; self.claimedBy = claimedBy
    }

    /// The protocol section 14 / 19.6 table: the HTTP statuses each code may carry. Most have one; `cert_expired` is 400 for
    /// sessions and 403 for membership, `expired` is 401 (challenge) and 410 (unknown or expired rid), `too_large` is 413 for
    /// JSON routes and 400 for ORB2 posts.
    public static func statuses(of code: Code) -> Set<Int> {
        switch code {
        case .malformed, .wrongSuite, .certInvalid, .delegationMismatch: [400]
        case .certExpired: [400, 403]
        case .tooLarge: [400, 413]
        case .badSignature, .staleTimestamp, .unknownWorkspace, .replay, .unknownChallenge, .unauthenticated: [401]
        case .expired: [401, 410]
        case .revoked, .otherPerson, .scopeExceeded, .notEligible, .notForThisDevice: [403]
        case .notFound: [404]
        case .otherWorkspace, .wskChanged, .delegationChanged, .staleCard, .wxkChangedWithoutVersion, .badWxkVersion, .staleList,
             .badEpoch, .rotationRequired, .missingGrant, .wkCommitChanged, .alreadyClaimed, .versionConflict, .accountExists, .certConflict,
             .grantConflict, .wrapConflict, .ridConflict, .retryExhausted, .chunkConflict, .staleEpoch, .holderConflict, .fenced,
             .requestOpen, .replayed, .alreadySigned: [409]
        case .preconditionRequired: [428]
        case .rateLimited, .quotaExceeded: [429]
        case .overloaded: [503]
        }
    }

    /// The fields a code carries besides `error` (section 14): nothing else is accepted.
    static func extraFields(of code: Code) -> Set<String> {
        switch code {
        case .staleTimestamp: ["server_ms"]
        case .alreadyClaimed: ["claimed_by"]
        case .versionConflict: ["current"]
        case .staleEpoch: ["epoch"]
        default: []
        }
    }

    /// Strict: a known code with a status it may carry and exactly its documented fields: those section 14 lists for the code are
    /// required and type-checked, anything else is refused.
    init?(status: Int, code: String, fields: [String: JSONValue], retryAfter: Int? = nil) {
        guard let c = Code(rawValue: code), Self.statuses(of: c).contains(status),
              Set(fields.keys) == Set(["error"]).union(Self.extraFields(of: c)) else { return nil }
        var epoch: UInt32?, current: UInt32?, serverMs: Int64?, claimedBy: ID16?
        switch c {
        case .staleEpoch:
            guard let e = fields["epoch"]?.int, e >= 1, e <= Int64(UInt32.max) else { return nil }
            epoch = UInt32(e)
        case .versionConflict:
            guard let n = fields["current"]?.int, n >= 0, n <= Int64(UInt32.max) else { return nil }
            current = UInt32(n)
        case .staleTimestamp:
            guard let m = fields["server_ms"]?.int, m >= 0 else { return nil }
            serverMs = m
        case .alreadyClaimed:
            switch fields["claimed_by"] {
            case .some(.null): break
            case .some(.string(let h)): guard let id = ID16(hex: h) else { return nil }; claimedBy = id
            default: return nil
            }
        default: break
        }
        self.init(status: status, code: c, retryAfter: (status == 429 || status == 503) ? retryAfter : nil, epoch: epoch,
                  current: current, serverMs: serverMs, claimedBy: claimedBy)
    }
}

/// Sealed, host-signed refusals (protocol section 14, bridge table). Produced from slice 2a on, after verification; kept a
/// separate type so a relay HTTP error can never be mistaken for one.
public enum HostRefusal: Error, Equatable, Sendable {
    case malformed, notVisible, notMember, revoked, badSignature, ridConflict
    case alreadyDone(status: String)
    case staleTimestamp(hostMs: Int64)
    case staleSequence(high: UInt64)
    case staleEpoch(epoch: UInt32)
    case forbiddenScope, busy, scopeChanged, stopped
    case alreadyAnswered(byDeviceLabel: String, atMs: Int64)
    case questionChanged(contentHash: Data)
    case pairingClosed, otherPerson, certInvalid, certExpired
}

/// What a client call throws once a reply has been understood. Relay and host refusals are never conflated.
public enum ClientError: Error, Equatable, Sendable {
    case relay(RelayRefusal)
    case host(HostRefusal)
    /// The reply was not what section 19 promises (not strict JSON, wrong field set, wrong types, an unknown code or a code
    /// under a status it may not carry).
    case badReply
}
