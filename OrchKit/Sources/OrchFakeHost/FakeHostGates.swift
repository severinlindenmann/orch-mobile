import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

// B10 phase 1 in the FakeHost: a requirements and a plan gate on a seeded ticket, `gate.input`, `phone.requests`, and the judgement of
// `approve` / `changes` (core #628 contract (b), (c)). Written from the contract and independent of the phone's `GateReview`: the hash
// formulas are spelled out here again, so a fault shared with the phone's recomputation cannot make both sides agree.

struct FakeDecisionRec: Sendable, Equatable {
    var id: String, kind: String, person: String
    var seq: Int64, gen: Int64
}

struct FakeGate: Sendable, Equatable {
    var gen: Int64 = 1
    var decisions: [FakeDecisionRec] = []
}

/// The gates of one ticket and the content they hash.
struct FakeGateSet: Sendable, Equatable {
    var requirements = FakeGate()
    var plan = FakeGate()
    var texts: [String: String]
    var acceptance: [[String: String]] = [["id": "AC1", "text": "Seeds load"]]
    var tasks: [JSONValue] = [["id": "T1", "text": "Export the CSVs", "proves": ["AC1"], "verify": ["cmd": "ls seeds | wc -l"]]]
    var ticketType = "feature"
    /// Non-empty makes the requirements gate carry a file (so the phone must show the full review).
    var artifacts: JSONValue = [:]

    static let requirementsSections = ["context", "out_of_scope", "requirements", "summary"]
    static let planSections = ["decisions", "plan"]

    init() {
        texts = ["context": "", "out_of_scope": "Nothing.", "requirements": "- R1 caf\u{E9}\nsecond line", "summary": "Load the tariffs.",
                 "decisions": "", "plan": "1. export\n2. seed"]
    }
}

struct FakeHint: Sendable, Equatable {
    var id: String, uid: String, ref: String, title: String, gate: String, gateGen: Int64
    var createdMs: Int64, expiresMs: Int64
}

/// Test controls: the host says something that is not true. Each is a persistent switch.
package struct FakeGateLies: Sendable, Equatable {
    /// `gate.input` claims this hash instead of the real one.
    package var hash: String?
    /// `ticket.get` shows this text for the section while `gate.input` hashes the real one.
    package var sectionText: [String: String] = [:]
    /// `gate.input` answers `invalid.input` (a gate that cannot be hashed right now).
    package var cannotHash = false
    /// `gate.input` names another ticket.
    package var otherUID = false
    /// Devices whose gate events the model refuses at append with `device.invalid`.
    package var deviceInvalid: Set<String> = []
    package init() {}
}

extension FakeHost {
    static let gateLabel = "orch/v2/gate|", sectionLabel = "orch/v2/section|"

    private var fakePolicy: JSONValue { ["approvers": ["owner"], "count": 1, "not": [], "applies": "all", "independent": false] }
    private var fakePolicyHash: String { "sha256:" + Hex.encode(SHA256.hash(data: Data("policy:fake".utf8))) }
    private var fakePeopleHash: String { "sha256:" + Hex.encode(SHA256.hash(data: Data("people:fake".utf8))) }

    func sectionHashOf(_ text: String) -> String { "sha256:" + Hex.encode(SHA256.hash(data: Data((Self.sectionLabel + text).utf8))) }

    func gateSectionTexts(_ g: FakeGateSet) -> [String: String] {
        var t = g.texts
        for (k, v) in viewState!.gateLies.sectionText { t[k] = v }
        return t
    }

    /// G of one gate (ticket-format 5.7): the 15 keys.
    func gateG(uid: String, gate: String, _ g: FakeGateSet) -> JSONValue {
        let ids = gate == "plan" ? FakeGateSet.planSections : FakeGateSet.requirementsSections
        var sections: [String: JSONValue] = [:]
        for id in ids { sections[id] = .string(sectionHashOf(g.texts[id] ?? "")) }
        var prior: JSONValue = [:]
        if gate == "plan" { prior = [:] }
        return ["workspace_id": .string(workspace.hex), "uid": .string(uid), "gate": .string(gate), "schema": "orch.ticket/2", "hash_v": 1,
                "sections": .object(sections),
                "fields": ["ticket_type": .string(g.ticketType), "size": "m", "acceptance": .array(g.acceptance.map { ["id": .string($0["id"] ?? ""), "text": .string($0["text"] ?? "")] }),
                           "links": .null, "addons": [:]],
                "addon_packages": [:], "tasks": gate == "plan" ? .array(g.tasks) : [], "artifacts": gate == "requirements" ? g.artifacts : [:], "receipts": [:],
                "source_sha": [], "prior": prior, "policy_hash": .string(fakePolicyHash), "people_hash": .string(fakePeopleHash)]
    }

    func gateHashOf(_ g: JSONValue) -> String {
        "sha256:" + Hex.encode(SHA256.hash(data: Data(Self.gateLabel.utf8) + ((try? canonicalJSON(g)) ?? Data())))
    }

    func gatesJSON(_ uid: String) -> JSONValue {
        guard let g = viewState!.gates[uid] else { return [:] }
        func one(_ name: String, _ fg: FakeGate) -> JSONValue {
            ["state": "open", "gen": .int(fg.gen), "applies": true, "waiting": false, "blocked": false, "count": 1, "approved_by": [], "eligible": [.string(viewer)],
             "policy": fakePolicy, "missing": [],
             "decisions": .array(fg.decisions.map { ["id": .string($0.id), "kind": .string($0.kind), "person": .string($0.person), "at": .string(Self.time(wall.nowMs)),
                                                    "seq": .int($0.seq), "gen": .int($0.gen), "counting": true, "voided": false] }),
             "hash": .string(gateHashOf(gateG(uid: uid, gate: name, g))), "policy_hash": .string(fakePolicyHash)]
        }
        return ["requirements": one("requirements", g.requirements), "plan": one("plan", g.plan)]
    }

    func gateInputReply(args: [String: JSONValue]) -> HostReply {
        let s = viewState!
        guard let ref = args["ref"]?.string, let gate = args["gate"]?.string, let t = s.tickets.first(where: { $0.key == ref || $0.uid == ref }) else { return hostRefusal("not_found") }
        guard gate == "requirements" || gate == "plan" else { return hostRefusal("invalid.input") }
        guard let g = s.gates[t.uid] else { return hostRefusal("gate.not_applicable") }
        if s.gateLies.cannotHash { return hostRefusal("invalid.input") }
        var input = gateG(uid: t.uid, gate: gate, g)
        let real = gateHashOf(input)
        if s.gateLies.otherUID, var o = input.object { o["uid"] = .string(HostViewState.newULID(entropy, wall.nowMs)); input = .object(o) }
        return result(["ref": .string(t.uid), "gate": .string(gate), "gen": .int(gate == "plan" ? g.plan.gen : g.requirements.gen), "hash": .string(s.gateLies.hash ?? real),
                       "policy_hash": .string(fakePolicyHash), "input": input])
    }

    func phoneRequestsReply(scopes: [String]) -> HostReply {
        let now = wall.nowMs
        let open = viewState!.hints.filter { $0.expiresMs > now }
        return result(["requests": .array(open.map { ["id": .string($0.id), "uid": .string($0.uid), "ref": .string($0.ref), "title": .string($0.title), "gate": .string($0.gate),
                                                       "gate_gen": .int($0.gateGen), "created_at": .string(Self.time($0.createdMs)), "expires_at": .string(Self.time($0.expiresMs))] }),
                       "now": .string(Self.time(now))])
    }

    /// The model's judgement of a gate decision at the position (core #628 contract (c), in the order it lists): ticket visible, device standing
    /// at append, roster, then the gate (kind, generation, policy, hash).
    func judgeGate(log: String, roster: Int64, base: String, gate: String, gen: Int64, hash: String, policyHash: String, device: String) -> String? {
        let s = viewState!
        guard let ticket = s.tickets.first(where: { $0.uid == log }), let g = s.gates[log] else { return "not_found" }
        if s.gateLies.deviceInvalid.contains(device) { return "device.invalid" }
        let history = (1...max(ticket.headSeq, 1)).map { "sha256:" + Hex.encode(SHA256.hash(data: Data((ticket.uid + String($0)).utf8))) }
        guard history.contains(base) else { return "event.bad_base" }
        guard roster == s.membersV else { return "members.stale" }
        guard gate == "requirements" || gate == "plan" else { return "op.not_allowed" }
        let current = gate == "plan" ? g.plan.gen : g.requirements.gen
        guard gen == current else { return "gate.stale" }
        guard policyHash == fakePolicyHash else { return "gate.stale" }
        guard hash == gateHashOf(gateG(uid: log, gate: gate, g)) else { return "gate.stale" }
        return nil
    }

    func appendGateDecision(log: String, ev: [String: JSONValue], digest: String, device: String) -> Int64 {
        let now = wall.nowMs
        guard let ticket = viewState!.tickets.first(where: { $0.uid == log }) else { return 0 }
        viewState!.touch(ticket.key, type: ev["type"]?.string ?? "gate.approved", at: now)
        let seq = viewState!.tickets.first { $0.uid == ticket.uid }!.headSeq
        let gate = ev["gate"]?.string ?? "", id = ev["id"]?.string ?? ""
        let rec = FakeDecisionRec(id: id, kind: ev["type"]?.string == "gate.approved" ? "approve" : "changes", person: ownerPersonID, seq: seq, gen: ev["gate_gen"]?.int ?? 0)
        if gate == "plan" { viewState!.gates[log]?.plan.decisions.append(rec) } else { viewState!.gates[log]?.requirements.decisions.append(rec) }
        viewState!.logged[id] = FakeLogged(log: log, digest: digest, actor: ev["actor"] ?? .null, seq: seq)
        viewState!.hints.removeAll { $0.uid == log && $0.gate == gate }
        return seq
    }

    private var ownerPersonID: String { "p_" + primary.personID.hex }

    // MARK: Demo and test controls

    /// A requirements and a plan gate on `ticket` (the ticket must exist), with seeded content.
    package func demoSeedGates(ticket key: String) {
        seedViews()
        if let t = viewState!.tickets.first(where: { $0.key == key }) { viewState!.gates[t.uid] = FakeGateSet() }
    }
    /// The Mac asks for an approval: one open hint (10 minutes).
    @discardableResult
    package func demoRequestApproval(ticket key: String, gate: String) -> String? {
        seedViews()
        guard let t = viewState!.tickets.first(where: { $0.key == key }), let g = viewState!.gates[t.uid] else { return nil }
        let id = "ph_" + HostViewState.newULID(entropy, wall.nowMs)
        viewState!.hints.append(FakeHint(id: id, uid: t.uid, ref: t.key, title: t.title, gate: gate, gateGen: gate == "plan" ? g.plan.gen : g.requirements.gen,
                                         createdMs: wall.nowMs, expiresMs: wall.nowMs + 600_000))
        return id
    }
    /// The ticket's section changes on the Mac: the content (and so the hash) moves and the gate generation with it.
    package func demoChangeGateText(ticket key: String, section: String, to text: String, gate: String = "requirements") {
        seedViews()
        guard let t = viewState!.tickets.first(where: { $0.key == key }) else { return }
        viewState!.gates[t.uid]?.texts[section] = text
        if gate == "plan" { viewState!.gates[t.uid]?.plan.gen += 1 } else { viewState!.gates[t.uid]?.requirements.gen += 1 }
    }
    package func demoSetGateArtifacts(ticket key: String, _ artifacts: JSONValue) {
        seedViews()
        if let t = viewState!.tickets.first(where: { $0.key == key }) { viewState!.gates[t.uid]?.artifacts = artifacts }
    }
    package func setGateLies(_ lies: FakeGateLies) { seedViews(); viewState!.gateLies = lies }
    package func gateDecisions(ticket key: String, gate: String) -> [(id: String, kind: String, gen: Int64)] {
        guard let t = viewState?.tickets.first(where: { $0.key == key }), let g = viewState?.gates[t.uid] else { return [] }
        return (gate == "plan" ? g.plan : g.requirements).decisions.map { ($0.id, $0.kind, $0.gen) }
    }
    package func openHints() -> [String] { viewState?.hints.map(\.id) ?? [] }
}
