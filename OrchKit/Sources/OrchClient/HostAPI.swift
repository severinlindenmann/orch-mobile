import Foundation
import OrchProtocol

/// Host API v0 adapter (host-api sections 1 and 3): the version boundary, route spelling and strict JSON bodies.
/// Everything here is provisional v0 and independent of the signed objects' `v: 2`.
public enum HostAPI {
    public static let version: Int64 = 0
    public static let base = "/mobile/host-api/0"
    public static let versionHeader = "orch-host-api"
    public static let maxJSONBytes = 2 << 20

    // MARK: requests

    /// Adapter JSON with `host_api: 0` first added, canonical.
    public static func json(_ fields: [String: JSONValue] = [:]) -> Data {
        var o = fields
        o["host_api"] = .int(version)
        return (try? canonicalJSON(.object(o))) ?? Data()
    }

    /// A decimal with no sign, no leading zero and no more than 64 bits: the only spelling a cursor takes on the wire.
    public static func decimal(_ v: UInt64) -> String { String(v) }

    public static func parseDecimal(_ s: String) -> UInt64? {
        let u = Array(s.utf8)
        guard !u.isEmpty, u.count <= 20, u.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), u.count == 1 || u[0] != 0x30 else { return nil }
        return UInt64(s)
    }

    // MARK: replies

    /// Strict parse of an adapter JSON body: an object, `host_api == 0`. Throws `AdapterError`.
    public static func object(_ body: Data) throws -> [String: JSONValue] {
        guard let v = try? StrictJSON.parse(body, maxBytes: maxJSONBytes), let o = v.object, o.allKeysASCII2 else {
            throw AdapterError.badReply
        }
        guard let ver = o["host_api"] else { throw AdapterError.badReply }
        guard ver == .int(version) else { throw AdapterError.unsupportedHostAPI }
        return o
    }

    static func exact(_ body: Data, _ keys: Set<String>) throws -> [String: JSONValue] {
        let o = try object(body)
        guard Set(o.keys) == keys.union(["host_api"]) else { throw AdapterError.badReply }
        return o
    }

    public struct Challenge: Equatable, Sendable { public let challenge: Data; public let expiresMs: Int64 }
    public static func challenge(_ body: Data) throws -> Challenge {
        let o = try exact(body, ["challenge", "expires_ms"])
        guard let c = o["challenge"]?.string.flatMap({ B64U.decode($0, length: 32) }), let e = o["expires_ms"]?.int else { throw AdapterError.badReply }
        return Challenge(challenge: c, expiresMs: e)
    }

    public struct Login: Equatable, Sendable { public let session: RelaySession; public let expiresMs: Int64 }
    public static func login(_ body: Data) throws -> Login {
        let o = try exact(body, ["token", "expires_ms"])
        guard let t = o["token"]?.string, !t.isEmpty, let e = o["expires_ms"]?.int else { throw AdapterError.badReply }
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

    /// `{"host_api":0,"chunks":[...]}`. An empty list means nothing available, never approval or refusal.
    public static func chunks(_ body: Data) throws -> [Chunk] {
        let o = try exact(body, ["chunks"])
        guard let list = o["chunks"]?.array else { throw AdapterError.badReply }
        return try list.map { c in
            guard let m = c.object, Set(m.keys) == ["id", "idx", "last", "stream", "envelope"], let id = m["id"]?.string.flatMap({ ID16(hex: $0) }),
                  let idx = m["idx"]?.int, idx >= 0, let last = m["last"]?.bool, let stream = m["stream"]?.bool,
                  let env = m["envelope"]?.string.flatMap({ B64U.decode($0) }) else { throw AdapterError.badReply }
            return Chunk(id: id, idx: UInt64(idx), last: last, stream: stream, envelope: env)
        }
    }

    public static func grants(_ body: Data) throws -> [JSONValue] {
        guard let a = try exact(body, ["grants"])["grants"]?.array else { throw AdapterError.badReply }
        return a
    }

    public static func memberList(_ body: Data) throws -> JSONValue {
        guard let v = try exact(body, ["member_list"])["member_list"] else { throw AdapterError.badReply }
        return v
    }

    public static func card(_ body: Data) throws -> JSONValue {
        guard let v = try exact(body, ["card"])["card"] else { throw AdapterError.badReply }
        return v
    }

    public static func revocation(_ body: Data) throws -> JSONValue {
        guard let v = try exact(body, ["record"])["record"] else { throw AdapterError.badReply }
        return v
    }

    public struct CardKey: Equatable, Sendable { public let workspace: ID16, device: ID16; public let cardSeq: UInt32; public let sealed: Data }
    public static func cardKey(_ body: Data) throws -> CardKey {
        let o = try exact(body, ["workspace_id", "device_id", "card_seq", "sealed"])
        guard let ws = o["workspace_id"]?.string.flatMap({ ID16(hex: $0) }), let dev = o["device_id"]?.string.flatMap({ ID16(hex: $0) }),
              let seq = o["card_seq"]?.int, seq >= 1, seq <= Int64(UInt32.max), let sealed = o["sealed"]?.string.flatMap({ B64U.decode($0) })
        else { throw AdapterError.badReply }
        return CardKey(workspace: ws, device: dev, cardSeq: UInt32(seq), sealed: sealed)
    }

    // MARK: errors

    /// Maps a non-2xx reply. Relay refusals (protocol section 14 HTTP codes) and adapter-only errors are different cases;
    /// sealed host refusals never come through here.
    public static func failure(of reply: WireReply) -> ClientError {
        guard let v = try? StrictJSON.parse(reply.body, maxBytes: maxJSONBytes), let o = v.object, let code = o["error"]?.string else {
            return .adapter(.badReply)
        }
        if o["host_api"] != nil {
            guard o["host_api"] == .int(version) else { return .adapter(.unsupportedHostAPI) }
            guard let a = AdapterError(code: code, retryAfter: reply.header("retry-after").flatMap { Int($0) }) else { return .adapter(.badReply) }
            return .adapter(a)
        }
        guard let r = RelayRefusal(status: reply.status, code: code, fields: o) else { return .adapter(.badReply) }
        return .relay(r)
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

/// Adapter-only errors: they carry `host_api` on the wire and are never a protocol section 14 refusal.
public enum AdapterError: Error, Equatable, Sendable {
    /// HTTP 400 `unsupported_host_api` (header or body).
    case unsupportedHostAPI
    case unauthenticated
    case notFound
    case rateLimited(retryAfter: Int?)
    case quotaExceeded
    case notImplemented
    /// The reply was not what the adapter promises (not JSON, wrong field set, wrong types).
    case badReply

    init?(code: String, retryAfter: Int?) {
        switch code {
        case "unsupported_host_api": self = .unsupportedHostAPI
        case "unauthenticated": self = .unauthenticated
        case "not_found": self = .notFound
        case "rate_limited": self = .rateLimited(retryAfter: retryAfter)
        case "quota_exceeded": self = .quotaExceeded
        case "not_implemented": self = .notImplemented
        default: return nil
        }
    }
}

/// Protocol section 14 relay and orch-publish HTTP codes. Unsigned: a relay can say anything, so none of these is ever
/// evidence of a host decision (a relay `revoked` only triggers fetching the signed record).
public struct RelayRefusal: Error, Equatable, Sendable {
    public enum Code: String, Sendable, CaseIterable {
        case malformed, wrongSuite = "wrong_suite", certInvalid = "cert_invalid", certExpired = "cert_expired"
        case delegationMismatch = "delegation_mismatch"
        case badSignature = "bad_signature", staleTimestamp = "stale_timestamp", unknownWorkspace = "unknown_workspace"
        case replay, unknownChallenge = "unknown_challenge", expired
        case revoked, otherPerson = "other_person", scopeExceeded = "scope_exceeded", notEligible = "not_eligible"
        case notForThisDevice = "not_for_this_device"
        case otherWorkspace = "other_workspace", wskChanged = "wsk_changed", delegationChanged = "delegation_changed"
        case staleCard = "stale_card", wxkChangedWithoutVersion = "wxk_changed_without_version", badWxkVersion = "bad_wxk_version"
        case staleList = "stale_list", badEpoch = "bad_epoch", rotationRequired = "rotation_required", missingGrant = "missing_grant"
        case alreadyClaimed = "already_claimed", versionConflict = "version_conflict"
        case preconditionRequired = "precondition_required"
    }
    public let status: Int
    public let code: Code

    public init(status: Int, code: Code) { self.status = status; self.code = code }

    init?(status: Int, code: String, fields: [String: JSONValue]) {
        guard let c = Code(rawValue: code) else { return nil }
        self.status = status; self.code = c
    }
}

/// Sealed, host-signed refusals (protocol section 14, bridge table). Produced from slice 2a on, after verification; kept a
/// separate type so a relay HTTP error can never be mistaken for one.
public enum HostRefusal: Error, Equatable, Sendable {
    case malformed, notMember, revoked, badSignature, ridConflict
    case alreadyDone(status: String)
    case staleTimestamp(hostMs: Int64)
    case staleSequence(high: UInt64)
    case staleEpoch(epoch: UInt32)
    case forbiddenScope, busy, scopeChanged, stopped
    case alreadyAnswered(byDeviceLabel: String, atMs: Int64)
    case questionChanged(contentHash: Data)
    case pairingClosed, otherPerson, certInvalid, certExpired
}

/// What a client call throws once a reply has been understood. Three families, never conflated.
public enum ClientError: Error, Equatable, Sendable {
    case relay(RelayRefusal)
    case adapter(AdapterError)
    case host(HostRefusal)
}
