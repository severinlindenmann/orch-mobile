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

extension FakeHost {
    fileprivate func forgetOutcomes() { viewState?.outcomes = [:] }
}
