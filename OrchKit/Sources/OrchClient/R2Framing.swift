import Foundation
import OrchProtocol

/// The phone's side of orch-core's R2 framing (host section 11A.5 "As built in R2", the sheet orch-mobile codes against; data:
/// `r2_framing.json`). A column-R request is a sealed bridge request (relay protocol 8.6) whose meta is exactly
/// `{"op", "args", "idem"?, "rd"?}` with `data` empty; the answer is a first chunk with meta exactly `{"status":"ok"}` (later chunks
/// `{}`) whose data is `cj(Result)`, or one `LAST | REFUSAL` chunk with the closed per-code field set. Nothing here touches a key, a
/// clock or the network: sealing, signing and posting stay in `WorkspaceSession`.
public enum R2 {
    public enum Kind: String, Sendable, Equatable { case read, write }

    /// One row of the closed op table (`framing.OPS`): the relay op, the backend op it maps to, the scope the device needs, and a
    /// write's one event type.
    public struct OpSpec: Sendable, Equatable {
        public let backend: String
        public let kind: Kind
        public let scope: String
        public let event: String?
    }

    /// The ONE closed table. A request op outside it is a sealed `forbidden_scope`, so the phone never builds one.
    public static let ops: [String: OpSpec] = [
        "ticket.query": OpSpec(backend: "ticket.query", kind: .read, scope: "look", event: nil),
        "ticket.get": OpSpec(backend: "ticket.get", kind: .read, scope: "look", event: nil),
        "ticket.text": OpSpec(backend: "ticket.text", kind: .read, scope: "look", event: nil),
        "needs": OpSpec(backend: "needs", kind: .read, scope: "look", event: nil),
        "activity.list": OpSpec(backend: "activity.list", kind: .read, scope: "look", event: nil),
        "workspace.show": OpSpec(backend: "workspace.show", kind: .read, scope: "look", event: nil),
        "workspace.settings": OpSpec(backend: "workspace.settings", kind: .read, scope: "look", event: nil),
        "member.list": OpSpec(backend: "member.list", kind: .read, scope: "look", event: nil),
        "whoami": OpSpec(backend: "whoami", kind: .read, scope: "look", event: nil),
        "outcome.get": OpSpec(backend: "outcome.get", kind: .read, scope: "look", event: nil),
        "new_ticket": OpSpec(backend: "relay.submit", kind: .write, scope: "decide", event: "ticket.created"),
        "answer": OpSpec(backend: "relay.submit", kind: .write, scope: "decide", event: "question.answered"),
    ]

    public static let metaKeys: Set<String> = ["op", "args", "idem", "rd"]
    /// `auth` values column R accepts on a person event (`COLUMN_R_AUTH`).
    public static let columnRAuth: Set<String> = ["passphrase", "secure-enclave-unlocked"]

    // MARK: constants (framing.py; checked against the vectors' `constants`)

    /// The relay's per-device budget of undelivered response bytes (2 MiB).
    public static let relayDeviceResponseBytes = 2 << 20
    /// The largest `cj(Result)` whose chunk envelopes fit it (8 full chunks): 2 095 587 bytes.
    public static let maxAnswer = 2_095_587
    public static let chunkRoom = Bridge.maxChunk - Bridge.overhead
    /// The ULID window a never-seen write is judged in, against HOST time.
    public static let freshPastMs: Int64 = 900_000
    public static let freshFutureMs: Int64 = 300_000
    /// `outcome.get` answers `pending` for an idem without a record until its ULID time plus this (900 s + 300 s).
    public static let pendingNoRecordMs: Int64 = 1_200_000

    // MARK: request meta

    /// Why a meta is refused before it is sent: the code the host would answer with.
    public enum MetaError: Error, Equatable, Sendable {
        case reqInvalid, grantSecretInArgs, forbiddenScope, idemRequired, idemInvalid
        public var code: String {
            switch self {
            case .reqInvalid: "req.invalid"
            case .grantSecretInArgs: "grant.secret_in_args"
            case .forbiddenScope: "forbidden_scope"
            case .idemRequired: "idem.required"
            case .idemInvalid: "idem.invalid"
            }
        }
    }

    /// `check_meta` (step 11's first checks, in the host's order): an `auth` key, a grant-shaped string anywhere, an op outside the
    /// table, another key or a non-object `args` or non-empty `data`, then the idem rules. The phone applies it to what it builds, and
    /// FakeHost applies it to what it receives, so both sides run one function.
    @discardableResult
    public static func checkMeta(_ meta: JSONValue, data: Data = Data()) throws -> (op: String, spec: OpSpec, args: [String: JSONValue], idem: String?, rd: String?) {
        guard let m = meta.object, m.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.allSatisfy { $0 < 0x80 } }) else { throw MetaError.reqInvalid }
        if m["auth"] != nil { throw MetaError.reqInvalid }
        if grantShaped(meta) { throw MetaError.grantSecretInArgs }
        guard let op = m["op"]?.string, let spec = ops.first(where: { $0.key.utf8.elementsEqual(op.utf8) })?.value else { throw MetaError.forbiddenScope }
        guard Set(m.keys).isSubset(of: metaKeys), let args = m["args"]?.object, data.isEmpty else { throw MetaError.reqInvalid }
        let idem = m["idem"]
        if spec.kind == .write {
            guard let idem else { throw MetaError.idemRequired }
            guard let s = idem.string, ULID.isValid(s) else { throw MetaError.idemInvalid }
        } else if idem != nil { throw MetaError.reqInvalid }
        var rd: String?
        if let r = m["rd"] {
            guard let s = r.string, isDigest(s) else { throw MetaError.reqInvalid }
            rd = s
        }
        return (op, spec, args, idem?.string, rd)
    }

    /// The meta of an op call, exactly `{"op", "args", "idem"?, "rd"?}`. Reads take no `idem`; a write's `idem` is its event id. `rd`
    /// (H12d) is normally added at the session's single injection point (`ReaderRD`), not here.
    public static func requestMeta(op: String, args: [String: JSONValue] = [:], idem: String? = nil, rd: String? = nil) throws -> JSONValue {
        var m: [String: JSONValue] = ["op": .string(op), "args": .object(args)]
        if let idem { m["idem"] = .string(idem) }
        if let rd { m["rd"] = .string(rd) }
        let meta = JSONValue.object(m)
        try checkMeta(meta)
        return meta
    }

    /// `sha256:` and 64 lower-case hex digits.
    static func isDigest(_ s: String) -> Bool {
        let u = Array(s.utf8), p = Array("sha256:".utf8)
        guard u.count == p.count + 64, u.starts(with: p) else { return false }
        return u.dropFirst(p.count).allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// `gr_[0-7][0-9A-HJKMNP-TV-Z]{25}\.[A-Za-z0-9_-]{43}` anywhere in any string, key or value (the host's `GRANT_SHAPE`).
    public static func grantShaped(_ v: JSONValue) -> Bool {
        switch v {
        case .string(let s): return containsGrantShape(s)
        case .array(let a): return a.contains(where: grantShaped)
        case .object(let o): return o.contains { containsGrantShape($0.key) || grantShaped($0.value) }
        default: return false
        }
    }

    static func containsGrantShape(_ s: String) -> Bool {
        let u = Array(s.utf8)
        let total = 3 + 1 + 25 + 1 + 43
        guard u.count >= total else { return false }
        func crockford(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A && c != 0x49 && c != 0x4C && c != 0x4F && c != 0x55)
        }
        func b64url(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F }
        for i in 0...(u.count - total) where u[i] == 0x67 && u[i + 1] == 0x72 && u[i + 2] == 0x5F {
            guard u[i + 3] >= 0x30, u[i + 3] <= 0x37 else { continue }
            guard (4..<29).allSatisfy({ crockford(u[i + $0]) }), u[i + 29] == 0x2E, (30..<73).allSatisfy({ b64url(u[i + $0]) }) else { continue }
            return true
        }
        return false
    }

    // MARK: answers

    /// A sealed answer to one request, whole: a Result, or a refusal.
    public enum Answer: Equatable, Sendable {
        case result(HostResult)
        case refusal(HostRefusal)
    }

    /// The meta of the first chunk of a success answer.
    public static let okMeta: JSONValue = ["status": "ok"]

    /// Is `meta` the first chunk of a success answer (`{"status":"ok"}` exactly)?
    static func isOKMeta(_ meta: JSONValue) -> Bool {
        guard let m = meta.object, m.exactly(["status"]), let s = m["status"]?.string else { return false }
        return s.utf8.elementsEqual("ok".utf8)
    }

    /// One decoded chunk of an answer (what `Bridge.checkResponse` accepted).
    public struct Chunk: Sendable {
        public let meta: JSONValue, data: Data, last: Bool, refusal: Bool
        public init(meta: JSONValue, data: Data, last: Bool, refusal: Bool) { self.meta = meta; self.data = data; self.last = last; self.refusal = refusal }
    }

    /// The whole answer from its accepted chunks, in order: a refusal is exactly one `LAST | REFUSAL` chunk; a success has meta exactly
    /// `{"status":"ok"}` on chunk 0 and `{}` on every later one, `LAST` on the final chunk only, and its data across the chunks is
    /// `cj(Result)` (at most `maxAnswer`). Anything else is `ViewError.malformed`.
    public static func assemble(_ chunks: [Chunk]) throws -> Answer {
        guard let first = chunks.first else { throw ViewError.malformed }
        if first.refusal {
            guard chunks.count == 1, first.last, first.data.isEmpty, let r = HostRefusal(meta: first.meta) else { throw ViewError.malformed }
            return .refusal(r)
        }
        guard isOKMeta(first.meta) else { throw ViewError.malformed }
        var body = Data()
        for (i, c) in chunks.enumerated() {
            guard !c.refusal, c.last == (i == chunks.count - 1) else { throw ViewError.malformed }
            if i > 0 { guard c.meta.object?.isEmpty == true else { throw ViewError.malformed } }
            body.append(c.data)
            guard body.count <= maxAnswer else { throw ViewError.malformed }
        }
        return .result(try HostResult(parsing: body))
    }

    /// The retry class of an answer (11A.5 "Retry classes", `framing.RETRY`; an unknown code is D). `effectsPossible` is the `internal`
    /// context after a write was admitted; `ctx` carries the `outcome.unknown_idem` context.
    public static func retryClass(of r: HostRefusal, context: PhoneRefusalContext? = nil) -> PhoneRetryClass {
        let ctx = context ?? PhoneRefusalContext(eventID: "", hostNowMs: 0)
        switch r {
        case .alreadyDone: return PhoneRetryTable.classify("already_done.unknown", ctx)
        default: return PhoneRetryTable.classify(r.code, ctx)
        }
    }
}

/// The §0.3 `Result` of one op: `data` is the op's own result. Unknown keys are ignored (the envelope is host text, unsigned and not
/// bound); the keys the phone reads are typed, and `data` and `exit` are required.
public struct HostResult: Equatable, Sendable {
    public let data: JSONValue
    public let key: String?
    public let seq: Int64
    public let cursor: Int64
    public let hints: [String]
    public let lines: [String]
    public let duplicate: Bool
    public let exit: Int64
    public let head: String?

    public init(parsing body: Data) throws {
        guard body.count <= R2.maxAnswer, let v = try? StrictJSON.parse(body, maxBytes: R2.maxAnswer), let o = v.object,
              o.keys.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 < 0x80 } }),
              let data = o["data"], let exit = o["exit"]?.int, (0...9).contains(exit) else { throw ViewError.malformed }
        func optString(_ k: String) throws -> String? {
            guard let v = o[k], !v.isNull else { return nil }
            guard let s = v.string else { throw ViewError.malformed }
            return s
        }
        func int(_ k: String) throws -> Int64 {
            guard let v = o[k] else { return 0 }
            guard let n = v.int, n >= 0, n <= maxSafeInt else { throw ViewError.malformed }
            return n
        }
        func strings(_ k: String) throws -> [String] {
            guard let v = o[k] else { return [] }
            guard let a = v.array, a.count <= 10_000 else { throw ViewError.malformed }
            return try a.map { guard let s = $0.string else { throw ViewError.malformed }; return s }
        }
        self.data = data; self.exit = exit
        key = try optString("key"); head = try optString("head")
        seq = try int("seq"); cursor = try int("cursor")
        hints = try strings("hints"); lines = try strings("lines")
        if let d = o["duplicate"] { guard let b = d.bool else { throw ViewError.malformed }; duplicate = b } else { duplicate = false }
    }
}
