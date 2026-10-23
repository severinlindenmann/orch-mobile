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

/// One `[label, value]` fact of an option (arrays only: an object form is refused).
public struct F1Fact: Equatable, Sendable {
    public let label: String
    public let value: String
    public init(label: String, value: String) { self.label = label; self.value = value }
    var json: JSONValue { .array([.string(label), .string(value)]) }
}

/// One option of a `choice` question: `{key, label, text?, facts?, cost?}` (design #1123 rev 4 section 2). The hash binds the option
/// VERBATIM (`F1Question.Content.optionsWire`); these are its parsed fields, which a signing surface shows. `label` is the title.
public struct F1QuestionOption: Equatable, Sendable {
    public let key: String
    public let label: String
    public let text: String?
    public let facts: [F1Fact]
    public let cost: String?
    public init(key: String, label: String, cost: String? = nil, text: String? = nil, facts: [F1Fact] = []) {
        self.key = key; self.label = label; self.cost = cost; self.text = text; self.facts = facts
    }

    /// The option as core writes it: absent is the only "none" (no empty `facts`).
    public var json: JSONValue {
        var o: [String: JSONValue] = ["key": .string(key), "label": .string(label)]
        if let text { o["text"] = .string(text) }
        if !facts.isEmpty { o["facts"] = .array(facts.map(\.json)) }
        if let cost { o["cost"] = .string(cost) }
        return .object(o)
    }
}

/// The kinds of the closed registry (`canon/question.py KINDS`). A kind this phone does not know is "cannot verify", never a guess.
public enum F1QuestionKind: String, Sendable, Equatable, CaseIterable { case choice, text }

/// A question that does not parse, has a kind or key the phone does not know, or breaks a limit. It is shown as "cannot verify" with
/// `reason` (a plain sentence naming the field), never answerable; the ticket stays.
public struct F1QuestionRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable, Equatable { case malformed, unknownKind, unknownKey, text, option, facts, spec, hashMismatch }
    public let code: Code
    public let reason: String
    public var description: String { reason }
    init(_ code: Code, _ reason: String) { self.code = code; self.reason = reason }
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

/// A question of `ticket.get` under the F1 values (host section 11A.14 14.5, F1 section 5.6, design #1123 rev 4). The ticket is a uid and
/// the hash is `sha256:` + hex over the RAW question: `{question_id, ticket, text, options or [], spec}` where `options` and `spec` are
/// exactly as the host sent them (`Content.optionsWire`, `Content.specWire`); the phone never rebuilds `spec` from other keys.
///
/// Strictness has two levels. Question, answer and signer objects IGNORE unknown top-level keys (host section 0.4), while every key the
/// phone knows is validated strictly. `text`, `options` and `spec` are HASHED content, so they are CLOSED: a key or kind the phone does
/// not know would be bound content it never rendered, and the question becomes "cannot verify" (`F1QuestionRefusal`).
public struct F1Question: Equatable, Sendable {
    public enum State: Sendable, Equatable { case open, answered, stale }

    /// Limits of `canon/question.py LIMITS`: (min, max) in scalars or items; every string is also at most 4096 UTF-8 bytes.
    enum Limit {
        static let question = 140, label = 60, optionText = 200, cost = 60, factLabel = 24, factValue = 40, details = 1500, why = 4096, answer = 1000
        static let options = 2...6, facts = 1...3, key = 32
    }

    /// The hashed content of a question: parsed fields for display, and the verbatim `options` and `spec` the hash binds.
    public struct Content: Equatable, Sendable {
        public let kind: F1QuestionKind
        public let text: String
        public let why: String?
        public let details: String?
        public let recommended: String?
        public let allowOther: Bool
        public let options: [F1QuestionOption]
        /// `options` as received (`.array`, `[]` when absent) and `spec` as received (`.object`): what the hash covers.
        public let optionsWire: JSONValue
        public let specWire: JSONValue

        /// Parses and validates `text`, `options` and `spec` as `validate_question` does. `options` is absent for a `text` question.
        public init(text textValue: JSONValue?, options optionsValue: JSONValue?, spec specValue: JSONValue?) throws {
            func plain(_ v: JSONValue?, _ what: String, oneLine: Bool, limit: Int, code: F1QuestionRefusal.Code = .text) throws -> String {
                guard let s = v?.string else { throw F1QuestionRefusal(code, "\(what) is missing or not text") }
                do { try F1Text.checkPlain(s, oneLine: oneLine, limit: limit) } catch { throw F1QuestionRefusal(code, "\(what) breaks the text rules") }
                return s
            }
            guard let spec = specValue?.object else { throw F1QuestionRefusal(.malformed, "the question has no spec") }
            guard spec.keys.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 < 0x80 } }) else { throw F1QuestionRefusal(.unknownKey, "a spec key is not ASCII") }
            guard let kindRaw = spec["kind"]?.string else { throw F1QuestionRefusal(.unknownKind, "the question has no kind") }
            guard let kindName = F1ASCII.oneOf(kindRaw, F1QuestionKind.allCases.map(\.rawValue)), let kind = F1QuestionKind(rawValue: kindName) else {
                throw F1QuestionRefusal(.unknownKind, "this question has a kind this iPhone does not know")
            }
            let allowed: Set<String> = kind == .choice ? ["kind", "why", "details", "recommended", "allow_other"] : ["kind", "why", "details"]
            // never echo host text into a reason: the UI shows it
            if spec.keys.contains(where: { !allowed.contains($0) }) { throw F1QuestionRefusal(.unknownKey, "the question carries a key this iPhone does not know") }
            let text = try plain(textValue, "the question", oneLine: false, limit: Limit.question)
            let why = try spec["why"].map { try plain($0, "why", oneLine: false, limit: Limit.why, code: .spec) }
            let details = try spec["details"].map { try plain($0, "details", oneLine: false, limit: Limit.details, code: .spec) }
            var options: [F1QuestionOption] = [], recommended: String?, allowOther = false
            switch kind {
            case .text:
                // a text question has no options: absent is the only "none" (`[]` would be a second encoding)
                guard optionsValue == nil else { throw F1QuestionRefusal(.option, "a text question has no options") }
            case .choice:
                guard let arr = optionsValue?.array, Limit.options.contains(arr.count) else { throw F1QuestionRefusal(.option, "a choice question has 2 to 6 options") }
                for (i, item) in arr.enumerated() { options.append(try Content.parseOption(item, index: i)) }
                guard Set(options.map { Array($0.key.utf8) }).count == options.count else { throw F1QuestionRefusal(.option, "two options have the same key") }
                guard Set(options.map { Array(F1Text.fold($0.label).utf8) }).count == options.count else { throw F1QuestionRefusal(.option, "two options have the same title") }
                if let r = spec["recommended"] {
                    guard let key = r.string, options.contains(where: { $0.key.bytesEqual(key) }) else { throw F1QuestionRefusal(.spec, "recommended is not an option key") }
                    recommended = key
                }
                if let a = spec["allow_other"] {
                    guard a == .bool(true) else { throw F1QuestionRefusal(.spec, "allow_other is true or absent") }
                    allowOther = true
                }
            }
            self.kind = kind; self.text = text; self.why = why; self.details = details; self.recommended = recommended; self.allowOther = allowOther
            self.options = options; optionsWire = optionsValue ?? .array([]); specWire = .object(spec)
        }

        /// The answer rule of the kind (core `validate_answer`): choice = an `option` (a `text` is then only a note that never replaces
        /// it) or, with `allow_other`, a `text` alone; text = a `text` alone. A text is 1..1000 scalars and plain. Checks the text as given
        /// (never normalises): phone-authored text goes through `PhoneEvents.prepareText` first.
        /// Until the phone renders every hash-bound field (D-mob-2), a question is answerable only when it has nothing the current screens
        /// do not show: a plain choice question (no details, no why, no recommendation, no option text or facts). D-mob-2 widens this.
        public var phoneShowsEverything: Bool {
            kind == .choice && details == nil && why == nil && recommended == nil && options.allSatisfy { $0.text == nil && $0.facts.isEmpty }
        }

        /// The constant reason for any other open question.
        public static let cannotShowAllReason = "this iPhone cannot show every part of this question yet; answer it on your Mac"

        public func checkAnswer(option: String?, text answer: String?) throws {
            guard option != nil || answer != nil else { throw PhoneEvents.Failure.noAnswer }
            if let answer {
                guard !F1Text.isBlank(answer) else { throw PhoneEvents.Failure.emptyText }
                guard answer.unicodeScalars.count <= Limit.answer, answer.utf8.count <= PhoneEvents.maxAnswerTextBytes else { throw PhoneEvents.Failure.textTooLong }
                guard F1Text.isPlain(answer, oneLine: false, limit: Limit.answer) else { throw PhoneEvents.Failure.textRefused }
            }
            switch kind {
            case .choice:
                if let option {
                    guard options.contains(where: { $0.key.bytesEqual(option) }) else { throw PhoneEvents.Failure.unknownOption }
                } else if !allowOther { throw PhoneEvents.Failure.otherNotAllowed }
            case .text:
                guard option == nil else { throw PhoneEvents.Failure.optionOnTextQuestion }
                guard answer != nil else { throw PhoneEvents.Failure.noAnswer }
            }
        }

        private static func parseOption(_ v: JSONValue, index i: Int) throws -> F1QuestionOption {
            let n = "option \(i + 1)"
            guard let o = v.object, o.keys.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 < 0x80 } }) else { throw F1QuestionRefusal(.option, "\(n) is not an object") }
            guard let extra = Optional(o.keys.filter { !["key", "label", "text", "facts", "cost"].contains($0) }), extra.isEmpty else {
                throw F1QuestionRefusal(.unknownKey, "\(n) carries a key this iPhone does not know")
            }
            guard let key = o["key"]?.string, isToken(key) else { throw F1QuestionRefusal(.option, "\(n) has a bad key") }
            func field(_ name: String, oneLine: Bool = true, limit: Int) throws -> String? {
                guard let v = o[name] else { return nil }
                guard let s = v.string, F1Text.isPlain(s, oneLine: oneLine, limit: limit) else { throw F1QuestionRefusal(.option, "\(n) \(name) breaks the text rules") }
                return s
            }
            guard o["label"] != nil, let label = try field("label", limit: Limit.label) else { throw F1QuestionRefusal(.option, "\(n) has no title") }
            let text = try field("text", limit: Limit.optionText), cost = try field("cost", limit: Limit.cost)
            var facts: [F1Fact] = []
            if let fv = o["facts"] {
                guard let arr = fv.array, Limit.facts.contains(arr.count) else { throw F1QuestionRefusal(.facts, "\(n) facts are 1 to 3 [label, value] pairs") }
                for f in arr {
                    guard let p = f.array, p.count == 2, let l = p[0].string, let val = p[1].string,
                          F1Text.isPlain(l, oneLine: true, limit: Limit.factLabel), F1Text.isPlain(val, oneLine: true, limit: Limit.factValue) else {
                        throw F1QuestionRefusal(.facts, "\(n) has a fact that is not a [label, value] pair of plain text")
                    }
                    facts.append(F1Fact(label: l, value: val))
                }
                guard Set(facts.map { Array(F1Text.fold($0.label).utf8) }).count == facts.count else { throw F1QuestionRefusal(.facts, "\(n) has two facts with the same label") }
            }
            return F1QuestionOption(key: key, label: label, cost: cost, text: text, facts: facts)
        }

        /// `[a-z][a-z0-9_]*`, at most 32.
        static func isToken(_ s: String) -> Bool {
            let u = Array(s.utf8)
            guard (1...Limit.key).contains(u.count), u[0] >= 0x61, u[0] <= 0x7A else { return false }
            return u.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
        }
    }

    public let id: String
    public let state: State
    public let to: [String]
    public let blocking: Bool
    public let answeredBy: String?
    public let answeredSeq: Int64?
    public let toRef: String?
    /// `text`, `options` and `spec` as hashed, parsed (see `Content`).
    public let content: Content
    public let askedAt: String?
    public let askedSeq: Int64?
    public let answer: F1Answer?
    public let qid: String?
    public let hash: String?

    public var kind: F1QuestionKind { content.kind }
    public var text: String { content.text }
    public var why: String? { content.why }
    public var details: String? { content.details }
    public var recommended: String? { content.recommended }
    public var allowOther: Bool { content.allowOther }
    /// Empty for a `text` question.
    public var options: [F1QuestionOption] { content.options }

    static let requiredKeys: Set<String> = ["id", "state", "to", "blocking", "answered_by", "answered_seq"]
    static let optionalKeys: Set<String> = ["text", "spec", "to_ref", "options", "asked_at", "asked_by", "asked_seq", "answer", "qid", "hash"]
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
        toRef = try F1Question.optionalText(m["to_ref"], oneLine: true)
        content = try Content(text: m["text"], options: m["options"], spec: m["spec"])
        askedAt = m["asked_at"]?.string
        if m["asked_at"] != nil, askedAt == nil { throw Refusal.malformed }
        if let a = m["asked_by"], a.object == nil { throw Refusal.malformed }
        if let s = m["asked_seq"] {
            guard let n = s.int, n >= 0, n <= maxSafeInt else { throw Refusal.malformed }
            askedSeq = n
        } else { askedSeq = nil }
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

    /// The stored form of an OPEN question as reviewed (C2b `pe_reviews.snapshot`): exactly the fields this parser reads back, with `text`,
    /// `options` and `spec` as received (no normalisation). `F1Question(wire)` reproduces an equal question, byte for byte.
    public var openWire: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "state": "open", "to": .array(to.map(JSONValue.string)), "blocking": .bool(blocking),
                                      "answered_by": .null, "answered_seq": .null, "text": .string(content.text), "spec": content.specWire]
        if content.kind == .choice { o["options"] = content.optionsWire }
        if let toRef { o["to_ref"] = .string(toRef) }
        if let askedAt { o["asked_at"] = .string(askedAt) }
        if let askedSeq { o["asked_seq"] = .int(askedSeq) }
        if let qid { o["qid"] = .string(qid) }
        if let hash { o["hash"] = .string(hash) }
        return .object(o)
    }

    // MARK: parsing helpers

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

    // MARK: question id and hash (11A.14 14.5, F1 section 5.6, design #1123 rev 4)

    /// `qid = hex(SHA-256("orch/v2/question-id|" || cj({"question":"Q1","ticket":uid,"workspace_id":W}))[0:16])`.
    public static func questionID(question: String, ticketUID: String, workspace: ID16) throws -> String {
        guard F1ASCII.isQuestionID(question), F1ASCII.isULID(ticketUID) else { throw Refusal.malformed }
        let body = try canonicalJSON(["question": .string(question), "ticket": .string(ticketUID), "workspace_id": .string(workspace.hex)])
        return Hex.encode(SHA256.hash(data: Data(Label.hQuestionID.utf8) + body).prefix(16))
    }

    /// `hash = "sha256:" + hex(SHA-256("orch/v2/question|" || cj({"question_id":qid, "ticket":uid, "text":text, "options":options or [],
    /// "spec":spec})))`. `options` and `spec` are hashed VERBATIM (the host's JSON, as received), never rebuilt from parsed fields. The
    /// content is validated first (core `question_hash` calls `validate_question`): nothing hashes a question that breaks the shape.
    public static func questionHash(qid: String, ticketUID: String, content: Content) throws -> String {
        guard F1ASCII.isHex32(qid), F1ASCII.isULID(ticketUID) else { throw Refusal.malformed }
        let digest = try Decisions.contentHash(of: ["question_id": .string(qid), "ticket": .string(ticketUID), "text": .string(content.text),
                                                    "options": content.optionsWire, "spec": content.specWire])
        return "sha256:" + Hex.encode(digest)
    }

    /// Parses `text`, `options` (nil when absent) and `spec` as received, then hashes them. Throws `F1QuestionRefusal` for content the
    /// phone cannot read or verify.
    public static func questionHash(qid: String, ticketUID: String, text: JSONValue, options: JSONValue?, spec: JSONValue) throws -> String {
        try questionHash(qid: qid, ticketUID: ticketUID, content: Content(text: text, options: options, spec: spec))
    }

    /// What the phone shows and signs for a question: both values recomputed from the uid, the paired workspace id and the displayed
    /// content, and equal to the host's `qid` and `hash` (14.5). Anything else is refused: no sign sheet for a question the phone cannot
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

    /// The recomputed `qid` and `hash`, each compared byte-exactly with the host's. Throws `F1QuestionRefusal(.hashMismatch)` when the host
    /// hash is not the phone's, so the caller can say why the question cannot be verified.
    package func verified(ticketUID: String, workspace: ID16) throws -> (qid: String, hash: String) {
        guard let hostQid = qid, let hostHash = hash else { throw F1QuestionRefusal(.malformed, "the host sent no id or hash for this question") }
        let myQid = try F1Question.questionID(question: id, ticketUID: ticketUID, workspace: workspace)
        let myHash = try F1Question.questionHash(qid: myQid, ticketUID: ticketUID, content: content)
        guard myQid.bytesEqual(hostQid), myHash.bytesEqual(hostHash) else { throw F1QuestionRefusal(.hashMismatch, "the host's hash is not the one this iPhone computes") }
        return (myQid, myHash)
    }

    public func reviewed(ticketUID: String, workspace: ID16, basedOn: String, rosterV: Int64) throws -> Reviewed {
        guard F1ASCII.isHash(basedOn), rosterV >= 0, rosterV <= maxSafeInt else { throw Refusal.malformed }
        guard state == .open else { throw Refusal.malformed }
        let (myQid, myHash) = try verified(ticketUID: ticketUID, workspace: workspace)
        return Reviewed(question: self, ticketUID: ticketUID, qid: myQid, hash: myHash, text: text, basedOn: basedOn, rosterV: rosterV)
    }
}
