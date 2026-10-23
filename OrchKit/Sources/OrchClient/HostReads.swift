import Foundation
import OrchProtocol

/// Typed results of the host reads the phone calls over column R (host section 0.8; the R2 table of 11A.5). Two levels of strictness, the
/// same split as `F1Question` (#74): every field the phone BINDS (a ticket uid, `doc.head`, `members_v`, a question's text and options, the
/// `next_key` a creation proposes) or DISPLAYS is required and type-checked, and an object that carries bound content is closed where the
/// hash covers it; every other key a host view carries is ignored (section 0.4: clients ignore unknown keys the host sends), because the
/// view is unsigned and nothing the phone does depends on what it does not read.
public enum HostReads {}

/// RFC 3339 UTC with a `Z` and whole or fractional seconds (`Time`, host section 0.1), as epoch milliseconds.
public enum HostTime {
    public static func ms(_ s: String) -> Int64? {
        let u = Array(s.utf8)
        guard u.count >= 20, u.last == 0x5A else { return nil }
        func num(_ range: Range<Int>) -> Int64? {
            var v: Int64 = 0
            for i in range { guard u[i] >= 0x30, u[i] <= 0x39 else { return nil }; v = v * 10 + Int64(u[i] - 0x30) }
            return v
        }
        guard u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x54, u[13] == 0x3A, u[16] == 0x3A,
              let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10), let h = num(11..<13), let mi = num(14..<16), let sec = num(17..<19),
              (1970...9999).contains(y), (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 61 else { return nil }
        var frac: Int64 = 0
        if u.count > 20 {
            guard u[19] == 0x2E, u.count >= 22, u.count <= 29 else { return nil }
            let digits = u[20..<(u.count - 1)]
            guard digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            var ms: Int64 = 0, n = 0
            for c in digits where n < 3 { ms = ms * 10 + Int64(c - 0x30); n += 1 }
            while n < 3 { ms *= 10; n += 1 }
            frac = ms
        } else { guard u.count == 20 else { return nil } }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let dim: [Int64] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard d <= dim[Int(mo) - 1] else { return nil }
        // days from civil (Howard Hinnant)
        let yy = mo <= 2 ? y - 1 : y
        let era = yy / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return ((days * 24 + h) * 60 + mi) * 60_000 + min(sec, 59) * 1000 + frac
    }
}

/// Field readers over one JSON object (`ViewError.malformed` on anything the phone depends on being wrong).
struct ViewObject {
    let o: [String: JSONValue]
    init(_ v: JSONValue?) throws {
        guard let o = v?.object, o.keys.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 < 0x80 } }) else { throw ViewError.malformed }
        self.o = o
    }
    func has(_ k: String) -> Bool { o[k] != nil }
    func value(_ k: String) throws -> JSONValue { guard let v = o[k] else { throw ViewError.malformed }; return v }
    func str(_ k: String) throws -> String { guard let s = o[k]?.string else { throw ViewError.malformed }; return s }
    func nullableStr(_ k: String) throws -> String? {
        guard let v = o[k] else { throw ViewError.malformed }
        if v.isNull { return nil }
        guard let s = v.string else { throw ViewError.malformed }
        return s
    }
    /// Absent or null is nil; anything else must be a string.
    func optStr(_ k: String) throws -> String? {
        guard let v = o[k], !v.isNull else { return nil }
        guard let s = v.string else { throw ViewError.malformed }
        return s
    }
    func int(_ k: String, _ range: ClosedRange<Int64> = 0...maxSafeInt) throws -> Int64 {
        guard let n = o[k]?.int, range.contains(n) else { throw ViewError.malformed }
        return n
    }
    func optInt(_ k: String, _ range: ClosedRange<Int64> = 0...maxSafeInt) throws -> Int64? {
        guard let v = o[k], !v.isNull else { return nil }
        guard let n = v.int, range.contains(n) else { throw ViewError.malformed }
        return n
    }
    func bool(_ k: String) throws -> Bool { guard let b = o[k]?.bool else { throw ViewError.malformed }; return b }
    func optBool(_ k: String) throws -> Bool? {
        guard let v = o[k], !v.isNull else { return nil }
        guard let b = v.bool else { throw ViewError.malformed }
        return b
    }
    func array(_ k: String) throws -> [JSONValue] { guard let a = o[k]?.array else { throw ViewError.malformed }; return a }
    func strings(_ k: String) throws -> [String] {
        try array(k).map { guard let s = $0.string else { throw ViewError.malformed }; return s }
    }
    func time(_ k: String) throws -> Int64 { guard let t = HostTime.ms(try str(k)) else { throw ViewError.malformed }; return t }
    func optTime(_ k: String) throws -> Int64? {
        guard let s = try optStr(k) else { return nil }
        guard let t = HostTime.ms(s) else { throw ViewError.malformed }
        return t
    }
}

/// ASCII shape checks over bytes (the F1 ones in OrchProtocol are internal to it).
enum ViewShape {
    static func isULID(_ s: String) -> Bool { ULID.isValid(s) }
    static func isPrefixedHex32(_ s: String, prefix: String) -> Bool {
        let u = Array(s.utf8), p = Array(prefix.utf8)
        guard u.count == p.count + 32, u.starts(with: p) else { return false }
        return u.dropFirst(p.count).allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
    static func isHex32(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return u.count == 32 && u.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
    static func isHash(_ s: String) -> Bool { R2.isDigest(s) }
    /// `Q<n>`, n a positive decimal without leading zeros.
    static func isQuestionID(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count >= 2, u.count <= 12, u[0] == 0x51, u[1] >= 0x31, u[1] <= 0x39 else { return false }
        return u.dropFirst().allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }
}

private func personID(_ s: String) -> Bool { ViewShape.isPrefixedHex32(s, prefix: "p_") }
private func deviceID(_ s: String) -> Bool { ViewShape.isPrefixedHex32(s, prefix: "d_") }

// MARK: needs

public struct NeedItem: Equatable, Sendable {
    public enum Kind: String, Sendable { case question, approve, noEligible = "no_eligible", acknowledge, addon }
    public enum Payload: Equatable, Sendable {
        /// No options here: a question's options are bound into its hash, so they are read only from `ticket.get` through `F1Question` (never from a needs item).
        case question(id: String, blocking: Bool, to: String, recommended: String?, why: String?)
        case approve(gate: String, gen: Int64, count: Int64, have: Int64)
        case noEligible(gate: String, cause: String)
        case acknowledge(scope: String)
        case addon(addon: String, rule: String)
    }
    public let kind: Kind
    public let key: String?
    public let uid: String?
    public let ref: String?
    public let detail: String
    public let who: [String]
    public let sinceMs: Int64?
    public let text: String?
    public let textCut: Bool
    public let status: String?
    public let payload: Payload?
}

/// `needs` (read): `{items:[NeedItem], sub_cursor}`. An item of a kind this phone does not know is left out (a later host may add one);
/// an item of a known kind that does not parse fails the read.
public struct NeedsResult: Equatable, Sendable {
    public let items: [NeedItem]
    public let subCursor: String

    init(_ data: JSONValue) throws {
        let o = try ViewObject(data)
        subCursor = try Self.cursor(o)
        var items: [NeedItem] = []
        for v in try o.array("items") {
            let i = try ViewObject(v)
            guard let kind = NeedItem.Kind(rawValue: try i.str("kind")) else { continue }
            let key = try i.nullableStr("key"), uid = try i.nullableStr("uid"), ref = try i.nullableStr("ref")
            if let k = key { guard validTicketKey(k) else { throw ViewError.malformed } }
            if let u = uid { guard ViewShape.isULID(u) else { throw ViewError.malformed } }
            guard (key == nil) == (uid == nil) else { throw ViewError.malformed }
            let who = try i.strings("who")
            guard who.allSatisfy(personID) else { throw ViewError.malformed }
            var payload: NeedItem.Payload?
            if let pv = i.o["payload"] {
                let p = try ViewObject(pv)
                switch kind {
                case .question:
                    payload = .question(id: try p.str("question"), blocking: try p.bool("blocking"), to: try p.str("to"),
                                        recommended: try p.optStr("recommended"), why: try p.optStr("why"))
                case .approve: payload = .approve(gate: try p.str("gate"), gen: try p.int("gen"), count: try p.int("count"), have: try p.int("have"))
                case .noEligible: payload = .noEligible(gate: try p.str("gate"), cause: try p.str("cause"))
                case .acknowledge: payload = .acknowledge(scope: try i.o["payload"].flatMap { try ViewObject($0).str("scope") } ?? "")
                case .addon: payload = .addon(addon: try p.str("addon"), rule: try p.str("rule"))
                }
            }
            if kind == .question {
                guard key != nil, let ref, ViewShape.isQuestionID(ref), case .question(let qid, _, _, _, _)? = payload, qid.bytesEqual(ref) else { throw ViewError.malformed }
            }
            items.append(NeedItem(kind: kind, key: key, uid: uid, ref: ref, detail: try i.str("detail"), who: who, sinceMs: try i.optTime("since"),
                                  text: try i.optStr("text"), textCut: try i.optBool("text_cut") ?? false, status: try i.optStr("status"), payload: payload))
        }
        self.items = items
    }

    static func cursor(_ o: ViewObject) throws -> String {
        let c = try o.str("sub_cursor")
        guard (1...256).contains(c.utf8.count) else { throw ViewError.malformed }
        return c
    }
}

// MARK: ticket.query

public struct TicketRow: Equatable, Sendable {
    public let key: String
    public let uid: String
    public let title: String
    public let type: String
    public let status: String
    public let parent: String?
    public let epic: String?
    public let updatedMs: Int64
    public let headSeq: Int64
    public let restricted: Bool
    public let blockingQuestions: Int64?
}

/// `ticket.query` (read): `{rows, next_page, total, sub_cursor, as_of}`.
public struct TicketPage: Equatable, Sendable {
    public let rows: [TicketRow]
    public let nextPage: String?
    public let total: Int64
    public let subCursor: String
    public let asOfMs: Int64

    init(_ data: JSONValue) throws {
        let o = try ViewObject(data)
        var rows: [TicketRow] = []
        for v in try o.array("rows") {
            let r = try ViewObject(v)
            let key = try r.str("key"), uid = try r.str("uid")
            guard validTicketKey(key), ViewShape.isULID(uid) else { throw ViewError.malformed }
            let parent = try r.nullableStr("parent"), epic = try r.nullableStr("epic")
            for k in [parent, epic] { if let k { guard validTicketKey(k) else { throw ViewError.malformed } } }
            rows.append(TicketRow(key: key, uid: uid, title: try r.str("title"), type: try r.str("type"), status: try r.str("status"), parent: parent,
                                  epic: epic, updatedMs: try r.time("updated_at"), headSeq: try r.int("head_seq"),
                                  restricted: try r.optBool("restricted") ?? false, blockingQuestions: try r.optInt("blocking_questions")))
        }
        guard Set(rows.map(\.uid)).count == rows.count else { throw ViewError.malformed }
        self.rows = rows
        nextPage = try o.nullableStr("next_page")
        if let p = nextPage { guard (1...512).contains(p.utf8.count) else { throw ViewError.malformed } }
        total = try o.int("total")
        subCursor = try NeedsResult.cursor(o)
        asOfMs = try o.time("as_of")
    }
}

// MARK: ticket.get

/// One entry of `ticket.get` `questions`: parsed under #74's `F1Question` rules, or refused (never rendered, never signable). A bad entry
/// does not take the other questions of the ticket with it.
public enum TicketQuestion: Equatable, Sendable {
    case question(F1Question)
    /// The entry does not parse, has a kind or key this iPhone does not know, or breaks a limit: shown as "cannot verify" with `reason`,
    /// never answerable. The ticket and its other questions stay.
    case unreadable(id: String?, reason: String)
    public var question: F1Question? { if case .question(let q) = self { return q }; return nil }
}

/// `ticket.get` (read), the fields the phone reads: `doc.{uid,key,title,type,status,head}`, `questions`, `members_v`, `sub_cursor`.
public struct TicketGet: Equatable, Sendable {
    public let uid: String
    public let key: String
    public let title: String
    public let type: String
    public let status: String
    public let headSeq: Int64
    public let headHash: String
    public let owner: String?
    public let questions: [TicketQuestion]
    public let membersV: Int64
    public let subCursor: String
    /// B10: `doc.sections` (section id -> text), the texts a gate's section hashes are recomputed from; nil when absent or not strings
    /// (then no gate review can be built from this read).
    public let sections: [String: String]?
    /// B10: `gates.<gate>` as far as the phone reads it (the host's word, except what `gate.input` lets it recompute).
    public let gates: [String: TicketGateInfo]

    init(_ data: JSONValue) throws {
        let o = try ViewObject(data)
        let d = try ViewObject(o.value("doc"))
        uid = try d.str("uid"); key = try d.str("key")
        guard ViewShape.isULID(uid), validTicketKey(key) else { throw ViewError.malformed }
        title = try d.str("title"); type = try d.str("type"); status = try d.str("status")
        owner = try d.optStr("owner")
        let head = try ViewObject(d.value("head"))
        headSeq = try head.int("seq"); headHash = try head.str("head")
        guard ViewShape.isHash(headHash) else { throw ViewError.malformed }
        membersV = try o.int("members_v")
        subCursor = try NeedsResult.cursor(o)
        var qs: [TicketQuestion] = []
        for v in try o.array("questions") {
            do { qs.append(.question(try F1Question(v))) } catch {
                let reason = (error as? F1QuestionRefusal)?.reason ?? "the host's view of this question is not one this iPhone can read"
                qs.append(.unreadable(id: v.object?["id"]?.string, reason: reason))
            }
        }
        let ids = qs.compactMap { $0.question?.id }
        guard Set(ids.map { Array($0.utf8) }).count == ids.count else { throw ViewError.malformed }
        questions = qs
        if let so = d.o["sections"]?.object, so.allSatisfy({ $0.value.string != nil }) {
            sections = so.mapValues { $0.string ?? "" }
        } else { sections = nil }
        var gs: [String: TicketGateInfo] = [:]
        for (name, v) in o.o["gates"]?.object ?? [:] { if let g = TicketGateInfo(v) { gs[name] = g } }
        gates = gs
    }
}

/// One decision of a gate, as `ticket.get` `gates.<gate>.decisions` lists it (B10: how a landed approval is found in the log).
public struct GateDecisionRef: Equatable, Sendable {
    public let id: String
    public let kind: String
    public let person: String
    public let seq: Int64
    public let gen: Int64
}

/// `ticket.get` `gates.<gate>`: lenient (a gate it cannot read is simply absent). Everything here is the host's word.
public struct TicketGateInfo: Equatable, Sendable {
    public let gen: Int64?
    public let applies: Bool?
    public let state: String?
    public let policy: JSONValue?
    public let decisions: [GateDecisionRef]

    init?(_ v: JSONValue) {
        guard let o = v.object else { return nil }
        gen = o["gen"]?.int
        applies = o["applies"]?.bool
        state = o["state"]?.string
        policy = o["policy"]
        decisions = (o["decisions"]?.array ?? []).compactMap { d in
            guard let x = d.object, let id = x["id"]?.string, let k = x["kind"]?.string, let p = x["person"]?.string, let seq = x["seq"]?.int,
                  let gen = x["gen"]?.int else { return nil }
            return GateDecisionRef(id: id, kind: k, person: p, seq: seq, gen: gen)
        }
    }

    /// The policy in words (host `signcontent.policy_words`); a policy with a key it does not know is shown as its JSON. Per host, not signed.
    public var policyWords: String? {
        guard let p = policy?.object else { return nil }
        guard Set(p.keys).isSubset(of: ["approvers", "count", "not", "applies", "independent"]) else {
            return (try? canonicalJSON(policy ?? .null)).map { GateReview.oneLine(String(decoding: $0, as: UTF8.self)) }
        }
        func list(_ k: String) -> [String] { (p[k]?.array ?? []).compactMap(\.string) }
        let n = p["count"]?.int ?? 0
        var out = "\(n) approval\(n == 1 ? "" : "s") from \(list("approvers").isEmpty ? "nobody" : list("approvers").joined(separator: ", "))"
        if !list("not").isEmpty { out += "; not by \(list("not").joined(separator: ", "))" }
        let applies = p["applies"]?.string ?? "?"
        out += "; applies to " + (applies == "all" ? "all tickets" : applies == "off" ? "no ticket" : applies)
        if p["independent"]?.bool == true { out += "; approvers independent of the author" }
        return GateReview.oneLine(out)
    }
}

// MARK: phone.requests, gate.input (B10)

/// One open approval hint from `phone.requests` (core #628): the host's word, unsigned. `ref` (the key), `title` and `gateGen` are not
/// proven by anything; a request grants no authority and is not needed to sign.
public struct PhoneRequest: Equatable, Sendable, Identifiable {
    public let id: String
    public let uid: String
    public let ref: String
    public let title: String
    public let gate: String
    public let gateGen: Int64
    public let createdMs: Int64
    public let expiresMs: Int64
    public init(id: String, uid: String, ref: String, title: String, gate: String, gateGen: Int64, createdMs: Int64, expiresMs: Int64) {
        self.id = id; self.uid = uid; self.ref = ref; self.title = title; self.gate = gate; self.gateGen = gateGen
        self.createdMs = createdMs; self.expiresMs = expiresMs
    }
}

/// `phone.requests` (read, column R): `{requests:[{id, uid, ref, title, gate, gate_gen, created_at, expires_at}], now}`. A request that is
/// not for a phone gate, or has a bad id, is dropped (it could never be reviewed); the shape of the rest is strict.
public struct PhoneRequestsResult: Equatable, Sendable {
    public let requests: [PhoneRequest]
    public let nowMs: Int64
    public static let hintPrefix = "ph_"

    init(_ data: JSONValue) throws {
        let o = try ViewObject(data)
        var out: [PhoneRequest] = []
        for v in try o.array("requests") {
            let r = try ViewObject(v)
            let id = try r.str("id"), uid = try r.str("uid"), ref = try r.str("ref"), gate = try r.str("gate")
            guard id.hasPrefix(Self.hintPrefix), ULID.isValid(String(id.dropFirst(3))), ViewShape.isULID(uid), validTicketKey(ref) else { throw ViewError.malformed }
            guard GateReview.isPhoneGate(gate) else { continue }
            out.append(PhoneRequest(id: id, uid: uid, ref: ref, title: try r.str("title"), gate: gate, gateGen: try r.int("gate_gen"),
                                    createdMs: try r.time("created_at"), expiresMs: try r.time("expires_at")))
        }
        guard Set(out.map(\.id)).count == out.count, out.count <= 64 else { throw ViewError.malformed }
        requests = out
        nowMs = try o.time("now")
    }
}

/// `gate.input {ref, gate}` (read): `{ref:uid, gate, gen, hash, policy_hash, input}`. All of it is the host's claim until `GateReview.verify`
/// recomputes it. A gate that cannot be hashed now answers an `invalid.input` ERROR (not nulls); nulls are refused here as well.
public struct GateInputResult: Equatable, Sendable {
    public let uid: String
    public let gate: String
    public let gen: Int64
    public let hash: String
    public let policyHash: String
    public let input: JSONValue

    init(_ data: JSONValue) throws {
        let o = try ViewObject(data)
        uid = try o.str("ref"); gate = try o.str("gate"); gen = try o.int("gen")
        guard ViewShape.isULID(uid), let h = try o.optStr("hash"), let ph = try o.optStr("policy_hash"), ViewShape.isHash(h), ViewShape.isHash(ph),
              let input = o.o["input"], input.object != nil else { throw ViewError.malformed }
        hash = h; policyHash = ph; self.input = input
    }
}

// MARK: member.list, workspace.show

public struct MemberDevice: Equatable, Sendable {
    public let id: String
    public let auth: String?
    public let scopes: [String]
    public let valid: Bool
    public let label: String?
    public let pairedMs: Int64?
    public let relay: Bool?
    public let certExpiresMs: Int64?
    public let reader: Int64?
}
public struct HostMember: Equatable, Sendable {
    public let person: String
    public let name: String
    public let role: String
    public let devices: [MemberDevice]
}
/// `member.list` (read): `{members:[{person, name, role, devices:[...]}], required_reader}`.
public struct MemberListResult: Equatable, Sendable {
    public let members: [HostMember]
    public let requiredReader: Int64?

    init(_ data: JSONValue) throws {
        let o = try ViewObject(data)
        var members: [HostMember] = []
        for v in try o.array("members") {
            let m = try ViewObject(v)
            let person = try m.str("person")
            guard personID(person) else { throw ViewError.malformed }
            var devices: [MemberDevice] = []
            for dv in try m.array("devices") {
                let d = try ViewObject(dv)
                let id = try d.str("id")
                guard deviceID(id) else { throw ViewError.malformed }
                devices.append(MemberDevice(id: id, auth: try d.optStr("auth"), scopes: try d.strings("scopes"), valid: try d.bool("valid"),
                                            label: try d.optStr("label"), pairedMs: try d.optTime("paired_at"), relay: try d.optBool("relay"),
                                            certExpiresMs: try d.optTime("cert_expires_at"), reader: try d.optInt("reader")))
            }
            members.append(HostMember(person: person, name: try m.str("name"), role: try m.str("role"), devices: devices))
        }
        self.members = members
        requiredReader = try o.optInt("required_reader", 0...1)
    }
}

/// `workspace.show` (read): `{id, prefix, name, genesis, epoch, wsk_fingerprint, members_v, state, next_key, required_reader}`.
/// `next_key` is advisory (never a reservation); `null` for a principal that may not create a ticket.
public struct WorkspaceShowResult: Equatable, Sendable {
    public let id: String
    public let prefix: String
    public let name: String
    public let genesis: String
    public let epoch: Int64
    public let membersV: Int64
    public let state: String
    public let nextKey: String?
    public let requiredReader: Int64?

    init(_ data: JSONValue) throws {
        let o = try ViewObject(data)
        id = try o.str("id"); prefix = try o.str("prefix"); name = try o.str("name"); genesis = try o.str("genesis")
        guard ViewShape.isHex32(id), ViewShape.isHash(genesis) else { throw ViewError.malformed }
        epoch = try o.int("epoch"); membersV = try o.int("members_v")
        let st = try o.str("state")
        guard ["ok", "degraded"].contains(where: { $0.bytesEqual(st) }) else { throw ViewError.malformed }
        state = st
        // `next_key` is sent by every v1.7 host; absent means a host that does not propose keys: nil, never an error
        let nk = try o.optStr("next_key")
        if let nk { guard (1...64).contains(nk.utf8.count), validTicketKey(nk) else { throw ViewError.malformed } }
        nextKey = nk
        requiredReader = try o.optInt("required_reader", 0...1)
    }
}

// MARK: activity.list

public struct ActivityEntry: Equatable, Sendable {
    public let id: String
    public let jpos: Int64
    public let log: String
    public let key: String?
    public let seq: Int64
    public let type: String
    public let atMs: Int64
}
/// `activity.list` (read): `{items, next_page, sub_cursor, as_of}`. The phone reads the cursor and the newest `jpos` only (change
/// detection by polling: `wait` is not served on the relay).
public struct ActivityPage: Equatable, Sendable {
    public let items: [ActivityEntry]
    public let nextPage: String?
    public let subCursor: String
    public let asOfMs: Int64

    init(_ data: JSONValue) throws {
        let o = try ViewObject(data)
        var items: [ActivityEntry] = []
        for v in try o.array("items") {
            let i = try ViewObject(v)
            items.append(ActivityEntry(id: try i.str("id"), jpos: try i.int("jpos"), log: try i.str("log"), key: try i.optStr("key"), seq: try i.int("seq"),
                                       type: try i.str("type"), atMs: try i.time("at")))
        }
        self.items = items
        nextPage = try o.nullableStr("next_page")
        subCursor = try NeedsResult.cursor(o)
        asOfMs = try o.time("as_of")
    }
}

// MARK: whoami, outcome.get, reader.list

/// `whoami` (host 0.8: `{peer, person, tier, grant, session}`). Display data of an unsigned view: it never grants a scope or changes trust. Every
/// field is optional.
public struct WhoAmIResult: Equatable, Sendable {
    public let person: String?
    public let tier: String?
    /// Column-R `whoami.relay` (host changelog 57): which person-event writes the host serves and the live R6 gate. Lenient: absent or
    /// malformed is nil and never fails the read. Read-only display input to `HostWriteSupport`; it grants nothing by itself.
    public let relay: HostWriteSupport?
    init(_ data: JSONValue) throws {
        let o = try ViewObject(data)
        person = try o.optStr("person")
        tier = try o.optStr("tier")
        relay = HostWriteSupport(o.o["relay"])
    }
}

/// What the host says it takes from this phone: `relay:{ops:{<kind>:<version>}, r6_ready:bool}`. Held in memory by the session only (never
/// persisted), refreshed per `startViews`, per foreground and per epoch change, and cleared on any failure (fail closed).
public struct HostWriteSupport: Equatable, Sendable {
    public let ops: [String: Int64]
    public let r6Ready: Bool
    /// `relay.dev` (host 11A.17): present only while the host's dev gate passes for this workspace. nil for anything else (absent, `false`,
    /// non-bool, a bad sandbox id, a non-object): the lane stays off and nothing else about the read changes. Display/UX input only; core
    /// admission is the gate.
    public let dev: RelayDevSignal?

    public init(ops: [String: Int64], r6Ready: Bool, dev: RelayDevSignal? = nil) { self.ops = ops; self.r6Ready = r6Ready; self.dev = dev }

    /// nil for anything but `{ops: {string: int}, r6_ready: bool}`. Unknown keys and unknown ops are ignored; a malformed op value drops that op only.
    init?(_ v: JSONValue?) {
        guard let o = v?.object, let opsObject = o["ops"]?.object, let ready = o["r6_ready"]?.bool else { return nil }
        var ops: [String: Int64] = [:]
        for (k, n) in opsObject { if let i = n.int { ops[k] = i } }
        self.ops = ops
        r6Ready = ready
        dev = RelayDevSignal(o["dev"])
    }

    /// A write of `kind` is accepted only at version 1 and while R6 is ready.
    public func allows(_ kind: String) -> Bool { r6Ready && ops[kind] == 1 }
}

/// `whoami.relay.dev` = `{sim_convenience:true, sandbox:"<id8>"}` (host 11A.17.2). Lenient: only exactly that shape counts.
public struct RelayDevSignal: Equatable, Sendable {
    /// Eight lower-case hex digits.
    public let sandbox: String

    public init?(sandbox: String) {
        guard sandbox.utf8.count == 8, sandbox.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        self.sandbox = sandbox
    }

    init?(_ v: JSONValue?) {
        guard let o = v?.object, o["sim_convenience"]?.bool == true, let id = o["sandbox"]?.string else { return nil }
        self.init(sandbox: id)
    }
}

/// `outcome.get {idem}` (11A.5, host 0.7): the host's record of a write, or `pending`. `failed` without `seqs` means nothing landed:
/// classify by `error.code`, never by the state.
public struct OutcomeResult: Equatable, Sendable {
    public enum State: String, Sendable { case pending, committed, failed, partial }
    public let state: State
    public let exit: Int64?
    public let errorCode: String?
    public let seqs: [Int64]?
    public let result: JSONValue?

    init(_ data: JSONValue) throws {
        let o = try ViewObject(data)
        guard let s = State(rawValue: try o.str("state")) else { throw ViewError.malformed }
        state = s
        if s == .pending {
            exit = nil; errorCode = nil; seqs = nil; result = nil
            return
        }
        exit = try o.int("exit", 0...9)
        errorCode = try o.o["error"].flatMap { v in v.isNull ? nil : try ViewObject(v).str("code") }
        result = o.o["result"]
        if let a = o.o["seqs"] {
            guard let arr = a.array, !arr.isEmpty, arr.count <= 1024 else { throw ViewError.malformed }
            seqs = try arr.map { guard let n = $0.int, n >= 1, n <= maxSafeInt else { throw ViewError.malformed }; return n }
        } else { seqs = nil }
        if s == .committed { guard result != nil else { throw ViewError.malformed } }
        if s != .committed { guard errorCode != nil else { throw ViewError.malformed } }
    }
}

/// `reader.list` as column R gets it (host 0.8.6 item 9.11, #513): `{readers:[{device, person, reader, level}], required_reader}`, no
/// `decl` and no `dk_hash`. NOT in the R2 closed op table: the phone does not call it yet (a call would be `forbidden_scope`); the
/// parser is here for when the host serves it.
public struct ReaderListResult: Equatable, Sendable {
    public struct Reader: Equatable, Sendable { public let device: String, person: String; public let reader: Int64, level: Int64 }
    public let readers: [Reader]
    public let requiredReader: Int64

    public init(_ data: JSONValue) throws {
        let o = try ViewObject(data)
        readers = try o.array("readers").map { v in
            let r = try ViewObject(v)
            let d = try r.str("device"), p = try r.str("person")
            guard deviceID(d), personID(p) else { throw ViewError.malformed }
            return Reader(device: d, person: p, reader: try r.int("reader"), level: try r.int("level"))
        }
        requiredReader = try o.int("required_reader", 0...1)
    }
}
