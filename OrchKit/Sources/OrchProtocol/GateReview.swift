import CryptoKit
import Foundation

/// B10 phase 1: what the phone recomputes and shows before it signs a gate decision (`gate.approved` / `gate.changes_requested` on
/// `requirements` and `plan`).
///
/// The host hands over three things: the gate-hash input G (`gate.input`), the section TEXTS (`ticket.get` `doc.sections`) and the hash
/// it says G has. The phone trusts none of them: it recomputes `section_hash(text)` for every section G names, compares it with
/// `G.sections[id]`, recomputes `gate_hash(G)` and compares it with the host's hash, and checks that G names this ticket (uid), this gate
/// and this workspace. Everything it then shows comes from G and the verified texts. Anything else (the ticket key, the title, the
/// generation, the rule) is the host's word and is labelled "per host, not signed" by the caller.
///
/// The plain view follows the B6 SignContent rules (host `signcontent.py`): a closed set of keys it knows how to show, the others in
/// the full review (raw G, sorted). A string on one line goes through `GateReview.oneLine` (a line break is shown as ` ⏎ `); only a
/// section's text is a multi-line block.
public enum GateReview {
    /// Phase 1: the gates a phone may decide. `code` and `verify` carry a host-stamped `source_sha` (phase 2).
    public static let phoneGates: [String] = ["requirements", "plan"]
    public static func isPhoneGate(_ gate: String) -> Bool { phoneGates.contains { $0.bytesEqual(gate) } }

    public static let schema = "orch.ticket/2"
    /// The 15 keys of G (ticket-format 5.7), always present.
    static let gateKeys: Set<String> = ["workspace_id", "uid", "gate", "schema", "hash_v", "sections", "fields", "addon_packages", "tasks",
                                        "artifacts", "receipts", "source_sha", "prior", "policy_hash", "people_hash"]
    public static let maxSectionBytes = 65_536

    public enum Failure: Error, Equatable, Sendable {
        /// Not requirements or plan.
        case notAPhoneGate
        /// G, a hash or a text is not in a shape the phone can recompute: nothing is shown or signed.
        case shape(String)
        /// A recomputed value is not the host's, or G names another ticket, gate or workspace: "This changed or does not match. Reopen."
        case mismatch(String)
    }

    // MARK: hashes

    /// `"sha256:" + hex(SHA-256("orch/v2/section|" || UTF-8(text)))`. The text must already follow section 11.3 and carry no leading or
    /// trailing LF and at most 65 536 bytes: refused, never trimmed (`canon.hashing.section_hash`).
    public static func sectionHash(_ text: String) throws -> String {
        guard F1Text.isClean(text), !text.hasPrefix("\n"), !text.hasSuffix("\n"), text.utf8.count <= maxSectionBytes else { throw Failure.shape("section text") }
        return "sha256:" + Hex.encode(SHA256.hash(data: Data(Label.hSection.utf8) + Data(text.utf8)))
    }

    /// `"sha256:" + hex(SHA-256("orch/v2/gate|" || cj(G)))`. Only the shape the phone relies on is checked here (15 keys, the values the
    /// verify step compares); the host's own `gate_hash` checks every field type, and an `E.hash` it does not recognise is `gate.stale`.
    public static func gateHash(_ g: JSONValue) throws -> String {
        guard let o = g.object, Set(o.keys) == gateKeys else { throw Failure.shape("G keys") }
        let body: Data
        do { body = try canonicalJSON(g) } catch { throw Failure.shape("G is not canonical JSON") }
        return "sha256:" + Hex.encode(SHA256.hash(data: Data(Label.hGate.utf8) + body))
    }

    // MARK: verifying

    /// A gate the phone has recomputed: everything in it is checked against the hashes, except `gen` and `basedOn`/`rosterV`, which are the
    /// host's current values that the model compares itself (`gate.stale`, `event.bad_base`, `members.stale`).
    public struct Verified: Equatable, Sendable {
        public let ticketUID: String
        public let gate: String
        public let workspace: ID16
        public let gen: Int64
        public let hash: String
        public let policyHash: String
        /// `ticket.get` `doc.head.head`.
        public let basedOn: String
        /// `ticket.get` `members_v`.
        public let rosterV: Int64
        /// G itself, as the host hashes it.
        public let input: JSONValue
        /// The texts of the sections G names, each checked against `G.sections[id]`.
        public let texts: [String: String]

        /// The same verified gate under another roster version (an automatic re-sign after `members.stale`): nothing else changes.
        public func withRoster(_ v: Int64) -> Verified {
            Verified(ticketUID: ticketUID, gate: gate, workspace: workspace, gen: gen, hash: hash, policyHash: policyHash, basedOn: basedOn, rosterV: v,
                     input: input, texts: texts)
        }
    }

    /// Recomputes and compares. `claimed*` and `gen` are what `gate.input` said; `sectionTexts` is `ticket.get` `doc.sections`.
    public static func verify(ticketUID: String, gate: String, workspace: ID16, claimedHash: String, claimedPolicyHash: String, gen: Int64,
                              input: JSONValue, sectionTexts: [String: String], basedOn: String, rosterV: Int64) throws -> Verified {
        guard isPhoneGate(gate) else { throw Failure.notAPhoneGate }
        guard F1ASCII.isULID(ticketUID), F1ASCII.isHash(claimedHash), F1ASCII.isHash(claimedPolicyHash), F1ASCII.isHash(basedOn),
              gen >= 0, gen <= maxSafeInt, rosterV >= 0, rosterV <= maxSafeInt, let g = input.object, Set(g.keys) == gateKeys else {
            throw Failure.shape("fields")
        }
        guard g["uid"]?.string?.bytesEqual(ticketUID) == true, g["gate"]?.string?.bytesEqual(gate) == true,
              g["workspace_id"]?.string?.bytesEqual(workspace.hex) == true, g["schema"]?.string?.bytesEqual(schema) == true,
              g["hash_v"]?.int == 1 else { throw Failure.mismatch("identity") }
        guard let secs = g["sections"]?.object else { throw Failure.shape("sections") }
        var texts: [String: String] = [:]
        for (id, h) in secs {
            guard let want = h.string, F1ASCII.isHash(want) else { throw Failure.shape("section hash") }
            let text = sectionTexts[id] ?? ""
            guard try sectionHash(text).bytesEqual(want) else { throw Failure.mismatch("section \(id)") }
            texts[id] = text
        }
        guard g["policy_hash"]?.string?.bytesEqual(claimedPolicyHash) == true else { throw Failure.mismatch("policy_hash") }
        guard try gateHash(input).bytesEqual(claimedHash) else { throw Failure.mismatch("hash") }
        return Verified(ticketUID: ticketUID, gate: gate, workspace: workspace, gen: gen, hash: claimedHash, policyHash: claimedPolicyHash,
                        basedOn: basedOn, rosterV: rosterV, input: input, texts: texts)
    }

    // MARK: the plain view

    public struct Section: Equatable, Sendable {
        public let id: String, title: String, text: String
        public init(id: String, title: String, text: String) { self.id = id; self.title = title; self.text = text }
    }
    public struct Criterion: Equatable, Sendable {
        public let id: String, text: String
        public init(id: String, text: String) { self.id = id; self.text = text }
    }
    public struct TaskRow: Equatable, Sendable {
        public let n: Int, id: String, title: String, verify: [String]
        public init(n: Int, id: String, title: String, verify: [String]) { self.n = n; self.id = id; self.title = title; self.verify = verify }
    }
    public struct Row: Equatable, Sendable {
        public let field: String, value: String
        public init(field: String, value: String) { self.field = field; self.value = value }
    }

    /// What the review screen shows of a verified gate. `fullReview`: something signed is outside what the plain view knows how to show
    /// (or non-default where the contract asks for the whole input), so the raw input is shown in full and first.
    public struct Content: Equatable, Sendable {
        public let gate: String
        public let sections: [Section]
        public let acceptance: [Criterion]
        public let tasks: [TaskRow]
        public let rows: [Row]
        public let fullReview: Bool
        public let fullReviewReasons: [String]
        /// Every key of G, sorted, one line each (`key: cj(value)`): the details, always one tap away, and the whole review when `fullReview`.
        public let rawLines: [String]
        public init(gate: String, sections: [Section], acceptance: [Criterion], tasks: [TaskRow], rows: [Row], fullReview: Bool, fullReviewReasons: [String],
                    rawLines: [String]) {
            self.gate = gate; self.sections = sections; self.acceptance = acceptance; self.tasks = tasks; self.rows = rows; self.fullReview = fullReview
            self.fullReviewReasons = fullReviewReasons; self.rawLines = rawLines
        }
    }

    static let fieldsShown: Set<String> = ["ticket_type", "size", "acceptance", "links", "addons"]
    static let taskShown: Set<String> = ["id", "text", "verify", "proves"]
    static let criterionShown: Set<String> = ["id", "text"]

    /// A single-line value: every line break is visible as ` ⏎ ` (a title or command with a newline cannot fake a second row).
    public static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .joined(separator: " ⏎ ")
    }

    static func title(of id: String) -> String {
        let t = id.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    static func compact(_ v: JSONValue) -> String {
        if let s = v.string { return oneLine(s) }
        if let d = try? canonicalJSON(v) { return oneLine(String(decoding: d, as: UTF8.self)) }
        return "?"
    }

    /// `persons`: approval id -> person, from `ticket.get` `gates.requirements.decisions` (the host's word; shown only with "per host, not signed").
    static let maxPriorApprovals = 32

    /// `prior` (ticket-format 5.7): a requirements gate has none; a plan gate may carry the requirements gate's generation and its counted approvals.
    /// A shape outside that is the full review (reason "earlier gates"). When it holds, the verified row and one line per approval id; a person is
    /// named only from the host's list and only with the per-host label.
    static func priorRows(_ prior: JSONValue?, gate: String, persons: [String: String], reasons: inout [String]) -> [Row] {
        guard let p = prior?.object else { reasons.append("earlier gates"); return [] }
        func fallback() -> [Row] {
            reasons.append("earlier gates")
            return p.sorted(by: { $0.key < $1.key }).map { Row(field: "Earlier gate \(oneLine($0.key))", value: compact($0.value)) }
        }
        if p.isEmpty { return [] }
        guard gate == "plan", Set(p.keys) == ["requirements"], let e = p["requirements"]?.object, Set(e.keys) == ["gen", "approvals"],
              let gen = e["gen"]?.int, gen >= 0, gen <= maxSafeInt, let items = e["approvals"]?.array, items.count <= maxPriorApprovals else { return fallback() }
        var ids: [String] = []
        for it in items { guard let id = it.string, ULID.isValid(id) else { return fallback() }; ids.append(id) }
        guard zip(ids, ids.dropFirst()).allSatisfy({ $0.utf8.lexicographicallyPrecedes($1.utf8) }) else { return fallback() }
        var rows = [Row(field: "Requirements, approved before", value: "generation \(gen), " + (ids.isEmpty ? "no approvals counted" : (ids.count == 1 ? "1 approval" : "\(ids.count) approvals")))]
        for id in ids {
            rows.append(Row(field: "Approval", value: persons[id].map { "\(oneLine($0)) (per host, not signed)" } ?? "approval \(id.suffix(6)) (not listed by the host)"))
        }
        return rows
    }

    public static func content(of v: Verified, persons: [String: String] = [:]) -> Content {
        let g = v.input.object ?? [:]
        var reasons: [String] = []
        var rows: [Row] = []
        /// A value that must be an object / array when present: a wrong type is a shape the plain view does not know (fail closed).
        func obj(_ x: JSONValue?) -> [String: JSONValue] {
            guard let x else { return [:] }
            if let o = x.object { return o }
            reasons.append("unknown shape"); return [:]
        }
        func arr(_ x: JSONValue?) -> [JSONValue] {
            guard let x else { return [] }
            if let a = x.array { return a }
            reasons.append("unknown shape"); return []
        }
        let fields = obj(g["fields"])
        if g["fields"] == nil { reasons.append("unknown shape") }
        if !Set(fields.keys).isSubset(of: fieldsShown) { reasons.append("unknown fields") }
        if let t = fields["ticket_type"] { rows.append(Row(field: "Type", value: compact(t))) }
        if let s = fields["size"], !s.isNull { rows.append(Row(field: "Size", value: compact(s))) }
        if let l = fields["links"], !l.isNull { rows.append(Row(field: "Links", value: compact(l))); reasons.append("links") }
        for (name, val) in obj(fields["addons"]).sorted(by: { $0.key < $1.key }) {
            rows.append(Row(field: "Add-on \(oneLine(name))", value: compact(val))); reasons.append("add-ons")
        }
        var acceptance: [Criterion] = []
        for a in arr(fields["acceptance"]) {
            guard let o = a.object, Set(o.keys).isSubset(of: criterionShown), let id = o["id"]?.string, let text = o["text"]?.string else {
                reasons.append("unknown acceptance"); continue
            }
            acceptance.append(Criterion(id: oneLine(id), text: oneLine(text)))
        }
        var seenIDs = Set<String>()
        if !acceptance.allSatisfy({ seenIDs.insert($0.id).inserted }) { reasons.append("repeated criterion id") }
        var tasks: [TaskRow] = []
        for (i, t) in arr(g["tasks"]).enumerated() {
            guard let o = t.object, Set(o.keys).isSubset(of: taskShown), let id = o["id"]?.string, let text = o["text"]?.string else {
                reasons.append("unknown task"); continue
            }
            var line = oneLine(text)
            if let pv = o["proves"] {
                if let items = pv.array, items.allSatisfy({ $0.string != nil }) {
                    let p = items.compactMap(\.string)
                    if !p.isEmpty { line += " (proves \(oneLine(p.joined(separator: ", "))))" }
                } else { reasons.append("unknown task") }
            }
            var verify: [String] = []
            if let vv = o["verify"], !vv.isNull {
                if let vo = vv.object, Set(vo.keys).isSubset(of: ["cmd"]) {
                    if let c = vo["cmd"] { if let cs = c.string { if !cs.isEmpty { verify.append(oneLine(cs)) } } else { reasons.append("unknown task") } }
                } else { reasons.append("unknown task verify") }
            }
            tasks.append(TaskRow(n: i + 1, id: oneLine(id), title: line, verify: verify))
        }
        // the keys the contract sends to the full review when they are non-empty
        for (key, label) in [("artifacts", "files"), ("receipts", "results"), ("addon_packages", "add-on packages")] {
            let o = obj(g[key])
            if !o.isEmpty {
                reasons.append(label)
                for (name, val) in o.sorted(by: { $0.key < $1.key }) { rows.append(Row(field: "\(title(of: label)) \(oneLine(name))", value: compact(val))) }
            }
        }
        let src = arr(g["source_sha"])
        if !src.isEmpty {
            reasons.append("source")
            for item in src { rows.append(Row(field: "Code", value: compact(item))) }
        }
        rows += priorRows(g["prior"], gate: v.gate, persons: persons, reasons: &reasons)
        let sections = (g["sections"]?.object ?? [:]).keys.sorted().map { Section(id: $0, title: title(of: $0), text: v.texts[$0] ?? "") }
        let raw = g.sorted { $0.key < $1.key }.map { "\($0.key): \(compact($0.value))" }
        var seen = Set<String>(); let unique = reasons.filter { seen.insert($0).inserted }
        return Content(gate: v.gate, sections: sections, acceptance: acceptance, tasks: tasks, rows: rows, fullReview: !unique.isEmpty,
                       fullReviewReasons: unique, rawLines: raw)
    }
}
