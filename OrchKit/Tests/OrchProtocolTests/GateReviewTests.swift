import Foundation
import Testing
@testable import OrchProtocol

/// B10 phase 1: the phone recomputes section and gate hashes from what the host sends and refuses on any difference; the plain view follows the
/// B6 SignContent rules; the gate events it builds validate. Known answers: orch-core `f1/gate_hash.json` and `f1/hashes.json` (PROVENANCE.md).
@Suite struct GateReviewTests {
    let kat = F1Vectors.load("gate_hash")
    let hashes = F1Vectors.load("hashes")
    let base = "sha256:" + String(repeating: "a", count: 64)
    let id = "01M4JM4RKG79RG3QTWCP60NNNG"

    func me(_ auth: F1Auth = .secureEnclaveUnlocked) throws -> PhoneActor {
        try PhoneActor(person: ID16(hex: String(repeating: "1", count: 32))!, device: ID16(hex: String(repeating: "2", count: 32))!, auth: auth)
    }

    /// A case of the gate_hash vector as a verify call, with section texts from its ticket.
    func verified(_ index: Int, mutate: (inout [String: JSONValue]) -> Void = { _ in }, texts mutateTexts: (inout [String: String]) -> Void = { _ in },
                  claimedHash: String? = nil) throws -> GateReview.Verified {
        let c = kat["gate_hash"][index]
        var g = c["G"].object!
        let hash = c["hash"].str
        mutate(&g)
        var texts: [String: String] = [:]
        for (k, v) in c["ticket"]["sections"].object! { texts[k] = v.str }
        mutateTexts(&texts)
        return try GateReview.verify(ticketUID: g["uid"]!.string!, gate: g["gate"]!.string!, workspace: ID16(hex: g["workspace_id"]!.string!)!,
                                     claimedHash: claimedHash ?? hash, claimedPolicyHash: g["policy_hash"]!.string!, gen: 1, input: .object(g),
                                     sectionTexts: texts, basedOn: base, rosterV: 3)
    }

    @Test func gateHashKnownAnswers() throws {
        for c in kat["gate_hash"].items {
            #expect(try GateReview.gateHash(c["G"]) == c["hash"].str, "\(c["name"].str)")
            #expect(Hex.encode(try canonicalJSON(c["G"])) == c["cj_hex"].str)
        }
    }

    @Test func sectionHashKnownAnswers() throws {
        for c in hashes["section_hash"].items { #expect(try GateReview.sectionHash(c["text"].str) == c["hash"].str, "\(c["text"].str)") }
        for t in hashes["section_hash_refused"].items where t.string != nil && t.str.utf8.count < 100 {
            #expect(throws: GateReview.Failure.self) { try GateReview.sectionHash(t.str) }
        }
    }

    @Test func requirementsAndPlanVerifyAgainstTheirTexts() throws {
        let r = try verified(0)
        #expect(r.gate == "requirements" && r.texts["requirements"] == "- R1 caf\u{E9}\n![mock](artifact:mock.png)")
        let p = try verified(1)
        #expect(p.gate == "plan" && p.texts["plan"] == "1. export\n2. seed")
    }

    @Test func aChangedTextIsRefused() {
        #expect(throws: GateReview.Failure.mismatch("section requirements")) { try verified(0, texts: { $0["requirements"] = "- R1 caf\u{E9} (changed)" }) }
        // a missing section text is the hash of "" and does not match
        #expect(throws: GateReview.Failure.self) { try verified(0, texts: { $0["requirements"] = nil }) }
        // a text the section rules refuse is not hashed
        #expect(throws: GateReview.Failure.shape("section text")) { try verified(0, texts: { $0["summary"] = "x\n" }) }
    }

    @Test func aHostHashThatIsNotTheRecomputedOneIsRefused() {
        #expect(throws: GateReview.Failure.mismatch("hash")) { try verified(0, claimedHash: "sha256:" + String(repeating: "0", count: 64)) }
        // G changed after the host hashed it: the section hashes still match, the gate hash does not
        #expect(throws: GateReview.Failure.mismatch("hash")) {
            try verified(0, mutate: { g in var f = g["fields"]!.object!; f["size"] = "xl"; g["fields"] = .object(f) })
        }
        #expect(throws: GateReview.Failure.mismatch("hash")) { try verified(0, mutate: { $0["people_hash"] = .string("sha256:" + String(repeating: "1", count: 64)) }) }
    }

    @Test func gMustNameThisTicketGateAndWorkspace() throws {
        let c = kat["gate_hash"][0]
        var g = c["G"].object!
        let ws = ID16(hex: g["workspace_id"]!.string!)!
        func go(uid: String? = nil, gate: String = "requirements", workspace: ID16? = nil, schema: String? = nil) throws {
            var gg = g
            if let schema { gg["schema"] = .string(schema) }
            _ = try GateReview.verify(ticketUID: uid ?? g["uid"]!.string!, gate: gate, workspace: workspace ?? ws, claimedHash: c["hash"].str,
                                      claimedPolicyHash: g["policy_hash"]!.string!, gen: 1, input: .object(gg), sectionTexts: [:], basedOn: base, rosterV: 1)
        }
        #expect(throws: GateReview.Failure.mismatch("identity")) { try go(uid: "01J9ZK4Q7M3R8T2V6X0B5N1C9E") }
        #expect(throws: GateReview.Failure.mismatch("identity")) { try go(gate: "plan") }
        #expect(throws: GateReview.Failure.mismatch("identity")) { try go(workspace: ID16(hex: String(repeating: "7", count: 32))!) }
        #expect(throws: GateReview.Failure.mismatch("identity")) { try go(schema: "orch.ticket/3") }
        // a G with a key missing or added
        g["extra"] = 1
        #expect(throws: GateReview.Failure.shape("fields")) { try go() }
    }

    @Test func onlyRequirementsAndPlanAreOffered() throws {
        for i in [2, 3] {   // verify, code
            let c = kat["gate_hash"][i]
            #expect(throws: GateReview.Failure.notAPhoneGate) {
                try GateReview.verify(ticketUID: c["G"]["uid"].str, gate: c["G"]["gate"].str, workspace: ID16(hex: c["G"]["workspace_id"].str)!,
                                      claimedHash: c["hash"].str, claimedPolicyHash: c["G"]["policy_hash"].str, gen: 1, input: c["G"], sectionTexts: [:],
                                      basedOn: base, rosterV: 1)
            }
        }
        #expect(GateReview.isPhoneGate("requirements") && GateReview.isPhoneGate("plan"))
        #expect(!GateReview.isPhoneGate("code") && !GateReview.isPhoneGate("verify") && !GateReview.isPhoneGate("verdict.given"))
    }

    // MARK: the plain view

    /// A requirements gate with nothing outside the plain view: no artifacts, no prior, no links.
    func plain(mutate: (inout [String: JSONValue]) -> Void = { _ in }, texts: [String: String]? = nil) throws -> GateReview.Verified {
        let c = kat["gate_hash"][0]
        var g = c["G"].object!
        g["artifacts"] = [:]
        mutate(&g)
        var t: [String: String] = [:]
        for (k, v) in c["ticket"]["sections"].object! { t[k] = v.str }
        t["requirements"] = "- R1\nsecond line"
        if let texts { for (k, v) in texts { t[k] = v } }
        var secs: [String: JSONValue] = [:]
        for k in g["sections"]!.object!.keys { secs[k] = .string(try GateReview.sectionHash(t[k] ?? "")) }
        g["sections"] = .object(secs)
        return try GateReview.verify(ticketUID: g["uid"]!.string!, gate: "requirements", workspace: ID16(hex: g["workspace_id"]!.string!)!,
                                     claimedHash: try GateReview.gateHash(.object(g)), claimedPolicyHash: g["policy_hash"]!.string!, gen: 1, input: .object(g),
                                     sectionTexts: t, basedOn: base, rosterV: 3)
    }

    @Test func aPlainGateShowsSectionsAcceptanceAndTypeWithoutTheFullReview() throws {
        let c = GateReview.content(of: try plain())
        #expect(!c.fullReview && c.fullReviewReasons.isEmpty)
        #expect(c.sections.map(\.id) == ["context", "out_of_scope", "requirements", "summary"])
        #expect(c.sections.first { $0.id == "requirements" }?.text == "- R1\nsecond line")   // a block keeps its lines
        #expect(c.sections.first { $0.id == "out_of_scope" }?.title == "Out of scope")
        #expect(c.acceptance.map(\.id) == ["AC1", "AC2"])
        #expect(c.rows.contains(GateReview.Row(field: "Type", value: "feature")))
        #expect(c.rawLines.count == 15 && c.rawLines.first?.hasPrefix("addon_packages: ") == true)
    }

    @Test func oneLineValuesShowLineBreaksVisibly() throws {
        let v = try plain(mutate: { g in
            var f = g["fields"]!.object!
            f["acceptance"] = [["id": "AC1", "text": "first\nAC2 fake"]]
            g["fields"] = .object(f)
        })
        let c = GateReview.content(of: v)
        #expect(c.acceptance == [GateReview.Criterion(id: "AC1", text: "first \u{23CE} AC2 fake")])
        #expect(!c.acceptance[0].text.contains("\n"))
        #expect(GateReview.oneLine("a\r\nb\rc") == "a \u{23CE} b \u{23CE} c")
    }

    @Test func tasksShowTheirVerifyCommandAndWhatTheyProve() throws {
        let c = GateReview.content(of: try plain(mutate: { g in
            g["tasks"] = [["id": "T1", "text": "Export\nCSVs", "proves": ["AC1"], "verify": ["cmd": "ls | wc -l"]]]
        }))
        #expect(c.tasks == [GateReview.TaskRow(n: 1, id: "T1", title: "Export \u{23CE} CSVs (proves AC1)", verify: ["ls | wc -l"])])
        #expect(!c.fullReview)
    }

    @Test func anythingOutsideThePlainViewIsTheFullReview() throws {
        // contract (b): links, add-ons, packages, files, results, source, earlier gates
        let c0 = GateReview.content(of: try verified(0))
        #expect(c0.fullReview && c0.fullReviewReasons.contains("files"))
        // an unknown key of a field, a criterion or a task
        #expect(GateReview.content(of: try plain(mutate: { g in var f = g["fields"]!.object!; f["flavour"] = "x"; g["fields"] = .object(f) })).fullReview)
        #expect(GateReview.content(of: try plain(mutate: { g in
            var f = g["fields"]!.object!; f["acceptance"] = [["id": "AC1", "text": "t", "evidence": "x"]]; g["fields"] = .object(f)
        })).fullReview)
        #expect(GateReview.content(of: try plain(mutate: { g in g["tasks"] = [["id": "T1", "text": "x", "assignee": "p_1"]] })).fullReview)
        #expect(GateReview.content(of: try plain(mutate: { g in
            var f = g["fields"]!.object!; f["links"] = ["repos": []]; g["fields"] = .object(f)
        })).fullReview)
    }

    // MARK: shape, duplicates and the earlier gate (Opus final review)

    func fullReasons(_ mutate: @escaping (inout [String: JSONValue]) -> Void) throws -> [String] {
        let c = GateReview.content(of: try plain(mutate: mutate))
        return c.fullReview ? c.fullReviewReasons : []
    }

    @Test func aWrongTypeIsTheFullReviewNotAnEmptyPlainView() throws {
        func fields(_ f: @escaping (inout [String: JSONValue]) -> Void) -> (inout [String: JSONValue]) -> Void {
            { g in var o = g["fields"]!.object!; f(&o); g["fields"] = .object(o) }
        }
        let cases: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("fields not an object", { $0["fields"] = [] }),
            ("acceptance not an array", fields { $0["acceptance"] = "AC1" }),
            ("addons not an object", fields { $0["addons"] = [] }),
            ("tasks not an array", { $0["tasks"] = "x" }),
            ("artifacts not an object", { $0["artifacts"] = [] }),
            ("receipts not an object", { $0["receipts"] = "x" }),
            ("addon_packages not an object", { $0["addon_packages"] = [] }),
            ("source_sha not an array", { $0["source_sha"] = [:] }),
            ("prior not an object", { $0["prior"] = [] }),
            ("proves item not a string", { $0["tasks"] = [["id": "T1", "text": "x", "proves": ["AC1", 3]]] }),
            ("proves not an array", { $0["tasks"] = [["id": "T1", "text": "x", "proves": "AC1"]] }),
            ("verify.cmd not a string", { $0["tasks"] = [["id": "T1", "text": "x", "verify": ["cmd": 5]]] }),
        ]
        for (name, m) in cases { #expect(try !fullReasons(m).isEmpty, "\(name)") }
    }

    @Test func repeatedCriterionIdsAreTheFullReview() throws {
        let r = try fullReasons { g in
            var f = g["fields"]!.object!
            f["acceptance"] = [["id": "AC1", "text": "one"], ["id": "AC1", "text": "two"]]; g["fields"] = .object(f)
        }
        #expect(r == ["repeated criterion id"])
    }

    func plan(mutate: (inout [String: JSONValue]) -> Void = { _ in }) throws -> GateReview.Verified {
        let c = kat["gate_hash"][1]
        var g = c["G"].object!
        // the vector's plan carries an estimate add-on (a full review of its own); the plain plan has none
        var f = g["fields"]!.object!; f["addons"] = [:]; g["fields"] = .object(f); g["addon_packages"] = [:]
        mutate(&g)
        var t: [String: String] = [:]
        for (k, v) in c["ticket"]["sections"].object! { t[k] = v.str }
        return try GateReview.verify(ticketUID: g["uid"]!.string!, gate: "plan", workspace: ID16(hex: g["workspace_id"]!.string!)!,
                                     claimedHash: try GateReview.gateHash(.object(g)), claimedPolicyHash: g["policy_hash"]!.string!, gen: 1, input: .object(g),
                                     sectionTexts: t, basedOn: base, rosterV: 3)
    }
    let ulidA = "01J9ZP0000000000000000000A", ulidB = "01J9ZP0000000000000000000B"

    @Test func aNormalPlanShowsTheEarlierGateAsAVerifiedRowWithoutTheFullReview() throws {
        let c = GateReview.content(of: try plan())
        #expect(!c.fullReview)
        #expect(c.rows.contains(GateReview.Row(field: "Requirements, approved before", value: "generation 2, 1 approval")))
        // not listed by the host: only the tail of the id, never a person
        #expect(c.rows.contains(GateReview.Row(field: "Approval", value: "approval 00000A (not listed by the host)")))
        #expect(!c.rows.contains { $0.value.contains("approved by") })
        // listed by the host: the person, always with the per-host label
        let named = GateReview.content(of: try plan(), persons: [ulidA: "p_abc"])
        #expect(named.rows.contains(GateReview.Row(field: "Approval", value: "p_abc (per host, not signed)")))
        #expect(named.rawLines.contains { $0.hasPrefix("prior: ") && $0.contains(ulidA) })   // ids stay in "Everything that is signed"
        // no approvals counted
        let none = GateReview.content(of: try plan { $0["prior"] = ["requirements": ["gen": 0, "approvals": []]] })
        #expect(!none.fullReview && none.rows.contains(GateReview.Row(field: "Requirements, approved before", value: "generation 0, no approvals counted")))
        let two = GateReview.content(of: try plan { $0["prior"] = ["requirements": ["gen": 3, "approvals": [.string(ulidA), .string(ulidB)]]] })
        #expect(two.rows.first?.value == nil || two.rows.contains(GateReview.Row(field: "Requirements, approved before", value: "generation 3, 2 approvals")))
    }

    @Test func aPriorOutsideTheKnownShapeIsTheFullReview() throws {
        let many = (0..<33).map { JSONValue.string(String(format: "01J9ZP00000000000000%06d", $0)) }
        let bad: [(String, JSONValue)] = [
            ("another gate", ["code": ["gen": 1, "approvals": []]]),
            ("extra key in the entry", ["requirements": ["gen": 1, "approvals": [], "x": 1]]),
            ("missing gen", ["requirements": ["approvals": []]]),
            ("negative gen", ["requirements": ["gen": -1, "approvals": []]]),
            ("gen not an integer", ["requirements": ["gen": "2", "approvals": []]]),
            ("approvals not an array", ["requirements": ["gen": 1, "approvals": "x"]]),
            ("not a ULID", ["requirements": ["gen": 1, "approvals": ["nope"]]]),
            ("unsorted", ["requirements": ["gen": 1, "approvals": [.string(ulidB), .string(ulidA)]]]),
            ("duplicate", ["requirements": ["gen": 1, "approvals": [.string(ulidA), .string(ulidA)]]]),
            ("too many", ["requirements": ["gen": 1, "approvals": .array(many)]]),
        ]
        for (name, prior) in bad {
            let c = GateReview.content(of: try plan { $0["prior"] = prior })
            #expect(c.fullReview && c.fullReviewReasons.contains("earlier gates"), "\(name)")
        }
        // a requirements gate has no earlier gate at all
        #expect(try fullReasons { $0["prior"] = ["requirements": ["gen": 1, "approvals": []]] } == ["earlier gates"])
    }

    @Test func aTamperedPriorIsAHashMismatch() {
        #expect(throws: GateReview.Failure.mismatch("hash")) {
            try verified(1, mutate: { g in g["prior"] = ["requirements": ["gen": 2, "approvals": [.string(self.ulidA), .string(self.ulidB)]]] })
        }
    }

    // MARK: the events

    @Test func approveAndChangesBuildAndValidate() throws {
        let g = try plain()
        let wsid = g.workspace
        let signer = SoftwareSigner()
        let a = try me()
        let u = try PhoneEvents.unsignedGateDecision(g, approve: true, text: nil, id: id, actor: a, workspace: wsid)
        #expect(Set(u.event.keys) == ["v", "hash_v", "id", "type", "actor", "auth", "roster_v", "based_on", "gate", "gate_gen", "hash", "policy_hash"])
        #expect(u.event["type"]?.string == "gate.approved" && u.event["gate"]?.string == "requirements" && u.event["gate_gen"] == .int(1))
        #expect(u.event["hash"]?.string == g.hash && u.event["policy_hash"]?.string == g.policyHash && u.event["based_on"]?.string == base)
        #expect(u.log == g.ticketUID && u.event["roster_v"] == .int(3) && u.event["auth"]?.string == "secure-enclave-unlocked")
        let e = try PhoneEvents.sign(u, signer: signer)
        try PhoneEvents.validateSigned(e, kind: .gateApproved, actor: a, workspace: wsid, pub: signer.publicKey)
        #expect(e.event["source_sha"] == nil)

        let text = try PhoneEvents.prepareText("Please split\nthe plan.", oneLine: false)
        let ch = try PhoneEvents.sign(try PhoneEvents.unsignedGateDecision(g, approve: false, text: text, id: id, actor: a, workspace: wsid), signer: signer)
        try PhoneEvents.validateSigned(ch, kind: .gateChangesRequested, actor: a, workspace: wsid, pub: signer.publicKey)
        #expect(ch.event["text"]?.string == "Please split\nthe plan." && ch.event["type"]?.string == "gate.changes_requested")
    }

    @Test func aDecisionIsBuiltOnlyFromWhatWasVerified() throws {
        let g = try plain()
        let a = try me()
        let w = g.workspace
        // changes needs text; approve takes none
        #expect(throws: PhoneEvents.Failure.emptyText) { try PhoneEvents.unsignedGateDecision(g, approve: false, text: nil, id: id, actor: a, workspace: w) }
        #expect(throws: PhoneEvents.Failure.emptyText) {
            try PhoneEvents.unsignedGateDecision(g, approve: false, text: try PhoneEvents.prepareText("", oneLine: false), id: id, actor: a, workspace: w)
        }
        #expect(throws: PhoneEvents.Failure.textTooLong) {
            try PhoneEvents.unsignedGateDecision(g, approve: false, text: try PhoneEvents.prepareText(String(repeating: "x", count: 4097), oneLine: false), id: id, actor: a, workspace: w)
        }
        #expect(throws: PhoneEvents.Failure.schema("text")) {
            try PhoneEvents.unsignedGateDecision(g, approve: true, text: try PhoneEvents.prepareText("x", oneLine: false), id: id, actor: a, workspace: w)
        }
        // convenience is op.not_allowed on a gate event: never built (the passphrase value is the Simulator/Demo one)
        #if DEBUG && targetEnvironment(simulator)
        #expect(throws: PhoneEvents.Failure.actorMismatch) { try PhoneEvents.unsignedGateDecision(g, approve: true, text: nil, id: id, actor: try me(.convenience), workspace: w) }
        #endif
        // another workspace than G's
        #expect(throws: PhoneEvents.Failure.schema("workspace")) {
            try PhoneEvents.unsignedGateDecision(g, approve: true, text: nil, id: id, actor: a, workspace: ID16(hex: String(repeating: "9", count: 32))!)
        }
        #expect(throws: PhoneEvents.Failure.badID) { try PhoneEvents.unsignedGateDecision(g, approve: true, text: nil, id: "x", actor: a, workspace: w) }
    }

    @Test func aTamperedGateEventDoesNotValidate() throws {
        let g = try plain()
        let signer = SoftwareSigner()
        let a = try me()
        let e = try PhoneEvents.sign(try PhoneEvents.unsignedGateDecision(g, approve: true, text: nil, id: id, actor: a, workspace: g.workspace), signer: signer)
        func resign(_ f: (inout [String: JSONValue]) -> Void) throws -> SignedPhoneEvent {
            var ev = e.event; ev["sig"] = nil; f(&ev)
            let bytes = try PhoneEvents.signingBytes(event: ev, log: e.log, workspace: g.workspace)
            let sig = try Signature.sign(signer, label: Label.sigTicketEvent, message: Data(bytes.dropFirst(Label.sigTicketEvent.utf8.count)))
            ev["sig"] = .string(B64U.encode(sig))
            return SignedPhoneEvent(kind: .gateApproved, log: e.log, id: id, event: ev, bytes: try canonicalJSON(.object(ev)), signingBytes: bytes,
                                    digest: PhoneEvents.digest(signingBytes: bytes), signature: sig)
        }
        for f: (inout [String: JSONValue]) -> Void in [{ $0["source_sha"] = [] }, { $0["gate"] = "code" }, { $0["gate_gen"] = -1 }, { $0["hash"] = "x" },
                                                       { $0["text"] = "x" }, { $0["seq"] = 1 }] {
            #expect(throws: PhoneEvents.Failure.self) {
                try PhoneEvents.validateSigned(try resign(f), kind: .gateApproved, actor: a, workspace: g.workspace, pub: signer.publicKey)
            }
        }
    }
}
