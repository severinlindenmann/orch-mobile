import Foundation
import Testing
import OrchCustody
import OrchProtocol
@testable import OrchStore
@testable import OrchClient
@testable import OrchFakeHost

/// B10 phase 1 end to end against the FakeHost: the phone lists its approval requests, reads the gate, RECOMPUTES the section and gate hashes,
/// and only then builds, signs and sends `gate.approved` / `gate.changes_requested` (requirements and plan only). Anything the host says that
/// does not recompute is refused before a signature exists.
@Suite struct PersonEventGateTests {
    struct Rig {
        let w: World
        let p: Phone
        let api: BridgeWorkspaceAPI
        let hooks: Hooks
        let ops: OpCounter
    }

    func rig(gates: Bool = true) async throws -> Rig {
        let w = try await World.make()
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        let ops = OpCounter()
        let host = w.host
        await w.host.setHandler { req in
            ops.bump(req.meta.object?["op"]?.string ?? "?")
            return await host.handleView(req)
        }
        if gates { await w.host.demoSeedGates(ticket: "MOB-0001") }
        _ = try await w.serve(p) { try await api.snapshot() }
        let hooks = Hooks()
        await p.session.setCrashHook { try hooks.hit($0) }
        return Rig(w: w, p: p, api: api, hooks: hooks, ops: ops)
    }

    func review(_ r: Rig, _ gate: String = "requirements") async throws -> GateReviewSnapshot {
        let api = r.api
        return try await r.w.serve(r.p) { try await api.reviewGate(ref: "MOB-0001", gate: gate) }
    }
    func decide(_ r: Rig, _ s: GateReviewSnapshot, _ choice: GateChoice, steps: Int = 400) async throws -> WriteOutcome {
        let api = r.api
        return try await r.w.serve(r.p, steps: steps) { try await api.decideGate(s, choice: choice) }
    }
    func rows(_ p: Phone, _ sql: String) async throws -> [SQLRow] { try await p.container.database().query(sql, []) }

    // MARK: requests and the review

    @Test func requestsAreTheHostsWordAndListedFromPhoneRequests() async throws {
        let r = try await rig()
        let api = r.api
        #expect(try await r.w.serve(r.p) { try await api.phoneRequests() }.isEmpty)
        let id = try #require(await r.w.host.demoRequestApproval(ticket: "MOB-0001", gate: "requirements"))
        let list = try await r.w.serve(r.p) { try await api.phoneRequests() }
        #expect(list.count == 1 && list[0].id == id && list[0].ref == "MOB-0001" && list[0].gate == "requirements" && list[0].gateGen == 1)
        #expect(id.hasPrefix("ph_") && ULID.isValid(String(id.dropFirst(3))))
        // a request grants nothing: reviewing and signing do not need it
        let r2 = try await rig()
        let s = try await review(r2)
        #expect(s.ticketKey == "MOB-0001")
    }

    @Test func theReviewIsBuiltFromRecomputedContent() async throws {
        let r = try await rig()
        let s = try await review(r)
        #expect(s.gate == "requirements" && s.gateGen == 1 && s.ticketUID.count == 26)
        #expect(s.content.sections.map(\.id) == ["context", "out_of_scope", "requirements", "summary"])
        #expect(s.content.sections.first { $0.id == "requirements" }?.text == "- R1 caf\u{E9}\nsecond line")
        #expect(s.content.acceptance == [GateReview.Criterion(id: "AC1", text: "Seeds load")])
        #expect(s.content.rows.contains(GateReview.Row(field: "Type", value: "feature")))
        #expect(!s.content.fullReview)
        #expect(s.policyWords == "1 approval from owner; applies to all tickets")
        #expect(GateReviewSnapshot.perHost == "per host, not signed")
        // plan: tasks are shown, and the earlier-gate rule of the contract is the host's (prior is empty here)
        let p = try await review(r, "plan")
        #expect(p.content.tasks.map(\.id) == ["T1"] && p.content.tasks[0].verify == ["ls seeds | wc -l"])
        #expect(r.hooks.count("pe.sign") == 0)
    }

    @Test func aFileOnTheGateIsTheFullReview() async throws {
        let r = try await rig()
        await r.w.host.demoSetGateArtifacts(ticket: "MOB-0001", ["mock.png": ["kind": "screenshot", "digest": .string("sha256:" + String(repeating: "d", count: 64)), "ac": .null, "task": .null]])
        let s = try await review(r)
        #expect(s.content.fullReview && s.content.fullReviewReasons == ["files"])
        #expect(s.content.rawLines.contains { $0.hasPrefix("artifacts: ") && $0.contains("mock.png") })
    }

    // MARK: approving and requesting changes

    @Test func anApprovalLandsAndIsConfirmedFromTheLog() async throws {
        let r = try await rig()
        _ = await r.w.host.demoRequestApproval(ticket: "MOB-0001", gate: "requirements")
        let s = try await review(r)
        let out = try await decide(r, s, .approve)
        guard case .landed(let seq, let key) = out else { Issue.record("not landed: \(out)"); return }
        #expect(key == "MOB-0001" && seq >= 2)
        #expect(r.hooks.count("pe.sign") == 1 && r.ops.value("approve") == 1 && r.ops.value("changes") == 0)
        let rv = try #require(try await rows(r.p, "SELECT * FROM pe_reviews").first)
        #expect(rv.text("kind") == "gate" && rv.text("log") == s.ticketUID && rv.text("question") == "gate:\(s.ticketUID):requirements" && rv.text("state") == "landed")
        // the stored event is exactly the contract's: no source_sha, no host field, hash and policy_hash from the verified gate
        let ev = try #require(try await rows(r.p, "SELECT event FROM pe_attempts").first?.blob("event"))
        let e = try #require(try StrictJSON.parse(ev).object)
        #expect(Set(e.keys) == ["v", "hash_v", "id", "type", "actor", "auth", "roster_v", "based_on", "gate", "gate_gen", "hash", "policy_hash", "sig"])
        #expect(e["type"]?.string == "gate.approved" && e["hash"]?.string == s.verified.hash && e["policy_hash"]?.string == s.verified.policyHash && e["gate_gen"] == .int(1))
        #expect(await r.w.host.gateDecisions(ticket: "MOB-0001", gate: "requirements").map(\.kind) == ["approve"])
        #expect(await r.w.host.openHints().isEmpty)
        #expect(try await r.api.pendingWrites().isEmpty)
    }

    @Test func requestingChangesCarriesTheTypedText() async throws {
        let r = try await rig()
        let s = try await review(r, "plan")
        let out = try await decide(r, s, .changes(text: "Split\nthe plan"))
        guard case .landed = out else { Issue.record("not landed: \(out)"); return }
        #expect(r.ops.value("changes") == 1 && r.ops.value("approve") == 0)
        let ev = try #require(try await rows(r.p, "SELECT event FROM pe_attempts").first?.blob("event"))
        let e = try #require(try StrictJSON.parse(ev).object)
        #expect(e["type"]?.string == "gate.changes_requested" && e["text"]?.string == "Split\nthe plan" && e["gate"]?.string == "plan")
        #expect(await r.w.host.gateDecisions(ticket: "MOB-0001", gate: "plan").map(\.kind) == ["changes"])
    }

    @Test func textRulesAreCheckedBeforeAnythingIsSigned() async throws {
        let r = try await rig()
        let s = try await review(r)
        await #expect(throws: PhoneEvents.Failure.self) { _ = try await decide(r, s, .changes(text: "")) }
        await #expect(throws: PhoneEvents.Failure.self) { _ = try await decide(r, s, .changes(text: String(repeating: "x", count: 4097))) }
        await #expect(throws: PhoneEvents.Failure.self) { _ = try await decide(r, s, .changes(text: "a\u{202E}b")) }
        #expect(r.hooks.count("pe.sign") == 0)
        // a refused text does not use up the review
        let out = try await decide(r, s, .changes(text: "Fine"))
        guard case .landed = out else { Issue.record("not landed: \(out)"); return }
    }

    @Test func aReviewIsSignedOnce() async throws {
        let r = try await rig()
        let s = try await review(r)
        _ = try await decide(r, s, .approve)
        await #expect(throws: ViewError.invalidReview) { _ = try await decide(r, s, .approve) }
        #expect(r.hooks.count("pe.sign") == 1)
    }

    // MARK: the phone recomputes and refuses

    @Test func aHashTheHostClaimsButThePhoneCannotRecomputeIsRefused() async throws {
        let r = try await rig()
        await r.w.host.setGateLies({ var l = FakeGateLies(); l.hash = "sha256:" + String(repeating: "0", count: 64); return l }())
        await #expect(throws: GateReviewError.doesNotMatch) { _ = try await review(r) }
        #expect(r.hooks.count("pe.sign") == 0 && r.ops.value("approve") == 0)
        #expect(try await rows(r.p, "SELECT * FROM pe_reviews").isEmpty)
    }

    @Test func aSectionTextThatIsNotWhatWasHashedIsRefused() async throws {
        let r = try await rig()
        await r.w.host.setGateLies({ var l = FakeGateLies(); l.sectionText = ["requirements": "- R1 (the host shows other words)"]; return l }())
        await #expect(throws: GateReviewError.doesNotMatch) { _ = try await review(r) }
        #expect(r.hooks.count("pe.sign") == 0)
    }

    @Test func aGateOfAnotherTicketIsRefused() async throws {
        let r = try await rig()
        await r.w.host.setGateLies({ var l = FakeGateLies(); l.otherUID = true; return l }())
        await #expect(throws: GateReviewError.doesNotMatch) { _ = try await review(r) }
        #expect(r.hooks.count("pe.sign") == 0)
    }

    @Test func aGateTheHostCannotHashIsNotSignable() async throws {
        let r = try await rig()
        await r.w.host.setGateLies({ var l = FakeGateLies(); l.cannotHash = true; return l }())
        await #expect(throws: GateReviewError.cannotSignNow(code: "invalid.input")) { _ = try await review(r) }
        #expect(r.hooks.count("pe.sign") == 0)
    }

    @Test func onlyRequirementsAndPlanAreOffered() async throws {
        let r = try await rig()
        for gate in ["code", "verify", "verdict.given", ""] {
            let api = r.api
            await #expect(throws: GateReviewError.notOffered) { _ = try await r.w.serve(r.p) { try await api.reviewGate(ref: "MOB-0001", gate: gate) } }
        }
        #expect(r.ops.value("gate.input") == 0)
    }

    // MARK: stale, revoked, roster

    @Test func aGenerationThatMovedWhileYouLookedIsReviewedAgain() async throws {
        let r = try await rig()
        let s = try await review(r)
        await r.w.host.demoChangeGateText(ticket: "MOB-0001", section: "requirements", to: "- R1 changed on the Mac")
        let out = try await decide(r, s, .approve)
        #expect(out == .needsReview(.changed(code: "gate.stale")))
        #expect(try await rows(r.p, "SELECT state FROM pe_attempts").compactMap { $0.text("state") } == ["c_review"])
        #expect(await r.w.host.gateDecisions(ticket: "MOB-0001", gate: "requirements").isEmpty)
        // reopen: the new content is recomputed and shown, and signs
        let again = try await review(r)
        #expect(again.gateGen == 2 && again.content.sections.first { $0.id == "requirements" }?.text == "- R1 changed on the Mac")
        let ok = try await decide(r, again, .approve)
        guard case .landed = ok else { Issue.record("not landed: \(ok)"); return }
        #expect(await r.w.host.gateDecisions(ticket: "MOB-0001", gate: "requirements").map(\.gen) == [2])
    }

    @Test func aRevokedPhoneIsRefusedAtAppend() async throws {
        let r = try await rig()
        let s = try await review(r)
        await r.w.host.setGateLies({ var l = FakeGateLies(); l.deviceInvalid = ["d_" + r.w.phoneID.hex]; return l }())
        let out = try await decide(r, s, .approve)
        #expect(out == .refused(code: "device.invalid"))
        #expect(await r.w.host.gateDecisions(ticket: "MOB-0001", gate: "requirements").isEmpty)
        // removed at the host: its signature made before is refused too
        let r2 = try await rig()
        let s2 = try await review(r2)
        await r2.w.host.demoRemoveDevice(r2.w.phoneID)
        let out2 = try await decide(r2, s2, .approve)
        // the host answers a removed device `not_member` to every request, reads included: the phone cannot settle it ("checking"), and it never lands
        switch out2 { case .landed, .landedAfterResign, .landedUnconfirmed: Issue.record("landed: \(out2)"); default: break }
        #expect(await r2.w.host.gateDecisions(ticket: "MOB-0001", gate: "requirements").isEmpty)
    }

    @Test func aChangedRosterIsSignedAgainWithoutANewReviewWhenTheGateIsTheSame() async throws {
        let r = try await rig()
        let s = try await review(r)
        await r.w.host.demoBumpMembersV()
        let out = try await decide(r, s, .approve)
        guard case .landedAfterResign(_, let key) = out else { Issue.record("not resigned: \(out)"); return }
        #expect(key == "MOB-0001" && r.hooks.count("pe.sign") == 2)
        #expect(try await rows(r.p, "SELECT state FROM pe_attempts ORDER BY n").compactMap { $0.text("state") } == ["superseded", "landed"])
        let landed = await r.w.host.gateDecisions(ticket: "MOB-0001", gate: "requirements")
        #expect(landed.count == 1)
    }

    @Test func aRosterChangeWithAChangedGateAsksForANewReview() async throws {
        let r = try await rig()
        let s = try await review(r)
        await r.w.host.demoBumpMembersV()
        await r.w.host.demoChangeGateText(ticket: "MOB-0001", section: "summary", to: "Other summary")
        let out = try await decide(r, s, .approve)
        #expect(out == .needsReview(.workspaceChanged))
        #expect(r.hooks.count("pe.sign") == 1)
    }

    // MARK: crash safety and the migration

    @Test func aLostAnswerIsSettledByReadingNotByASecondSignature() async throws {
        let r = try await rig()
        let s = try await review(r)
        await r.w.host.demoLoseNextWriteResponse()
        let out = try await decide(r, s, .approve)
        guard case .landed = out else { Issue.record("not landed: \(out)"); return }
        let landed = await r.w.host.gateDecisions(ticket: "MOB-0001", gate: "requirements")
        #expect(r.hooks.count("pe.sign") == 1 && landed.count == 1)
    }

    @Test func migration18KeepsTheRowsAndAcceptsTheGateKind() async throws {
        let w = try await World.make()
        let p = try await w.makePhone()
        let db = try await p.container.database()
        #expect(try await db.appliedMigrations().contains(18))
        try await db.execute("INSERT INTO pe_reviews(review, kind, log, question, snapshot, current_idem, ver, state, created_ms) VALUES('r1','gate','u','gate:u:plan',x'00','i1',1,'active',1)")
        await #expect(throws: (any Error).self) {
            try await db.execute("INSERT INTO pe_reviews(review, kind, log, question, snapshot, current_idem, ver, state, created_ms) VALUES('r2','gate','u','gate:u:plan',x'00','i2',1,'active',1)")
        }
        await #expect(throws: (any Error).self) {
            try await db.execute("INSERT INTO pe_reviews(review, kind, log, snapshot, current_idem, ver, state, created_ms) VALUES('r3','other','u',x'00','i3',1,'active',1)")
        }
    }
}
