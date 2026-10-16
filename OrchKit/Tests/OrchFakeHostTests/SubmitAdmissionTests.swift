import CryptoKit
import Foundation
import Testing
import OrchCustody
import OrchProtocol
@testable import OrchClient
@testable import OrchFakeHost

/// FakeHost conformance for `relay.submit` `answer` (spec 14.6): every expected code is written out literally here, never computed by the
/// phone's classifier or validator. Events are built with the phone's signer but judged only by the FakeHost's own checker.
@Suite struct SubmitAdmissionTests {
    struct Rig {
        let w: World
        let reviewed: F1Question.Reviewed
        let phone: Phone
    }

    func rig() async throws -> Rig {
        let w = try await World.make()
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        let s = try await w.serve(p) { try await api.snapshot() }
        let id = s.questions[0].questionID
        let review = try await w.serve(p) { try await p.session.reviewQuestion(id) }
        return Rig(w: w, reviewed: try #require(review.reviewed), phone: p)
    }

    func event(_ r: Rig, option: String = "approve", id: String? = nil, auth: F1Auth = .passphrase, rosterV: Int64? = nil,
               basedOn: String? = nil, signer: (any Signer)? = nil, device: ID16? = nil) async throws -> SignedPhoneEvent {
        let person = await r.w.primary.personID
        let actor = try PhoneActor(person: person, device: device ?? r.w.phoneID, auth: auth)
        var reviewed = r.reviewed
        if rosterV != nil || basedOn != nil {
            reviewed = try r.reviewed.question.reviewed(ticketUID: r.reviewed.ticketUID, workspace: r.w.ws, basedOn: basedOn ?? r.reviewed.basedOn,
                                                         rosterV: rosterV ?? r.reviewed.rosterV)
        }
        let eid = try id ?? ULID.make(timeMs: r.w.clock.nowMs, random: SystemEntropy().bytes(10))
        let u = try PhoneEvents.unsignedAnswer(reviewed, option: option, text: nil, id: eid, actor: actor, workspace: r.w.ws)
        if let signer { return try PhoneEvents.sign(u, signer: signer) }
        return try PhoneEvents.sign(u, signer: r.w.env.device.sig)
    }

    func submit(_ r: Rig, _ e: SignedPhoneEvent, scopes: [String] = ["look", "decide"], device: ID16? = nil) async throws -> HostReply {
        let meta = try R2.writeMeta(e)
        return await r.w.host.handleView(HostRequest(device: device ?? r.w.phoneID, scopes: scopes, meta: meta, data: Data(), epoch: 1))
    }

    func code(_ reply: HostReply) -> String? {
        if case .refuse(let h) = reply { return h.code }
        return nil
    }

    func landed(_ reply: HostReply) throws -> (seqs: [JSONValue], duplicate: Bool)? {
        guard case .r2(let bytes) = reply, let o = try StrictJSON.parse(bytes).object else { return nil }
        return (o["data"]?.object?["seqs"]?.array ?? [], o["duplicate"]?.bool ?? false)
    }

    @Test func happyAnswerLandsAndAnIdenticalRetryReplaysWithDuplicate() async throws {
        let r = try await rig()
        let e = try await event(r)
        let first = try #require(try landed(try await submit(r, e)))
        #expect(first.seqs.count == 1 && first.duplicate == false)
        let again = try #require(try landed(try await submit(r, e)))
        #expect(again.seqs == first.seqs && again.duplicate == true)
        #expect(await r.w.host.outcomeRecord(device: r.w.phoneID, idem: e.id)?.state == "committed")
        // the same idem with other content
        let other = try await event(r, option: "reject", id: e.id)
        #expect(code(try await submit(r, other)) == "idem.conflict")
    }

    @Test func checksBeforeTheLock() async throws {
        let r = try await rig()
        // P4: another device named as actor
        #expect(code(try await submit(r, try await event(r, device: ID16.fresh(9)))) == "op.not_allowed")
        // P7: a signature by another key
        #expect(code(try await submit(r, try await event(r, signer: SoftwareSigner()))) == "sig.invalid")
        // P5 passphrase and secure-enclave-unlocked are both admitted (column R)
        #expect(try landed(try await submit(r, try await event(r, auth: .secureEnclaveUnlocked))) != nil)
    }

    @Test func standingAndScopeUnderTheLock() async throws {
        let r = try await rig()
        #expect(code(try await submit(r, try await event(r), scopes: ["look"])) == "forbidden_scope")
        await r.w.host.demoRemoveDevice(r.w.phoneID)
        #expect(code(try await submit(r, try await event(r))) == "not_member")
    }

    @Test func modelJudgement() async throws {
        let r = try await rig()
        #expect(code(try await submit(r, try await event(r, basedOn: "sha256:" + String(repeating: "ab", count: 32)))) == "event.bad_base")
        #expect(code(try await submit(r, try await event(r, rosterV: r.reviewed.rosterV + 7))) == "members.stale")
        await r.w.host.demoBumpMembersV()
        #expect(code(try await submit(r, try await event(r))) == "members.stale")
        #expect(try landed(try await submit(r, try await event(r, rosterV: r.reviewed.rosterV + 1))) != nil)
        // the question is answered now
        #expect(code(try await submit(r, try await event(r, rosterV: r.reviewed.rosterV + 1))) == "question.answered")
    }

    @Test func aChangedQuestionIsStale() async throws {
        let r = try await rig()
        let qid = try #require(ID16(hex: r.reviewed.qid))
        try await r.w.host.replaceQuestionText(qid, text: "Something else?")
        #expect(code(try await submit(r, try await event(r))) == "question.stale")
    }

    @Test func freshnessWindowOnlyForANeverSeenEvent() async throws {
        let r = try await rig()
        let old = try ULID.make(timeMs: r.w.clock.nowMs - 901_000, random: Data(repeating: 1, count: 10))
        #expect(code(try await submit(r, try await event(r, id: old))) == "event.expired")
        let future = try ULID.make(timeMs: r.w.clock.nowMs + 301_000, random: Data(repeating: 2, count: 10))
        #expect(code(try await submit(r, try await event(r, id: future))) == "event.expired")
        let edge = try ULID.make(timeMs: r.w.clock.nowMs - 900_000, random: Data(repeating: 3, count: 10))
        let e = try await event(r, id: edge)
        #expect(try landed(try await submit(r, e)) != nil)
        // amendment A: a known identity is answered before the window, at any age
        r.w.clock.advance(milliseconds: 3_600_000)
        #expect(try landed(try await submit(r, e))?.duplicate == true)
    }

    @Test func logDedupByContentAndActor() async throws {
        let r = try await rig()
        let e = try await event(r)
        _ = try await submit(r, e)
        await r.w.host.forgetOutcomes()
        // the identical event (another signature: dedup is by content) after the outcome record is gone: committed, duplicate
        let resigned = try await event(r, id: e.id)
        #expect(try landed(try await submit(r, resigned))?.duplicate == true)
        await r.w.host.forgetOutcomes()
        #expect(code(try await submit(r, try await event(r, option: "reject", id: e.id))) == "event.duplicate_id")
    }

    @Test func crashAfterPlanRecoversByRunningAgain() async throws {
        let r = try await rig()
        await r.w.host.setWriteControls(crashAfterPlan: true)
        let e = try await event(r)
        #expect(code(try await submit(r, e)) == "already_done")
        #expect(await r.w.host.outcomeRecord(device: r.w.phoneID, idem: e.id)?.state == "pending")
        #expect(code(try await submit(r, e)) == "pending")
        #expect(await r.w.host.loggedCount() == 0)
        await r.w.host.recoverWrites()
        #expect(await r.w.host.outcomeRecord(device: r.w.phoneID, idem: e.id)?.state == "committed")
        #expect(await r.w.host.loggedCount() == 1)
        #expect(try landed(try await submit(r, e))?.duplicate == true)
    }

    @Test func crashAfterAppendRecoversAsCommittedWithoutAppendingTwice() async throws {
        let r = try await rig()
        await r.w.host.setWriteControls(crashAfterAppend: true)
        let e = try await event(r)
        #expect(code(try await submit(r, e)) == "already_done")
        #expect(await r.w.host.loggedCount() == 1)
        await r.w.host.recoverWrites()
        #expect(await r.w.host.loggedCount() == 1)
        let rec = try #require(await r.w.host.outcomeRecord(device: r.w.phoneID, idem: e.id))
        #expect(rec.state == "committed" && rec.seq != nil)
    }

    @Test func recoveryRechecksStanding() async throws {
        let r = try await rig()
        await r.w.host.setWriteControls(crashAfterPlan: true)
        let e = try await event(r)
        _ = try await submit(r, e)
        await r.w.host.demoRemoveDevice(r.w.phoneID)
        await r.w.host.recoverWrites()
        let rec = try #require(await r.w.host.outcomeRecord(device: r.w.phoneID, idem: e.id))
        #expect(rec.state == "failed" && rec.code == "not_member")
        #expect(await r.w.host.loggedCount() == 0)
    }

    @Test func outcomeGetServesTheRecordOrPendingThenUnknown() async throws {
        let r = try await rig()
        func get(_ idem: String) async throws -> HostReply {
            await r.w.host.handleView(HostRequest(device: r.w.phoneID, scopes: ["look", "decide"],
                                                  meta: try R2.requestMeta(op: "outcome.get", args: ["idem": .string(idem)]), data: Data(), epoch: 1))
        }
        func state(_ reply: HostReply) throws -> String? {
            guard case .r2(let b) = reply else { return nil }
            return try StrictJSON.parse(b).object?["data"]?.object?["state"]?.string
        }
        let e = try await event(r)
        _ = try await submit(r, e)
        #expect(try state(try await get(e.id)) == "committed")
        let unknown = try ULID.make(timeMs: r.w.clock.nowMs, random: Data(repeating: 5, count: 10))
        #expect(try state(try await get(unknown)) == "pending")
        r.w.clock.advance(milliseconds: 1_200_000)
        #expect(code(try await get(unknown)) == "outcome.unknown_idem")
        let refused = try await event(r, rosterV: 99)
        _ = try await submit(r, refused)
        guard case .r2(let b) = try await get(refused.id), let d = try StrictJSON.parse(b).object?["data"]?.object else { Issue.record("no record"); return }
        #expect(d["state"]?.string == "failed" && d["error"]?.object?["code"]?.string == "members.stale" && d["seqs"] == nil)
    }
}

/// FakeHost conformance for `relay.submit` `new_ticket` (spec 14.6 with L4/L5 for a creation): expected codes written out literally.
@Suite struct SubmitCreationAdmissionTests {
    let base = SubmitAdmissionTests()
    struct Ev { let log: String, id: String; let event: [String: JSONValue] }

    func create(_ r: SubmitAdmissionTests.Rig, uid: String? = nil, key: String = "MOB-0002", type: String = "feature", title: String = "Check the tariff seeds",
                id: String? = nil, rosterV: Int64 = 1, auth: F1Auth = .passphrase, device: ID16? = nil, signer: (any Signer)? = nil,
                edit: (@Sendable (inout [String: JSONValue]) -> Void)? = nil) async throws -> Ev {
        let person = await r.w.primary.personID
        let actor = try PhoneActor(person: person, device: device ?? r.w.phoneID, auth: auth)
        let eid = try id ?? ULID.make(timeMs: r.w.clock.nowMs, random: SystemEntropy().bytes(10))
        let log = try uid ?? ULID.make(timeMs: r.w.clock.nowMs, random: SystemEntropy().bytes(10))
        let u = try PhoneEvents.unsignedCreate(ticketUID: log, key: key, ticketType: type, title: try PhoneEvents.prepareText(title, oneLine: true), id: eid,
                                               rosterV: rosterV, actor: actor, workspace: r.w.ws)
        let e: SignedPhoneEvent
        if let signer { e = try PhoneEvents.sign(u, signer: signer) } else { e = try PhoneEvents.sign(u, signer: r.w.env.device.sig) }
        guard let edit else { return Ev(log: e.log, id: e.id, event: e.event) }
        // a hand-edited event (re-signed over the edited content, so only the FakeHost's own checks can refuse it)
        var ev = e.event; ev["sig"] = nil; edit(&ev)
        let body = try canonicalJSON(["contract": 1, "event": .object(ev), "log": .string(log), "suite": 2, "workspace_id": .string(r.w.ws.hex)])
        let sig: Data
        if let signer { sig = try Signature.sign(signer, label: "orch/v2/sig/ticket-event|", message: body) }
        else { sig = try Signature.sign(r.w.env.device.sig, label: "orch/v2/sig/ticket-event|", message: body) }
        ev["sig"] = .string(B64U.encode(sig))
        return Ev(log: log, id: eid, event: ev)
    }

    /// The write meta built by hand (the phone's `R2.writeMeta` would refuse a hand-edited event).
    func submit(_ r: SubmitAdmissionTests.Rig, _ e: Ev, scopes: [String] = ["look", "decide"], op: String = "new_ticket") async throws -> HostReply {
        let meta: JSONValue = ["op": .string(op), "args": ["log": .string(e.log), "events": [.object(e.event)]], "idem": .string(e.id)]
        return await r.w.host.handleView(HostRequest(device: r.w.phoneID, scopes: scopes, meta: meta, data: Data(), epoch: 1))
    }

    func refusal(_ reply: HostReply) -> (code: String, nextKey: String?)? {
        if case .refuse(.host(let code, _, _, let k)) = reply { return (code, k) }
        if case .refuse(let h) = reply { return (h.code, nil) }
        return nil
    }

    func result(_ reply: HostReply) throws -> (log: String, seqs: [JSONValue], key: String?, duplicate: Bool)? {
        guard case .r2(let bytes) = reply, let o = try StrictJSON.parse(bytes).object, let d = o["data"]?.object else { return nil }
        return (d["log"]?.string ?? "", d["seqs"]?.array ?? [], o["key"]?.string, o["duplicate"]?.bool ?? false)
    }

    @Test func aCreationLandsWithItsKeyAndAnIdenticalRetryReplays() async throws {
        let r = try await base.rig()
        let e = try await create(r)
        let first = try #require(try result(try await submit(r, e)))
        #expect(first.log == e.log && first.seqs == [1] && first.key == "MOB-0002" && first.duplicate == false)
        let again = try #require(try result(try await submit(r, e)))
        #expect(again.seqs == [1] && again.key == "MOB-0002" && again.duplicate == true)
        // the ticket exists under the phone's uid, and the next key moved on
        #expect(await r.w.host.nextKey == "MOB-0003")
        // the same idem with other content
        #expect(refusal(try await submit(r, try await create(r, uid: e.log, title: "Other", id: e.id)))?.code == "idem.conflict")
    }

    @Test func aKeyRaceIsKeyNotNextWithTheAdvisoryNextKey() async throws {
        let r = try await base.rig()
        await r.w.host.demoTakeNextKey()
        let e = try await create(r)
        let got = try #require(refusal(try await submit(r, e)))
        #expect(got.code == "ticket.key_not_next" && got.nextKey == "MOB-0003")
        // the stored outcome answers the same, with the detail
        let o = await r.w.host.outcomeRecord(device: r.w.phoneID, idem: e.id)
        #expect(o?.state == "failed" && o?.code == "ticket.key_not_next")
        // signed with the advertised key, under the same uid: lands
        let again = try #require(try result(try await submit(r, try await create(r, uid: e.log, key: "MOB-0003"))))
        #expect(again.key == "MOB-0003")
    }

    @Test func aUsedUidIsTicketExists() async throws {
        let r = try await base.rig()
        let e = try await create(r)
        _ = try await submit(r, e)
        // a new event (new id) for the same uid, even with the right next key
        #expect(refusal(try await submit(r, try await create(r, uid: e.log, key: "MOB-0003")))?.code == "ticket.exists")
    }

    @Test func ownerTypeTitleAndShape() async throws {
        let r = try await base.rig()
        #expect(refusal(try await submit(r, try await create(r) { $0["owner"] = .string("p_" + String(repeating: "00", count: 16)) }))?.code == "invalid.input")
        #expect(refusal(try await submit(r, try await create(r) { $0["ticket_type"] = "story" }))?.code == "validation.event")
        #expect(refusal(try await submit(r, try await create(r) { $0["title"] = "two\nlines" }))?.code == "validation.text")
        #expect(refusal(try await submit(r, try await create(r) { $0["title"] = "" }))?.code == "validation.text")
        #expect(refusal(try await submit(r, try await create(r) { $0["based_on"] = .string("sha256:" + String(repeating: "ab", count: 32)) }))?.code == "validation.event")
        #expect(refusal(try await submit(r, try await create(r) { $0["key"] = "mob-2" }))?.code == "validation.event")
        #expect(refusal(try await submit(r, try await create(r) { $0["body"] = "details" }))?.code == "validation.event")
        // P2: a creation under the answer op, and an answer-typed event under new_ticket
        #expect(refusal(try await submit(r, try await create(r), op: "answer"))?.code == "forbidden_scope")
    }

    @Test func checksBeforeAndUnderTheLock() async throws {
        let r = try await base.rig()
        // P4, P5 (convenience never on a creation), P7
        #expect(refusal(try await submit(r, try await create(r, device: ID16.fresh(9))))?.code == "op.not_allowed")
        #expect(refusal(try await submit(r, try await create(r) { $0["auth"] = "convenience" }))?.code == "op.not_allowed")
        #expect(refusal(try await submit(r, try await create(r, signer: SoftwareSigner())))?.code == "sig.invalid")
        // L2
        #expect(refusal(try await submit(r, try await create(r), scopes: ["look"]))?.code == "forbidden_scope")
        await r.w.host.demoRemoveDevice(r.w.phoneID)
        #expect(refusal(try await submit(r, try await create(r)))?.code == "not_member")
    }

    @Test func aStaleRosterIsMembersStale() async throws {
        let r = try await base.rig()
        await r.w.host.demoBumpMembersV()
        #expect(refusal(try await submit(r, try await create(r)))?.code == "members.stale")
        #expect(try result(try await submit(r, try await create(r, rosterV: 2))) != nil)
    }

    @Test func theWindowAppliesToANeverSeenCreation() async throws {
        let r = try await base.rig()
        let old = try ULID.make(timeMs: r.w.clock.nowMs - 901_000, random: Data(repeating: 1, count: 10))
        #expect(refusal(try await submit(r, try await create(r, id: old)))?.code == "event.expired")
    }

    @Test func crashAfterPlanRecoversAndAKeyTakenMeanwhileIsKeyNotNext() async throws {
        let r = try await base.rig()
        await r.w.host.setWriteControls(crashAfterPlan: true)
        let e = try await create(r)
        #expect(refusal(try await submit(r, e))?.code == "already_done")
        await r.w.host.recoverWrites()
        let rec = try #require(await r.w.host.outcomeRecord(device: r.w.phoneID, idem: e.id))
        #expect(rec.state == "committed" && rec.seq == 1)
        #expect(try result(try await submit(r, e))?.duplicate == true)

        await r.w.host.setWriteControls(crashAfterPlan: true)
        let f = try await create(r, key: "MOB-0003")
        _ = try await submit(r, f)
        await r.w.host.demoTakeNextKey()
        await r.w.host.recoverWrites()
        let g = try #require(await r.w.host.outcomeRecord(device: r.w.phoneID, idem: f.id))
        #expect(g.state == "failed" && g.code == "ticket.key_not_next")
    }

    @Test func crashAfterAppendRecoversAsCommitted() async throws {
        let r = try await base.rig()
        await r.w.host.setWriteControls(crashAfterAppend: true)
        let e = try await create(r)
        #expect(refusal(try await submit(r, e))?.code == "already_done")
        await r.w.host.recoverWrites()
        #expect(await r.w.host.loggedCount() == 1)
        #expect(await r.w.host.outcomeRecord(device: r.w.phoneID, idem: e.id)?.state == "committed")
    }
}

extension FakeHost {
    fileprivate func forgetOutcomes() { viewState?.outcomes = [:] }
}
