import Foundation
import OrchProtocol

// What the hub tells the phone about workspaces and items (design B2; orch-hub web API `GET /me/workspaces`, `GET /me/needs-you`,
// `GET /workspaces/{ws}/items/{id}`). These types are DISPLAY ONLY (D-B4): nothing here feeds a signature, and `signable` / `canStart`
// only ever enable a button; the authority is the hub's prepare and the host. The hub decides what the user may see; the phone shows
// `hubReads`, `role` and `online` as given and filters nothing in. Every string is rendered again through `HubText` (defence in depth).

public struct HubWorkspace: Sendable, Equatable, Codable, Identifiable {
    public enum Mode: String, Sendable, Codable { case full, selective }
    public let id: String
    public let name: String?
    public let mode: Mode
    /// `owner` (selective: the aliased owner), `read`, `edit` or `admin`, as the hub gave it.
    public let role: String
    /// A workspace whose host is not bound right now: "Paused", never signable.
    public let online: Bool
    /// What the hub can read of this workspace, in the hub's words ("everything" / "shared items and summaries").
    public let hubReads: String
    /// Enables "start something" buttons; the hub's prepare is the authority.
    public let canStart: Bool
}

public struct HubNeedsYouRow: Sendable, Equatable, Codable, Identifiable {
    public var id: String { workspaceID + "/" + itemID }
    public let workspaceID: String
    public let mode: HubWorkspace.Mode
    public let itemID: String
    public let kind: String
    public let type: String?
    public let key: String?
    public let title: String?
    public let deadline: String?
    /// Selective `needs_you` rows are summaries: no detail beyond the summary and no sign button ("Handled where it lives").
    public let summaryOnly: Bool
    /// The hub's hint that a sign button may be enabled. Never an authority, and never true for a selective row in B2.
    public let signable: Bool
}

public struct HubNeedsYou: Sendable, Equatable, Codable {
    public let rows: [HubNeedsYouRow]
    /// Workspace ids whose host is offline (the hub could not read them) and ids it could not read at all.
    public let offline: [String]
    public let unavailable: [String]
}

/// One item with its content flattened to labelled lines (display only; the sign prompt of B3 is built from the signed context instead).
public struct HubItemDetail: Sendable, Equatable {
    public let row: HubNeedsYouRow
    public let lines: [Line]
    public let itemHash: String?
    /// What a sign button would start (nil: this item cannot be decided from the phone). Display data only: the action it builds is checked
    /// against the hub's prepared event (`check_built`), and the hub's prepare is the authority.
    public let decision: HubItemDecision?
    public struct Line: Sendable, Equatable { public let label: String; public let value: String }
}

/// The decision an item offers, from the hub's item answer (`log`, `hash`, and the content's `question` / `options` / `gate`).
public struct HubItemDecision: Sendable, Equatable {
    /// One option of a verified `choice` question: the title (`label`), and the one-line text, `[label, value]` facts and cost the hash binds.
    public struct Option: Sendable, Equatable {
        public let key: String
        public let label: String
        public let text: String?
        public let facts: [F1Fact]
        public let cost: String?
        public init(key: String, label: String, text: String? = nil, facts: [F1Fact] = [], cost: String? = nil) {
            self.key = key; self.label = label; self.text = text; self.facts = facts; self.cost = cost
        }
    }
    public enum Kind: Sendable, Equatable {
        case question(id: String, options: [Option])
        case gate(String)
        case verdict
    }
    public let log: String
    public let hash: String
    public let kind: Kind
    /// Set only for a shared item of a selective workspace (protocol 8.6): the action names `item`, and the prepared event is held to these values.
    public let shared: Shared?

    /// What the person was shown of a shared item: the item and the `f1` values the hub will build on. The phone compares the prepared event with
    /// them (they are unsigned display data: the host's check against its own log is the authority, protocol 8.6).
    public struct Shared: Sendable, Equatable {
        public let item: String
        public let itemHash: String
        public let rosterV: Int64
        /// The `f1` entry of the gate the decision is on (`verify` for a verdict); nil for a question.
        public let gateGen: Int64?
        public let policyHash: String?
        public let sourceSha: JSONValue?
        public init(item: String, itemHash: String, rosterV: Int64, gateGen: Int64?, policyHash: String?, sourceSha: JSONValue?) {
            self.item = item; self.itemHash = itemHash; self.rosterV = rosterV; self.gateGen = gateGen; self.policyHash = policyHash; self.sourceSha = sourceSha
        }
    }

    public init(log: String, hash: String, kind: Kind, shared: Shared? = nil) { self.log = log; self.hash = hash; self.kind = kind; self.shared = shared }
}

enum HubViewParse {
    static let maxText = 2_000
    static let maxRows = 500
    static let maxLines = 60

    static func isWorkspaceID(_ s: String) -> Bool { s.utf8.count == 32 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) } }
    /// An item id goes into a request path: a short token, never anything that could change the path.
    static func isItemID(_ s: String) -> Bool {
        s != "." && s != ".." && (1...64).contains(s.utf8.count) && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E }
    }

    static func text(_ v: JSONValue?) throws -> String? {
        guard let v, !v.isNull else { return nil }
        guard let s = v.string, s.utf8.count <= maxText else { throw HubAPIError.badReply }
        return HubText.render(s)
    }

    static func workspaces(_ o: [String: JSONValue]) throws -> [HubWorkspace] {
        guard let a = o["workspaces"]?.array, a.count <= 200 else { throw HubAPIError.badReply }
        var seen = Set<String>()
        return try a.map { v in
            guard let r = v.object, let id = r["workspace_id"]?.string, isWorkspaceID(id), seen.insert(id).inserted,
                  let m = r["mode"]?.string, let mode = HubWorkspace.Mode(rawValue: m), let role = r["role"]?.string, ["owner", "read", "edit", "admin"].contains(role),
                  let online = r["online"]?.bool, let reads = try text(r["hub_reads"]), let canStart = r["can_start"]?.bool
            else { throw HubAPIError.badReply }
            return HubWorkspace(id: id, name: try text(r["name"]), mode: mode, role: role, online: online, hubReads: reads, canStart: canStart)
        }
    }

    /// A row that does not parse fails the whole answer (a hub that sends garbage is not shown); a row for a workspace the user does not
    /// have, or whose mode differs from the workspace list, is dropped (the phone never shows what the list does not vouch for).
    static func row(_ r: [String: JSONValue], in ws: [String: HubWorkspace]) throws -> HubNeedsYouRow? {
        guard let w = r["workspace_id"]?.string, isWorkspaceID(w), let m = r["mode"]?.string, let mode = HubWorkspace.Mode(rawValue: m),
              let item = r["item_id"]?.string, isItemID(item), let kind = r["kind"]?.string, (1...32).contains(kind.utf8.count) else { throw HubAPIError.badReply }
        guard let known = ws[w], known.mode == mode else { return nil }
        let signable = r["signable"]?.bool ?? false
        let selective = mode == .selective
        if selective, !["ticket", "question", "needs_you"].contains(kind) { return nil }
        let summary = (r["summary_only"]?.bool ?? false) || (selective && kind == "needs_you")
        return HubNeedsYouRow(workspaceID: w, mode: mode, itemID: item, kind: HubText.render(kind), type: try text(r["type"]), key: try text(r["key"]),
                              title: try text(r["title"]), deadline: try text(r["deadline"]), summaryOnly: summary,
                              signable: signable && !selective && !summary && known.online)
    }

    static func needsYou(_ o: [String: JSONValue], workspaces: [HubWorkspace]) throws -> HubNeedsYou {
        guard let items = o["items"]?.array, items.count <= maxRows, let off = o["offline"]?.array, let un = o["unavailable"]?.array else { throw HubAPIError.badReply }
        let known = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let rows = try items.compactMap { v -> HubNeedsYouRow? in
            guard let r = v.object else { throw HubAPIError.badReply }
            return try row(r, in: known)
        }
        func ids(_ a: [JSONValue]) throws -> [String] {
            try a.map { v in guard let s = v.string, isWorkspaceID(s), a.count <= 200 else { throw HubAPIError.badReply }; return s }.filter { known[$0] != nil }
        }
        return HubNeedsYou(rows: rows, offline: try ids(off), unavailable: try ids(un))
    }

    static func detail(_ o: [String: JSONValue], workspaces: [HubWorkspace]) throws -> HubItemDetail {
        let known = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        guard let r = try row(o, in: known), let content = o["content"] else { throw HubAPIError.badReply }
        var lines: [HubItemDetail.Line] = []
        flatten(content, label: "", depth: 0, into: &lines)
        let hash = (o["item_hash"]?.string).flatMap { $0.utf8.count <= 80 ? HubText.render($0) : nil }
        let dec: HubItemDecision?
        if r.mode == .selective {
            // a summary is never signable; a shared item is signable only when its own `f1` names the target (protocol 8.6)
            dec = r.summaryOnly || r.kind == "needs_you" ? nil : sharedDecision(o, content: content, kind: r.kind)
        } else { dec = r.signable ? decision(o, content: content, kind: r.kind, workspace: ID16(hex: r.workspaceID)) : nil }
        return HubItemDetail(row: r, lines: lines, itemHash: hash, decision: dec)
    }

    /// The one decision a shared item offers, from `chain.log` and `f1` (exact shapes of protocol 10.2b). Anything the phone cannot read, an `f1`
    /// that names no target or more than one, or an item id that is not 32 hex, offers nothing: the item is shown and "Handled where it lives".
    static func sharedDecision(_ o: [String: JSONValue], content: JSONValue, kind: String) -> HubItemDecision? {
        guard let item = o["item_id"]?.string, HubSign.isItemID(item), let ih = o["item_hash"]?.string, HubSign.isHash(ih),
              let log = o["chain"]?.object?["log"]?.string, HubSign.isULID(log), let f1 = o["f1"]?.object, let roster = f1["roster_v"]?.int, roster >= 0,
              let c = content.object else { return nil }
        let gates = f1["gates"]?.object ?? [:], questions = f1["questions"]?.object ?? [:]
        guard gates.count + questions.count == 1 else { return nil }
        func shared(_ g: (gen: Int64, policy: String, source: JSONValue?)?) -> HubItemDecision.Shared {
            .init(item: item, itemHash: ih, rosterV: roster, gateGen: g?.gen, policyHash: g?.policy, sourceSha: g?.source)
        }
        if let (qid, v) = questions.first {
            // a question answer on a `question` item, about the question the item is about; options are not shared, so there are none
            guard kind == "question", c["id"]?.string == qid, qid.hasPrefix("Q"), qid.count > 1, qid.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }),
                  let h = v.object?["hash"]?.string, HubSign.isHash(h) else { return nil }
            return HubItemDecision(log: log, hash: h, kind: .question(id: qid, options: []), shared: shared(nil))
        }
        guard kind == "ticket", let (gate, v) = gates.first, let e = v.object, let h = e["hash"]?.string, HubSign.isHash(h), let gen = e["gen"]?.int, gen >= 0,
              let pol = e["policy_hash"]?.string, HubSign.isHash(pol) else { return nil }
        let src = e["source_sha"]
        switch gate {
        case "requirements", "plan": guard src == nil else { return nil }
        case "code", "verify": guard src?.array?.isEmpty == false else { return nil }
        default: return nil
        }
        return HubItemDecision(log: log, hash: h, kind: gate == "verify" ? .verdict : .gate(gate), shared: shared((gen, pol, src)))
    }

    static func decision(_ o: [String: JSONValue], content: JSONValue, kind: String, workspace: ID16?) -> HubItemDecision? {
        guard let log = o["log"]?.string, HubSign.isULID(log), let hash = o["hash"]?.string, HubSign.isHash(hash), let c = content.object else { return nil }
        switch kind {
        case "question":
            guard let q = c["question"]?.string, q.hasPrefix("Q"), q.count > 1, q.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }),
                  let qid = o["item_id"]?.string, HubSign.isItemID(qid), let workspace,
                  (try? F1Question.questionID(question: q, ticketUID: log, workspace: workspace))?.bytesEqual(qid) == true else { return nil }
            // Design #1123 rev 4: the phone hashes the RAW question exactly as the hub sent it (`text`, `options`, `spec` verbatim) and offers an
            // answer only when that is the row's hash. Unknown kind or key, a bad limit, a hash mismatch, a `text` question (no hub input yet) and any
            // question with a part the buttons do not show (details, why, recommended, option text, facts) offer nothing: the item is shown and answered on the Mac. Never a blind Answer button.
            guard let content = try? F1Question.Content(text: c["text"], options: c["options"], spec: c["spec"]), content.phoneShowsEverything,
                  let mine = try? F1Question.questionHash(qid: qid, ticketUID: log, content: content), mine.bytesEqual(hash) else { return nil }
            let opts = content.options.map { HubItemDecision.Option(key: $0.key, label: HubText.render($0.label), text: $0.text.map(HubText.render),
                                                                    facts: $0.facts, cost: $0.cost) }
            return HubItemDecision(log: log, hash: hash, kind: .question(id: q, options: opts), shared: nil)
        case "gate":
            guard let g = c["gate"]?.string, ["requirements", "plan", "code"].contains(g) else { return nil }
            return HubItemDecision(log: log, hash: hash, kind: .gate(g), shared: nil)
        case "verdict": return HubItemDecision(log: log, hash: hash, kind: .verdict, shared: nil)
        default: return nil
        }
    }

    /// Scalars only, at most three levels deep and `maxLines` lines; anything else is not shown (and nothing is invented).
    private static func flatten(_ v: JSONValue, label: String, depth: Int, into out: inout [HubItemDetail.Line]) {
        guard out.count < maxLines, depth <= 3 else { return }
        switch v {
        case .object(let o): for k in o.keys.sorted() { flatten(o[k]!, label: label.isEmpty ? k : label + " / " + k, depth: depth + 1, into: &out) }
        case .array(let a): for (i, e) in a.prefix(20).enumerated() { flatten(e, label: label + " [\(i + 1)]", depth: depth + 1, into: &out) }
        case .string(let s): out.append(.init(label: HubText.render(label), value: HubText.render(String(s.prefix(maxText)))))
        case .int(let i): out.append(.init(label: HubText.render(label), value: String(i)))
        case .bool(let b): out.append(.init(label: HubText.render(label), value: b ? "yes" : "no"))
        case .null: break
        }
    }
}
