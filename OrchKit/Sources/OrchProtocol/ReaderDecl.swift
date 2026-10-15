import CryptoKit
import Foundation

// H12d, the phone side of the reader-version handshake (host section 0.8.6 item 9, 9.2, 9.3, 9.5; protocol v2 section 8.3 and 8.6).

/// The runtime known-answer test of the `view` surface (9.2): the phone's REAL F1 question parser (`F1Question`, the code that renders
/// `answer.signer.auth`) is run over the corpus of `READER_VIEWS_1` and the results are hashed. A build declares level 1 only when every
/// outcome is the expected one (convenience accepted, passphrase accepted, bogus refused with `auth: null`) and the digest equals the one
/// core pins in `reader_kat_1.json` (`expected["1"].view`). Otherwise it declares nothing (level 0).
public enum ReaderKAT {
    /// `READER_VIEWS_1` (host 9.11): the signer on a question's answer in `ticket.get`. A phone that renders a signer in another view needs
    /// `READER_VIEWS_2`, a new corpus and a new level, never an edit of this list.
    public static let views1 = ["ticket.get.questions.answer"]
    /// orch-core `reader_kat_1.json` `expected["1"].view` (core-owned; vendored in the tests).
    public static let expectedView1 = "sha256:d76e4593ec191e91ca2f6bddef570cbfa1af14dae702bb5ded0572eebe1d9085"
    /// The `auth` values of the corpus, in corpus order: two valid, one that no reader may map to a known value.
    static let corpusAuth = ["convenience", "passphrase", "bogus"]
    static let expectedAccepted = [true, true, false]

    /// What a parser did with one corpus entry: `auth` is the parsed signer auth, nil when the entry was refused.
    package struct Result: Equatable, Sendable {
        package let view: String
        package let accepted: Bool
        package let auth: String?
        var json: JSONValue { ["view": .string(view), "accepted": .bool(accepted), "auth": auth.map { .string($0) } ?? .null] }
    }

    /// The production view parser for `ticket.get.questions.answer`: the parsed signer auth, or nil when the entry is refused.
    package static let productionParser: @Sendable (JSONValue) -> String? = { value in
        guard let q = try? F1Question(value), let a = q.answer?.signerAuth else { return nil }
        return a.rawValue
    }

    /// A `ticket.get` Question in state `answered` that differs from its siblings only in `answer.signer.auth` (core's corpus shape with the
    /// v1.7 `answer.id` the phone's parser requires: the view digest depends on the view ids and the outcomes, not on the entry shapes).
    package static func corpusEntry(auth: String) -> JSONValue {
        let person: JSONValue = .string("p_75bf75a3bb50b0c4ac02f8a757b90e23")
        return [
            "id": "Q1", "state": "answered", "blocking": true, "to": [person], "answered_by": person, "answered_seq": 3,
            "text": "Ship the reader handshake first?", "asked_at": "2026-10-10T10:05:00Z", "asked_seq": 2,
            "asked_by": ["kind": "person", "id": "p_6aae5cce832160e6f8cd9dadfbb4c5cd", "device": "d_7efc1ba896b95f9151978a1dad982e3a"],
            "options": [["key": "a", "label": "yes"], ["key": "b", "label": "no"]],
            "answer": ["by": person, "at": "2026-10-10T10:10:00Z", "seq": 3, "option": "a", "text": .null, "id": "01J9ZK00000000000000000003",
                       "signer": ["device": "d_c65032f21d43401cc223b05723c1e5b4", "auth": .string(auth)]],
        ]
    }

    /// Runs `parse` over the corpus of every view of level 1, in corpus order.
    package static func results1(parse: (JSONValue) -> String?) -> [Result] {
        var out: [Result] = []
        for view in views1 {
            for auth in corpusAuth {
                let a = parse(corpusEntry(auth: auth))
                out.append(Result(view: view, accepted: a != nil, auth: a))
            }
        }
        return out
    }

    /// `"sha256:" + hex(sha256(cj(results)))`, results in corpus order (F1 section 11.5).
    package static func digest(_ results: [Result]) -> String {
        let body = (try? canonicalJSON(.array(results.map(\.json)))) ?? Data()
        return "sha256:" + Hex.encode(SHA256.hash(data: body))
    }

    /// What a build may declare after its runtime KAT.
    public struct Capability: Equatable, Sendable {
        public let level: Int
        /// `kat` of the declaration: level -> surface -> digest.
        public let kat: [Int: [String: String]]
    }

    /// Level 1 with its `view` digest when the runtime KAT passes, nil (declare nothing) when it does not.
    package static func capability(parse: (JSONValue) -> String?) -> Capability? {
        let r = results1(parse: parse)
        guard r.map(\.accepted) == expectedAccepted, r.map(\.auth) == [corpusAuth[0], corpusAuth[1], nil] else { return nil }
        let d = digest(r)
        guard d.utf8.elementsEqual(expectedView1.utf8) else { return nil }
        return Capability(level: 1, kat: [1: ["view": d]])
    }

    /// The production result, computed once per process.
    public static let current: Capability? = capability(parse: productionParser)
}

/// A signed `reader_decl` (9.3): `{"o": {...}, "sig": b64u(Sign(dk_sig, "orch/v2/sig/reader-decl|" || cj(o)))}`. Kept verbatim: the exact
/// canonical bytes are what `rd` hashes and what a resend carries.
public struct ReaderDeclaration: Equatable, Sendable {
    public let json: JSONValue
    /// `cj(json)`.
    public let bytes: Data
    public let level: Int
    public let createdMs: Int64
    public let via: String
    /// `"sha256:" + hex(sha256(cj(reader_decl)))`: the declaration record's `digest` and the request's `rd` (protocol 8.6).
    public var digest: String { "sha256:" + Hex.encode(SHA256.hash(data: bytes)) }

    /// The cap of 9.3 / protocol 8.3: bytes of `cj(reader_decl)`.
    public static let maxBytes = 2048

    public enum Who: Equatable, Sendable {
        /// A pairing without a certificate: the link's `pk_pin` (32 bytes).
        case pkPin(Data)
        case person(ID16)
        var json: JSONValue {
            switch self {
            case .pkPin(let p): return ["pk_pin": .string(B64U.encode(p))]
            case .person(let p): return ["person_id": .string(p.hex)]
            }
        }
    }
    public enum Bind: Equatable, Sendable {
        case pair(offer: ID16, attempt: String)
        case declare
        var json: JSONValue {
            switch self {
            case .pair(let offer, let attempt): return ["via": "pair", "offer_id": .string(offer.hex), "attempt": .string(attempt)]
            case .declare: return ["via": "declare"]
            }
        }
    }

    /// Builds and signs a declaration with the (leased) device signer. `signer.publicKey` must be `dkSig`.
    package static func make(workspace: ID16, dkSig: SigningPublicKey, dkKx: AgreementPublicKey, who: Who, level: Int,
                             kat: [Int: [String: String]], bind: Bind, createdMs: Int64, signer: some Signer) throws -> ReaderDeclaration {
        guard signer.publicKey == dkSig, level >= 0, level <= ReaderDecl.levelMax, createdMs >= 0, createdMs <= maxSafeInt else { throw Refusal.malformed }
        if case .pkPin(let pin) = who, pin.count != 32 { throw Refusal.malformed }
        if case .pair(_, let attempt) = bind, !Identifiers.isAttempt(attempt) { throw Refusal.malformed }
        let (whoJSON, bindJSON) = (who.json, bind.json)
        // `kat` holds the levels 1...level (9.3): a level the build cannot prove is not declared
        var katJSON: [String: JSONValue] = [:]
        for l in stride(from: 1, through: level, by: 1) {
            guard let entry = kat[l], !entry.isEmpty else { throw Refusal.malformed }
            katJSON[String(l)] = .object(entry.mapValues { .string($0) })
        }
        let o: [String: JSONValue] = [
            "v": 1, "kind": "reader_decl", "suite": .int(Int64(Suite2.id)), "workspace_id": .string(workspace.hex),
            "device_id": .string(Identifiers.deviceID(dkSig).hex), "dk_hash": .string(B64U.encode(Identifiers.dkHash(sig: dkSig, kx: dkKx))),
            "who": whoJSON, "reader": .int(Int64(level)), "kat": .object(katJSON), "bind": bindJSON, "created_ms": .int(createdMs),
        ]
        let sig = try Signature.sign(signer, label: Label.sigReaderDecl, message: try canonicalJSON(.object(o)))
        let made = try ReaderDeclaration(signed: ["o": .object(o), "sig": .string(B64U.encode(sig))])
        // our own declaration must pass the gate we expect the host to apply (shape, signature, binding, kat form)
        let ctx = ReaderDecl.Context(workspace: workspace, dkSig: dkSig, dkKx: dkKx, who: who, bind: bind)
        guard case .success = ReaderDecl.check(made.json, ctx) else { throw Refusal.malformed }
        return made
    }

    /// The same declaration with a new `created_ms`, signed again (a pair declaration rebuilt after a clock correction, before any host
    /// stored it). Everything else, `who` and `bind` included, is copied from `self`.
    package func resigned(createdMs: Int64, dkSig: SigningPublicKey, dkKx: AgreementPublicKey, signer: some Signer) throws -> ReaderDeclaration {
        guard signer.publicKey == dkSig, createdMs >= 0, createdMs <= maxSafeInt, var o = json.object?["o"]?.object else { throw Refusal.malformed }
        o["created_ms"] = .int(createdMs)
        let sig = try Signature.sign(signer, label: Label.sigReaderDecl, message: try canonicalJSON(.object(o)))
        let made = try ReaderDeclaration(signed: ["o": .object(o), "sig": .string(B64U.encode(sig))])
        guard let who = o["who"], let bind = o["bind"], let ws = o["workspace_id"]?.string.flatMap({ ID16(hex: $0) }) else { throw Refusal.malformed }
        guard case .success = ReaderDecl.check(made.json, ReaderDecl.Context(workspace: ws, dkSig: dkSig, dkKx: dkKx, who: who, bind: bind)) else { throw Refusal.malformed }
        return made
    }

    /// Reads a stored or received declaration. The byte cap is checked BEFORE parsing (host 9.3 note I2); the form is strict. The
    /// signature is not verified here (`ReaderDecl.check` does that against a request's keys).
    public static func parse(_ data: Data) throws -> ReaderDeclaration {
        guard data.count <= maxBytes + 256 else { throw Refusal.malformed }
        return try ReaderDeclaration(signed: try StrictJSON.parse(data, maxBytes: maxBytes + 256))
    }

    public init(signed: JSONValue) throws {
        guard let m = signed.object, Set(m.keys) == ["o", "sig"], let o = m["o"]?.object, m["sig"]?.string != nil,
              let level = o["reader"]?.int, level >= 0, level <= ReaderDecl.levelMax,
              let created = o["created_ms"]?.int, created >= 0, created <= maxSafeInt,
              let via = o["bind"]?.object?["via"]?.string else { throw Refusal.malformed }
        let bytes = try canonicalJSON(signed)
        guard bytes.count <= ReaderDeclaration.maxBytes else { throw Refusal.malformed }
        self.json = signed; self.bytes = bytes; self.level = Int(level); self.createdMs = created; self.via = via
    }
}

public enum ReaderDecl {
    public static let levelMax = Int(Int32.max)

    /// Why a declaration was refused (the relay reference's names, protocol vectors `reader_decl.decls`).
    public enum Reason: String, Error, Sendable, Equatable { case shape, signature, workspace, device, keys, who, bind, katMissing = "kat_missing", katMismatch = "kat_mismatch" }

    /// The host's expectation of one request (relay reference `verify_reader_decl` ctx).
    package struct Context: Sendable {
        package var workspace: ID16
        package var dkSig: SigningPublicKey
        package var dkKx: AgreementPublicKey
        package var who: JSONValue
        package var bind: JSONValue
        package var hostMax = 1
        package var surfaces = ["view"]
        package var expectedKAT: [Int: [String: String]] = [:]
        package init(workspace: ID16, dkSig: SigningPublicKey, dkKx: AgreementPublicKey, who: JSONValue, bind: JSONValue) {
            self.workspace = workspace; self.dkSig = dkSig; self.dkKx = dkKx; self.who = who; self.bind = bind
        }
        package init(workspace: ID16, dkSig: SigningPublicKey, dkKx: AgreementPublicKey, who: ReaderDeclaration.Who, bind: ReaderDeclaration.Bind) {
            self.init(workspace: workspace, dkSig: dkSig, dkKx: dkKx, who: who.json, bind: bind.json)
        }
    }

    /// A check of a declaration the way the host's gate does it (host 9.3, in the reference's order). The phone uses it to verify its own
    /// declaration before it persists or sends it, and the tests run the relay's vectors through it.
    package static func check(_ decl: JSONValue, _ c: Context) -> Result<Int, Reason> {
        guard let d = try? ReaderDeclaration(signed: decl), let o = d.json.object?["o"]?.object, shapeOK(o, hostMax: c.hostMax),
              let sig = d.json.object?["sig"]?.string.flatMap({ B64U.decode($0) }), sig.count == Suite2.signatureLength else { return .failure(.shape) }
        guard let body = try? canonicalJSON(.object(o)),
              Signature.verify(c.dkSig, signature: sig, label: Label.sigReaderDecl, message: body) else { return .failure(.signature) }
        guard o["workspace_id"]?.string == c.workspace.hex else { return .failure(.workspace) }
        guard o["device_id"]?.string == Identifiers.deviceID(c.dkSig).hex else { return .failure(.device) }
        guard o["dk_hash"]?.string == B64U.encode(Identifiers.dkHash(sig: c.dkSig, kx: c.dkKx)) else { return .failure(.keys) }
        guard o["who"] == c.who else { return .failure(.who) }
        guard o["bind"] == c.bind else { return .failure(.bind) }
        let level = min(d.level, c.hostMax)
        if level >= 1 {
            for k in 1...level {
                guard let entry = o["kat"]?.object?[String(k)]?.object, c.surfaces.allSatisfy({ entry[$0] != nil }) else { return .failure(.katMissing) }
                if let want = c.expectedKAT[k], !c.surfaces.allSatisfy({ s in want[s].map { entry[s]?.string == $0 } ?? true }) { return .failure(.katMismatch) }
            }
        }
        return .success(level)
    }

    private static func shapeOK(_ o: [String: JSONValue], hostMax: Int) -> Bool {
        let fields: Set<String> = ["v", "kind", "suite", "workspace_id", "device_id", "dk_hash", "who", "reader", "kat", "bind", "created_ms"]
        guard Set(o.keys) == fields, o["v"] == .int(1), o["kind"] == "reader_decl", o["suite"] == .int(Int64(Suite2.id)),
              let ws = o["workspace_id"]?.string, ID16(hex: ws) != nil, let dev = o["device_id"]?.string, ID16(hex: dev) != nil,
              let dk = o["dk_hash"]?.string, B64U.decode(dk)?.count == 32, let who = o["who"]?.object, who.count == 1,
              let bind = o["bind"]?.object, let via = bind["via"]?.string, let kat = o["kat"]?.object else { return false }
        if let p = who["person_id"]?.string { guard ID16(hex: p) != nil else { return false } }
        else if let p = who["pk_pin"]?.string { guard B64U.decode(p)?.count == 32 else { return false } }
        else { return false }
        switch via {
        case "pair":
            guard Set(bind.keys) == ["via", "offer_id", "attempt"], let off = bind["offer_id"]?.string, ID16(hex: off) != nil,
                  let at = bind["attempt"]?.string, Identifiers.isAttempt(at) else { return false }
        case "declare": guard bind.count == 1 else { return false }
        default: return false
        }
        for (k, entry) in kat {
            let u = Array(k.utf8)
            guard !u.isEmpty, u[0] >= 0x31, u[0] <= 0x39, u.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let e = entry.object else { return false }
            guard let level = Int(k), level <= hostMax else { continue }
            guard !e.isEmpty, Set(e.keys).isSubset(of: ["log", "view"]), e.values.allSatisfy({ $0.string.map { F1ASCII.isHash($0) } ?? false }) else { return false }
        }
        return true
    }
}
