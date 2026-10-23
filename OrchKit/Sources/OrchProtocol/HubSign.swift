import CryptoKit
import Foundation

// Custodial signing from the phone (orch-hub protocol 8.2 to 8.5, design B3). Pure functions: the digest, the checks of a prepared request,
// the text escaping and the facts a sign prompt shows. Reference implementation: orch-hub `orch_hub.contract` (`check_prepared`,
// `check_built`, `render_text`); vectors `prepared_*`, `built_*`, `render_*` (replayed by `HubSignVectorTests`).
//
// WYSIWYS: everything the person sees comes from `ctx` (the bytes the phone hashes). A `shown` block from the hub is never read.

public enum HubSign {
    /// The ONLY event types the phone can sign through the hub (L2B-3): the four decisions. There is no Confirm for anything else.
    /// Moves, people, visibility, admin types and every other custodial type are refused before anything is shown.
    public static let decisionTypes: [String] = ["question.answered", "gate.approved", "gate.changes_requested", "verdict.given"]

    public static func isDecisionType(_ type: String) -> Bool { decisionTypes.contains { $0.bytesEqual(type) } }

    /// The decisions that name a reviewed content hash (`hash`): the phone shows it short next to a link to the content (protocol 8.4).
    public static func isContentBound(_ type: String) -> Bool { isDecisionType(type) && !"question.answered".bytesEqual(type) }

    /// `H("orch/v2/hub-event-digest|" || cj(ctx))` where `ctx.event` has no `channel_proof` (protocol 8.2).
    public static func digest(ofContext ctx: JSONValue) throws -> Data {
        guard var c = ctx.object, var event = c["event"]?.object else { throw Refusal.malformed }
        event["channel_proof"] = nil
        c["event"] = .object(event)
        return Data(SHA256.hash(data: Data(Label.hHubEventDigest.utf8) + (try canonicalJSON(.object(c)))))
    }

    static func isULID(_ s: String) -> Bool {
        s.utf8.count == 26 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }
    }

    static func isHash(_ s: String) -> Bool {
        s.hasPrefix("sha256:") && Hex.decode(String(s.dropFirst(7)), length: 32) != nil
    }

    /// `check_prepared` (protocol 8.4 step 3): `ctx` has exactly `{contract: 1, suite: 2, workspace_id, log, event}`, `event.auth == "hub"` and no
    /// `channel_proof` (else `malformed`); the digest recomputed from `ctx` equals the hub's (else `event_changed`). Returns the digest that
    /// the phone computed itself.
    @discardableResult
    public static func checkPrepared(ctx: JSONValue, digestHex: String) throws -> Data {
        guard let c = ctx.object, Set(c.keys) == ["contract", "suite", "workspace_id", "log", "event"],
              c["contract"] == .int(1), c["suite"] == .int(2),
              let ws = c["workspace_id"]?.string, Hex.decode(ws, length: 16) != nil,
              let log = c["log"]?.string, log.bytesEqual("workspace") || isULID(log),
              let event = c["event"]?.object, event["auth"]?.string?.bytesEqual("hub") == true, event["channel_proof"] == nil
        else { throw Refusal.malformed }
        let mine = try digest(ofContext: ctx)
        guard let theirs = Hex.decode(digestHex, length: 32), theirs == mine else { throw Refusal.eventChanged }
        return mine
    }

    /// `check_built` (protocol 8.4 step 2): the event the hub built is the action the person started: same type, same log, and on the four
    /// decisions `hash` present (`malformed`) and byte-equal to the action's (`event_changed`).
    public static func checkBuilt(action: JSONValue, log: String, event: JSONValue) throws {
        guard let a = action.object, let e = event.object, let at = a["type"]?.string, let et = e["type"]?.string, let al = a["log"]?.string
        else { throw Refusal.malformed }
        if isDecisionType(et) {
            guard let eh = e["hash"]?.string else { throw Refusal.malformed }
            guard let ah = a["hash"]?.string, ah.bytesEqual(eh) else { throw Refusal.eventChanged }
        }
        guard at.bytesEqual(et), al.bytesEqual(log) else { throw Refusal.eventChanged }
    }

    // MARK: render_text

    /// `render_text` (protocol 8.4, L2P4-2d): every character the 8.5 text rule refuses, other than LF, is shown as `<U+XXXX>` (at least four
    /// upper-case hex digits). View-derived text (titles, question text, option labels) comes from events agents write, so it can never hide
    /// a bidi override, a blank look-alike or a control character in a sign prompt.
    public static func renderText(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if s.value == 0x0A || !refused(s) { out.append(s) } else {
                let hex = String(s.value, radix: 16, uppercase: true)
                out.append(contentsOf: ("<U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + ">").unicodeScalars)
            }
        }
        return String(out)
    }

    private static func refused(_ s: Unicode.Scalar) -> Bool {
        if !F1Text.isAssigned(s.value) { return true }                       // Cn, on the Unicode 16.0 tables (never the OS's)
        if s.properties.isDefaultIgnorableCodePoint { return true }
        switch s.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: return true
        default: return false
        }
    }

    // MARK: short forms

    /// First 12 hex digits after `sha256:`, in groups of 4: what the phone and Mission Control show for a content hash (protocol 8.4).
    public static func shortHash(_ hash: String) -> String? {
        guard isHash(hash) else { return nil }
        let u = Array(hash.dropFirst(7).prefix(12))
        return stride(from: 0, to: 12, by: 4).map { String(u[$0..<$0 + 4]) }.joined(separator: " ")
    }

    /// A short form of a digest for the person to compare ("Signature reference").
    public static func shortDigest(_ digest: Data) -> String {
        let u = Array(Hex.encode(digest).prefix(12))
        return stride(from: 0, to: 12, by: 4).map { String(u[$0..<$0 + 4]) }.joined(separator: " ")
    }

    // MARK: what the prompt shows

    public struct Field: Sendable, Equatable { public let name: String; public let value: String }
    public struct Source: Sendable, Equatable { public let repo: String; public let sha: String }

    /// Everything a sign prompt shows, derived from `ctx.event` alone (D15b display rule: gate, short hash, `gate_gen`, short source SHAs).
    public struct Facts: Sendable, Equatable {
        public let type: String
        public let log: String
        public let workspaceID: String
        /// A plain sentence for a known shape; nil when the event carries a field the phone does not know (then only `fields` is shown).
        public let sentence: String?
        public let gate: String?
        public let shortHash: String?
        public let gateGen: Int64?
        public let sources: [Source]
        /// Every field of the event, by name, each string through `renderText`: the "Signed details".
        public let fields: [Field]
        public let hasUnknownField: Bool
    }

    static let envelope: Set<String> = ["v", "id", "type", "actor", "based_on", "roster_v", "hash_v", "auth", "channel", "channel_factor", "hub_id",
                                        "snapshot_version", "channel_cert", "uk_cert", "item_hash"]
    static let payload: [String: Set<String>] = [
        "question.answered": ["question", "hash", "option", "text"],
        "gate.approved": ["gate", "hash", "gate_gen", "policy_hash", "source_sha"],
        "gate.changes_requested": ["gate", "hash", "gate_gen", "policy_hash", "text"],
        "verdict.given": ["outcome", "hash", "text", "gate_gen", "policy_hash", "source_sha"],
    ]
    static let gates: Set<String> = ["requirements", "plan", "code"]

    /// The facts of a prepared request. Throws `malformed` for anything that is not one of the four decision types with the fields its type
    /// requires (the phone shows a sentence only for shapes it understands, and refuses to ask for a signature on a decision it cannot read).
    public static func facts(ctx: JSONValue) throws -> Facts {
        guard let c = ctx.object, let ws = c["workspace_id"]?.string, let log = c["log"]?.string, let e = c["event"]?.object,
              let type = e["type"]?.string, isDecisionType(type), isULID(log) else { throw Refusal.malformed }
        let known = envelope.union(payload.first { $0.key.bytesEqual(type) }?.value ?? [])
        let unknown = e.keys.contains { !known.contains($0) }
        func str(_ k: String) -> String? { e[k]?.string }
        guard let hash = str("hash"), let short = shortHash(hash) else { throw Refusal.malformed }
        var gate: String?, gen: Int64?, sources: [Source] = []
        if !"question.answered".bytesEqual(type) {
            // a verdict is on the verify gate (it has no `gate` field); the two gate decisions name one of the three gates
            let g = type == "verdict.given" ? "verify" : (str("gate") ?? "")
            guard type == "verdict.given" || gates.contains(g), let n = e["gate_gen"]?.int, n >= 0, let p = str("policy_hash"), isHash(p)
            else { throw Refusal.malformed }
            gate = g; gen = n
            let needsSource = type == "verdict.given" || g == "code"
            if needsSource {
                guard let list = e["source_sha"]?.array, !list.isEmpty else { throw Refusal.malformed }
                for item in list {
                    guard let o = item.object, let repo = o["repo"]?.string, let sha = o["sha"]?.string,
                          sha.utf8.count >= 7, sha.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) })
                    else { throw Refusal.malformed }
                    sources.append(Source(repo: renderText(repo), sha: String(sha.prefix(8))))
                }
            } else if e["source_sha"] != nil { throw Refusal.malformed }
        }
        var sentence: String?
        switch type {
        case "question.answered":
            guard let q = str("question"), q.hasPrefix("Q"), q.dropFirst().allSatisfy(\.isASCII), q.dropFirst().allSatisfy(\.isNumber), q.count > 1,
                  str("option") != nil || str("text") != nil else { throw Refusal.malformed }
            sentence = "Answer question \(renderText(q)): \(renderText(str("option") ?? str("text") ?? ""))"
        case "gate.approved":
            sentence = "Approve the \(renderText(gate ?? "")) gate"
        case "gate.changes_requested":
            guard let t = str("text") else { throw Refusal.malformed }
            sentence = "Ask for changes on the \(renderText(gate ?? "")) gate: \(renderText(t))"
        default:
            guard let o = str("outcome") else { throw Refusal.malformed }
            sentence = "Give the verdict “\(renderText(o))”" + (str("text").map { ": " + renderText($0) } ?? "")
        }
        let fields = e.keys.sorted().map { k in Field(name: renderText(k), value: render(e[k]!, key: k)) }
        return Facts(type: type, log: log, workspaceID: ws, sentence: unknown ? nil : sentence, gate: gate, shortHash: short, gateGen: gen,
                     sources: sources, fields: fields, hasUnknownField: unknown)
    }

    static func render(_ v: JSONValue, key: String) -> String {
        if key == "channel_cert" || key == "uk_cert" { return "signed certificate" }
        switch v {
        case .null: return "none"
        case .bool(let b): return b ? "yes" : "no"
        case .int(let i): return String(i)
        case .string(let s): return renderText(s)
        case .array, .object: return renderText((try? canonicalJSON(v)).map { String(decoding: $0, as: UTF8.self) } ?? "?")
        }
    }
}
