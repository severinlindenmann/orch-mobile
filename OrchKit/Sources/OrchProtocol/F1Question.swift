import CryptoKit
import Foundation

/// ASCII-only checks that compare bytes (Swift `==` is canonical equivalence, which equates U+212A with `K`).
enum F1ASCII {
    static func isULID(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count == 26, u[0] >= 0x30, u[0] <= 0x37 else { return false }
        return u.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A && c != 0x49 && c != 0x4C && c != 0x4F && c != 0x55)
        }
    }
    /// `<prefix>` followed by exactly 32 lower-case hex digits.
    static func isPrefixedHex32(_ s: String, prefix: String) -> Bool {
        let u = Array(s.utf8), p = Array(prefix.utf8)
        guard u.count == p.count + 32, u.starts(with: p) else { return false }
        return u.dropFirst(p.count).allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
    static func isHash(_ s: String) -> Bool {
        let u = Array(s.utf8), p = Array("sha256:".utf8)
        guard u.count == p.count + 64, u.starts(with: p) else { return false }
        return u.dropFirst(p.count).allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
    static func isHex32(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return u.count == 32 && u.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
    /// `Q<n>`, n a positive decimal without leading zeros.
    static func isQuestionID(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count >= 2, u.count <= 12, u[0] == 0x51, u[1] >= 0x31, u[1] <= 0x39 else { return false }
        return u.dropFirst().allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }
    /// Ticket key `[A-Z][A-Z0-9]{1,9}-[0-9]{4,}`.
    static func isTicketKey(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard let dash = u.firstIndex(of: 0x2D), dash >= 2, dash <= 10, u.count - dash - 1 >= 4 else { return false }
        let head = u[..<dash], tail = u[(dash + 1)...]
        guard let f = head.first, f >= 0x41, f <= 0x5A else { return false }
        return head.allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) } && tail.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }
    static func oneOf(_ s: String, _ options: [String]) -> String? { options.first { $0.bytesEqual(s) } }
}

/// The `auth` values of F1 section 11.4 (`AUTH_VALUES`). A value outside this list is refused when parsing a host view.
public enum F1Auth: String, Sendable, Equatable, CaseIterable {
    case passphrase
    case secureEnclave = "secure-enclave"
    case secureEnclaveUnlocked = "secure-enclave-unlocked"
    case convenience
    case webauthn
    case tpm
    case windowsHello = "windows-hello"

    init?(wire: String) {
        guard let raw = F1ASCII.oneOf(wire, F1Auth.allCases.map(\.rawValue)) else { return nil }
        self.init(rawValue: raw)
    }
}

public struct F1QuestionOption: Equatable, Sendable {
    public let key: String
    public let label: String
    public let cost: String?
    public init(key: String, label: String, cost: String? = nil) { self.key = key; self.label = label; self.cost = cost }

    /// `{key, label}` plus `cost` when present: exactly the hashed form (11A.14 14.5).
    var json: JSONValue {
        var o: [String: JSONValue] = ["key": .string(key), "label": .string(label)]
        if let cost { o["cost"] = .string(cost) }
        return .object(o)
    }
}

/// `questions[].answer` of `ticket.get` (host section 0.8, v1.5/v1.7 fields) with the H12d `signer {device, auth}` view field.
public struct F1Answer: Equatable, Sendable {
    public let by: String
    public let at: String
    public let seq: Int64
    public let option: String?
    public let text: String?
    public let auth: F1Auth?
    /// The id of the counting answer event (v1.7): a phone confirms its own landed answer by `id` == its event id.
    public let id: String
    public let signerDevice: String?
    public let signerAuth: F1Auth?
}

/// A question of `ticket.get` under the F1 values (host section 11A.14 14.5, F1 section 5.6). Not the v0 `Question` of the
/// host-api: the ticket is a uid, options are `{key, label, cost?}`, the hash is `sha256:` + hex.
///
/// Strictness has two levels. Question, answer and signer objects IGNORE unknown keys (host section 0.4: clients ignore unknown keys the
/// host sends), while every key the phone knows is validated strictly (required keys present, types, section 11.3 text, unknown `auth`
/// values refused). Option entries are CLOSED (`key`, `label`, `cost?` only): they are hashed into the question hash, so a key the
/// phone does not know would be bound content it never rendered, and the hash would not match what it shows.
public struct F1Question: Equatable, Sendable {
    public enum State: Sendable, Equatable { case open, answered, stale }

    public let id: String
    public let state: State
    public let to: [String]
    public let blocking: Bool
    public let answeredBy: String?
    public let answeredSeq: Int64?
    public let text: String?
    public let why: String?
    public let toRef: String?
    /// `ticket.get` omits the field when the question has no options: `[]` here, and `[]` in the hash.
    public let options: [F1QuestionOption]
    public let recommended: String?
    public let askedAt: String?
    public let askedSeq: Int64?
    public let answer: F1Answer?
    public let qid: String?
    public let hash: String?

    static let requiredKeys: Set<String> = ["id", "state", "to", "blocking", "answered_by", "answered_seq"]
    static let optionalKeys: Set<String> = ["text", "why", "to_ref", "options", "recommended", "asked_at", "asked_by", "asked_seq", "answer", "qid", "hash"]
    static let answerRequired: Set<String> = ["by", "at", "seq", "option", "text", "id"]
    static let answerOptional: Set<String> = ["auth", "signer"]

    public init(_ value: JSONValue) throws {
        guard let m = value.object, F1Question.keysOK(m, required: F1Question.requiredKeys, optional: F1Question.optionalKeys) else { throw Refusal.malformed }
        guard let id = m["id"]?.string, F1ASCII.isQuestionID(id),
              let stateRaw = m["state"]?.string, let st = F1ASCII.oneOf(stateRaw, ["open", "answered", "stale"]),
              let toArr = m["to"]?.array, let blocking = m["blocking"]?.bool else { throw Refusal.malformed }
        self.id = id
        state = st == "open" ? .open : (st == "answered" ? .answered : .stale)
        to = try toArr.map { v in
            guard let p = v.string, F1ASCII.isPrefixedHex32(p, prefix: "p_") else { throw Refusal.malformed }
            return p
        }
        self.blocking = blocking
        answeredBy = try F1Question.nullable(m["answered_by"]) { $0.string.flatMap { F1ASCII.isPrefixedHex32($0, prefix: "p_") ? $0 : nil } }
        answeredSeq = try F1Question.nullable(m["answered_seq"]) { $0.int.flatMap { $0 >= 0 && $0 <= maxSafeInt ? $0 : nil } }
        text = try F1Question.optionalText(m["text"], oneLine: false)
        why = try F1Question.optionalText(m["why"], oneLine: false)
        toRef = try F1Question.optionalText(m["to_ref"], oneLine: true)
        recommended = try F1Question.optionalText(m["recommended"], oneLine: true)
        askedAt = m["asked_at"]?.string
        if m["asked_at"] != nil, askedAt == nil { throw Refusal.malformed }
        if let a = m["asked_by"], a.object == nil { throw Refusal.malformed }
        if let s = m["asked_seq"] {
            guard let n = s.int, n >= 0, n <= maxSafeInt else { throw Refusal.malformed }
            askedSeq = n
        } else { askedSeq = nil }
        if let o = m["options"] {
            guard let arr = o.array else { throw Refusal.malformed }
            var opts: [F1QuestionOption] = []
            for item in arr { opts.append(try F1Question.parseOption(item)) }
            guard Set(opts.map { Array($0.key.utf8) }).count == opts.count else { throw Refusal.malformed }
            guard F1Question.labelsDistinct(opts) else { throw Refusal.malformed }
            options = opts
        } else { options = [] }
        if let r = recommended, !options.isEmpty, !options.contains(where: { $0.key.bytesEqual(r) }) { throw Refusal.malformed }
        if let q = m["qid"] {
            guard let s = q.string, F1ASCII.isHex32(s) else { throw Refusal.malformed }
            qid = s
        } else { qid = nil }
        if let h = m["hash"] {
            guard let s = h.string, F1ASCII.isHash(s) else { throw Refusal.malformed }
            hash = s
        } else { hash = nil }
        if let a = m["answer"] { answer = try F1Question.parseAnswer(a) } else { answer = nil }
        // answered <=> an answer and its counting event are shown (never for open or stale)
        guard (state == .answered) == (answer != nil) else { throw Refusal.malformed }
    }

    // MARK: parsing helpers

    /// Display safety of a signing surface: two options whose labels are the same after the phone's own NFC port (`F1Text.nfc`, never
    /// Foundation's) and case folding would look alike, so a question carrying them is refused. Keys are byte-unique separately.
    public static func labelsDistinct(_ options: [F1QuestionOption]) -> Bool {
        let folded = options.map { F1Text.nfc(F1Text.nfc($0.label).folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))) }
        return Set(folded.map { Array($0.utf8) }).count == options.count
    }

    /// `closed: false` ignores unknown keys (known keys are still checked by the callers); `closed: true` refuses them.
    private static func keysOK(_ m: [String: JSONValue], required: Set<String>, optional: Set<String>, closed: Bool = false) -> Bool {
        guard m.keys.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 < 0x80 } }) else { return false }
        let k = Set(m.keys)
        return required.isSubset(of: k) && (!closed || k.isSubset(of: required.union(optional)))
    }

    private static func nullable<T>(_ v: JSONValue?, _ f: (JSONValue) -> T?) throws -> T? {
        guard let v else { throw Refusal.malformed }
        if v.isNull { return nil }
        guard let r = f(v) else { throw Refusal.malformed }
        return r
    }

    private static func optionalText(_ v: JSONValue?, oneLine: Bool) throws -> String? {
        guard let v else { return nil }
        guard let s = v.string, (try? F1Text.check(s, oneLine: oneLine)) != nil else { throw Refusal.malformed }
        return s
    }

    private static func parseOption(_ v: JSONValue) throws -> F1QuestionOption {
        guard let o = v.object, keysOK(o, required: ["key", "label"], optional: ["cost"], closed: true),
              let key = o["key"]?.string, !key.isEmpty, (try? F1Text.check(key, oneLine: true)) != nil,
              let label = o["label"]?.string, !label.isEmpty, (try? F1Text.check(label, oneLine: true)) != nil else { throw Refusal.malformed }
        var cost: String?
        if let c = o["cost"] {
            guard let s = c.string, (try? F1Text.check(s, oneLine: true)) != nil else { throw Refusal.malformed }
            cost = s
        }
        return F1QuestionOption(key: key, label: label, cost: cost)
    }

    private static func parseAuth(_ v: JSONValue) throws -> F1Auth {
        guard let s = v.string, let a = F1Auth(wire: s) else { throw Refusal.malformed }
        return a
    }

    private static func parseAnswer(_ v: JSONValue) throws -> F1Answer {
        guard let a = v.object, keysOK(a, required: answerRequired, optional: answerOptional),
              let by = a["by"]?.string, F1ASCII.isPrefixedHex32(by, prefix: "p_"),
              let at = a["at"]?.string, let seq = a["seq"]?.int, seq >= 0, seq <= maxSafeInt,
              let id = a["id"]?.string, F1ASCII.isULID(id) else { throw Refusal.malformed }
        let option: String? = try nullable(a["option"]) { $0.string }
        let text: String? = try nullable(a["text"]) { $0.string.flatMap { (try? F1Text.check($0)) != nil ? $0 : nil } }
        let auth = try a["auth"].map(parseAuth)
        var dev: String?, sauth: F1Auth?
        if let s = a["signer"] {
            guard let so = s.object, keysOK(so, required: ["device", "auth"], optional: []),
                  let d = so["device"]?.string, F1ASCII.isPrefixedHex32(d, prefix: "d_"), let sa = so["auth"] else { throw Refusal.malformed }
            dev = d; sauth = try parseAuth(sa)
        }
        guard option != nil || text != nil else { throw Refusal.malformed }
        return F1Answer(by: by, at: at, seq: seq, option: option, text: text, auth: auth, id: id, signerDevice: dev, signerAuth: sauth)
    }

    // MARK: question id and hash (11A.14 14.5, F1 section 5.6)

    /// `qid = hex(SHA-256("orch/v2/question-id|" || cj({"question":"Q1","ticket":uid,"workspace_id":W}))[0:16])`.
    public static func questionID(question: String, ticketUID: String, workspace: ID16) throws -> String {
        guard F1ASCII.isQuestionID(question), F1ASCII.isULID(ticketUID) else { throw Refusal.malformed }
        let body = try canonicalJSON(["question": .string(question), "ticket": .string(ticketUID), "workspace_id": .string(workspace.hex)])
        return Hex.encode(SHA256.hash(data: Data(Label.hQuestionID.utf8) + body).prefix(16))
    }

    /// `hash = "sha256:" + hex(SHA-256("orch/v2/question|" || cj({"options":options, "question_id":qid, "text":text, "ticket":uid})))`.
    /// `options` is the list in asked order (`[]` when the question has none). Only `text` and `options` are bound.
    public static func questionHash(qid: String, ticketUID: String, text: String, options: [F1QuestionOption]) throws -> String {
        guard F1ASCII.isHex32(qid), F1ASCII.isULID(ticketUID) else { throw Refusal.malformed }
        // core refuses, never normalises, a string that breaks section 11.3 (hashes.json question_hash_refused)
        guard F1Text.isClean(text), options.allSatisfy({ F1Text.isClean($0.key, oneLine: true) && F1Text.isClean($0.label, oneLine: true)
            && ($0.cost.map { F1Text.isClean($0, oneLine: true) } ?? true) }) else { throw Refusal.malformed }
        let digest = try Decisions.contentHash(of: ["question_id": .string(qid), "ticket": .string(ticketUID), "text": .string(text),
                                                    "options": .array(options.map(\.json))])
        return "sha256:" + Hex.encode(digest)
    }

    /// What the phone shows and signs for a question: both values recomputed from the uid, the paired workspace id, the displayed text and
    /// options, and equal to the host's `qid` and `hash` (14.5). Anything else is refused: no sign sheet for a question the phone cannot
    /// reproduce. Requires `state == open`.
    public struct Reviewed: Equatable, Sendable {
        public let question: F1Question
        public let ticketUID: String
        public let qid: String
        public let hash: String
        public let text: String
        /// `ticket.get` -> `doc.head.head` (`based_on`) and `members_v` (`roster_v`), from the same snapshot as the question.
        public let basedOn: String
        public let rosterV: Int64
        fileprivate init(question: F1Question, ticketUID: String, qid: String, hash: String, text: String, basedOn: String, rosterV: Int64) {
            self.question = question; self.ticketUID = ticketUID; self.qid = qid; self.hash = hash; self.text = text
            self.basedOn = basedOn; self.rosterV = rosterV
        }
    }

    public func reviewed(ticketUID: String, workspace: ID16, basedOn: String, rosterV: Int64) throws -> Reviewed {
        guard F1ASCII.isHash(basedOn), rosterV >= 0, rosterV <= maxSafeInt else { throw Refusal.malformed }
        guard state == .open, let text, let hostQid = qid, let hostHash = hash else { throw Refusal.malformed }
        let myQid = try F1Question.questionID(question: id, ticketUID: ticketUID, workspace: workspace)
        let myHash = try F1Question.questionHash(qid: myQid, ticketUID: ticketUID, text: text, options: options)
        guard myQid.bytesEqual(hostQid), myHash.bytesEqual(hostHash) else { throw Refusal.malformed }
        return Reviewed(question: self, ticketUID: ticketUID, qid: myQid, hash: myHash, text: text, basedOn: basedOn, rosterV: rosterV)
    }
}
