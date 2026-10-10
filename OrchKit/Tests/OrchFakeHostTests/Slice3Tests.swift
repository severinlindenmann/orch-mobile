import Foundation
import Testing
import OrchProtocol
import OrchStore
import OrchTestVectors
@testable import OrchClient
@testable import OrchFakeHost

@Suite struct Slice3Tests {
    private func setup() async throws -> (World, Phone, BridgeWorkspaceAPI, WorkspaceSnapshot) {
        let w = try await World.make()
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        let s = try await w.serve(p) { try await api.snapshot() }
        return (w, p, api, s)
    }
    @Test func testSnapshotRejectsUnknownFields() async throws {
        let (w, p, api, _) = try await setup()
        await w.host.setHandler { req in
            let result = await w.host.handleView(req)
            guard case .response(let status, let headers, let data) = result,
                  var m = try? StrictJSON.parse(data).object else { return result }
            m["surprise"] = true
            return .response(status: status, headers: headers, data: try! canonicalJSON(.object(m)))
        }
        await #expect(throws: ViewError.malformed) { _ = try await w.serve(p) { try await api.snapshot() } }
    }
    @Test func testSnapshotNeverSuppliesIdentityName() async throws {
        let (w, p, api, snapshot) = try await setup()
        #expect(snapshot.workspaceID == w.ws)
        #expect(!Mirror(reflecting: snapshot).children.contains { $0.label == "name" || $0.label == "hostedBy" })
        await w.host.setHandler { req in
            guard case .response(let status, let headers, let data) = await w.host.handleView(req), var m = try? StrictJSON.parse(data).object else { return .refuse(.malformed) }
            m["name"] = "Forged identity"
            return .response(status: status, headers: headers, data: try! canonicalJSON(.object(m)))
        }
        await #expect(throws: ViewError.malformed) { _ = try await w.serve(p) { try await api.snapshot() } }
    }
    @Test func testReviewRereadsAndRecomputesHash() async throws {
        let (w, p, api, s) = try await setup()
        let id = s.questions[0].questionID
        try await w.host.replaceQuestionText(id, text: "New authoritative text")
        let review = try await w.serve(p) { try await api.review(questionID: id) }
        #expect(review.question.text == "New authoritative text")
        #expect(review.question.contentHash != s.questions[0].contentHash)
        await w.host.setHandler { req in
            guard case .response(let status, let headers, let data) = await w.host.handleView(req), var m = try? StrictJSON.parse(data).object,
                  var q = m["question"]?.object else { return .refuse(.malformed) }
            q["content_hash"] = .string(B64U.encode(Data(count: 32))); m["question"] = .object(q)
            return .response(status: status, headers: headers, data: try! canonicalJSON(.object(m)))
        }
        await #expect(throws: ViewError.malformed) { _ = try await w.serve(p) { try await api.review(questionID: id) } }
    }
    @Test func testUIOnlyUsesUnsignedReviewAPI() async throws {
        let (w, p, concrete, s) = try await setup()
        let api: any WorkspaceAPI = concrete
        let review = try await w.serve(p) { try await api.review(questionID: s.questions[0].questionID) }
        #expect(!Mirror(reflecting: review).children.contains { $0.label == "sig" || $0.label == "operation" })
        await p.session.invalidateReviews()
        await #expect(throws: ViewError.invalidReview) { _ = try await api.decide(review, optionID: "approve") }
        #expect(await api.pendingDecisions().isEmpty)
    }
    @Test func testBidiReviewPreservesHash() async throws {
        let (w, p, api, s) = try await setup()
        let q = s.questions[2]
        let review = try await w.serve(p) { try await api.review(questionID: q.questionID) }
        #expect(review.question.text.utf8.elementsEqual(q.text.utf8))
        #expect(review.question.text.contains("\u{202E}"))
        #expect(review.question.options[0].label.contains("\u{2066}"))
        #expect(review.question.contentHash == q.contentHash)
        #expect(try await w.serve(p) { try await api.decide(review, optionID: "approve") } == .accepted)
    }
    @Test func testLongReviewRequiresScrollAndArming() async throws {
        let (w, p, api, s) = try await setup()
        let r = try await w.serve(p) { try await api.review(questionID: s.questions[1].questionID) }
        #expect(r.question.text.count > 3000)
        var gate = ReviewArming(review: r)
        gate.select("approve", now: .zero)
        #expect(!gate.canConfirm(now: .seconds(60)))
        gate.scrollToEnd(now: .seconds(60))
        #expect(!gate.canConfirm(now: .milliseconds(60_799)))
        #expect(gate.canConfirm(now: .milliseconds(60_800)))
        gate.select("reject", now: .seconds(61))
        #expect(!gate.canConfirm(now: .seconds(61)))
        gate.invalidate()
        #expect(!gate.canConfirm(now: .seconds(100)))
    }
    @Test func testDecisionVectors() throws {
        let v = J(try StrictJSON.parse(Vectors.data, maxBytes: .max))["suites"]["2"]
        let q = v["question_hash"]["content"]
        #expect(B64U.encode(try Decisions.questionHash(questionID: q["question_id"].id, ticket: q["ticket"].str, text: q["text"].str, options: q["options"].v)) == v["question_hash"]["content_hash"].str)
        for c in v["decisions"]["cases"].items {
            let valid = c["expect"]["ok"].v.bool == true
            if valid {
                try Decisions.verifyOp(c["meta"].v, workspace: c["workspace_id"].id, deviceKey: c["dk_sig_pub"].sigPub)
                let m = c["meta"]
                #expect(try Decisions.signedBytes(workspace: c["workspace_id"].id, questionID: m["question_id"].id,
                                                 contentHash: B64U.decode(m["content_hash"].str)!, decisionID: m["decision_id"].id,
                                                 answer: m["answer"].v) == v["decisions"]["signed_bytes"].hexData)
            } else {
                let refusal: Refusal = c["expect"]["refuse"].str == "malformed" ? .malformed : .badSignature
                #expect(throws: refusal) { try Decisions.verifyOp(c["meta"].v, workspace: c["workspace_id"].id, deviceKey: c["dk_sig_pub"].sigPub) }
            }
        }
    }
    /// Drop the decision poll only (the preliminary authoritative reads still complete).
    private func lostDecision() async throws -> (World, Phone, BridgeWorkspaceAPI, ID16, PendingRequestInfo, Data) {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        let s = try await w.serve(p) { try await api.snapshot() }
        let review = try await w.serve(p) { try await api.review(questionID: s.questions[0].questionID) }
        await w.host.setHandler { req in
            let response = await w.host.handleView(req)
            if req.meta.object?["op"] == "decision" { faults.enqueue(.disconnect, at: .pollDelivery) }
            return response
        }
        #expect(try await w.serve(p) { try await api.decide(review, optionID: "approve") } == .uncertain)
        let rows = await api.pendingDecisions()
        let id = try #require(rows.first?.decisionID)
        let pending = try #require(try await p.session.pendingRequests().first { $0.logical == id })
        let envelope = try #require(try await p.session.storedEnvelope(rid: pending.rid))
        return (w, p, api, id, pending, envelope)
    }
    @Test func testLostResponseReplaysStoredEnvelope() async throws {
        let (w, p, api, id, pending, envelope) = try await lostDecision()
        w.clock.advance(milliseconds: 61_000); p.clock.advance(milliseconds: 61_000)
        #expect(try await w.serve(p) { try await p.session.reconcileDecision(id) } == .accepted)
        #expect(await w.host.coreState().rids[pending.rid]?.digest == (try Bridge.Parts(envelope: envelope)).digest)
        #expect(await api.pendingDecisions().isEmpty)
    }
    @Test func testExpiredOrUnknownRidReconcilesByQuestion() async throws {
        for expired in [false, true] {
            let (w, p, _, id, pending, _) = try await lostDecision()
            await w.host.forgetOutcome(rid: pending.rid)
            let elapsed: Int64 = expired ? 901_000 : 61_000
            w.clock.advance(milliseconds: elapsed); p.clock.advance(milliseconds: elapsed)
            #expect(try await w.serve(p) { try await p.session.reconcileDecision(id) } == .accepted)
            #expect(try await p.session.uncertainRequests().isEmpty)
        }
    }
    @Test func testPendingDecisionsSurviveRestart() async throws {
        let (w, p, _, id, _, envelope) = try await lostDecision()
        let restarted = try await WorkspaceSession(p.session.cfg)
        let pending = await restarted.pendingDecisions()
        #expect(pending.count == 1 && pending[0].decisionID == id && pending[0].state == .uncertain)
        let request = try #require(try await restarted.pendingRequests().first)
        #expect(try await restarted.storedEnvelope(rid: request.rid) == envelope)
        #expect(try await w.serve(p) { try await restarted.reconcileDecision(id) } == .accepted)
    }
    @Test func testStaleEpochPreservesSignedDecision() async throws {
        let (w, p, _, id, pending, _) = try await lostDecision()
        let db = try await p.container.database()
        let before = try #require(try await db.query("SELECT operation FROM decisions WHERE id=?", [.text(id.hex)]).first?.blob("operation"))
        // Open-state reconciliation after an uncommitted/lost request, under a newly published epoch.
        await w.host.reopenQuestionsForTest()
        await w.host.forgetOutcome(rid: pending.rid)
        try await w.host.rotate(remaining: await w.host.rosterEntries(), relay: w.relay, session: w.hostSession)
        w.clock.advance(milliseconds: 61_000); p.clock.advance(milliseconds: 61_000)
        // Remove the fault wrapper so a newly applied decision can return normally.
        await w.host.clearViewHandler()
        #expect(try await w.serve(p) { try await p.session.reconcileDecision(id) } == .accepted)
        let after = try #require(try await db.query("SELECT operation FROM decisions WHERE id=?", [.text(id.hex)]).first?.blob("operation"))
        #expect(before == after)
        #expect(try await p.session.currentEpoch() == 2)
    }
    @Test func testQuestionChangedRequiresReview() async throws {
        let (w, p, api, s) = try await setup()
        let q = s.questions[0].questionID
        let r = try await w.serve(p) { try await api.review(questionID: q) }
        try await w.host.replaceQuestionText(q, text: "Changed")
        let outcome = try await w.serve(p) { try await api.decide(r, optionID: "approve") }
        guard case .questionChanged = outcome else { Issue.record("Must re-review"); return }
        await #expect(throws: ViewError.invalidReview) { _ = try await api.decide(r, optionID: "reject") }
        let fresh = try await w.serve(p) { try await api.review(questionID: q) }
        #expect(fresh.question.text == "Changed")
    }
    @Test func testAlreadyAnsweredShowsActor() async throws {
        let (w, p, api, s) = try await setup()
        let q = s.questions[0].questionID
        let r = try await w.serve(p) { try await api.review(questionID: q) }
        let other = try await w.serve(p) { try await api.review(questionID: q) }
        #expect(try await w.serve(p) { try await api.decide(r, optionID: "approve") } == .accepted)
        let result = try await w.serve(p) { try await api.decide(other, optionID: "reject") }
        guard case .alreadyAnswered(let label, let at) = result else { Issue.record("Missing actor"); return }
        #expect(label == "Demo iPhone" && at > 0)
    }
    @Test func hostCASRejectsChangeAfterTheLastRead() async throws {
        let (w, p, api, s) = try await setup()
        let qid = s.questions[0].questionID
        let review = try await w.serve(p) { try await api.review(questionID: qid) }
        await w.host.setHandler { req in
            if req.meta.object?["op"] == "decision" { try! await w.host.replaceQuestionText(qid, text: "Raced with send") }
            return await w.host.handleView(req)
        }
        let result = try await w.serve(p) { try await api.decide(review, optionID: "approve") }
        guard case .questionChanged = result else { Issue.record("Host CAS must reject stale hash"); return }
        let rows = try await p.container.database().query("SELECT operation FROM decisions")
        #expect(rows.count == 1) // This rejection really crossed the signed decision path.
        #expect(await api.pendingDecisions().isEmpty)
    }
    @Test func offlineSubmissionRemainsUnsigned() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        let snapshot = try await w.serve(p) { try await api.snapshot() }
        let review = try await w.serve(p) { try await api.review(questionID: snapshot.questions[0].questionID) }
        faults.enqueue(.disconnect, at: .beforeQueue)
        await #expect(throws: TransportError.disconnected) { _ = try await api.decide(review, optionID: "approve") }
        #expect(try await p.container.database().query("SELECT * FROM decisions").isEmpty)
    }
    @Test func unsafeDraftsAreRejectedWithoutRewrite() async throws {
        let (w, _, api, _) = try await setup()
        await w.host.setRoster([(w.phone, World.all)])
        for title in ["", "Unsafe\u{202E}", String(repeating: "x", count: 201)] {
            let draft = NewTicketSubmission(creationID: .fresh(92), title: title, body: "")
            await #expect(throws: ViewError.invalidDraft) { _ = try await api.newTicket(draft) }
        }
        #expect(!validTicketKey("MOB-1\n"))
    }
    @Test func testNewTicketRetryCreatesOnce() async throws {
        let (w, p, api, s) = try await setup()
        await w.host.setRoster([(w.phone, World.all), (w.primary.deviceKeys, World.all)])
        let draft = NewTicketSubmission(creationID: .fresh(90), title: "A ticket", body: "Text", epicKey: "FAC-1")
        let first = try await w.serve(p) { try await api.newTicket(draft) }
        let second = try await w.serve(p) { try await api.newTicket(draft) }
        #expect(first == second)
        #expect(try await w.serve(p) { try await api.snapshot() }.tickets.count == s.tickets.count + 1)
    }
    @Test func testCreationConflictIsSealed409() async throws {
        let (w, p, api, _) = try await setup()
        await w.host.setRoster([(w.phone, World.all)])
        let draft = NewTicketSubmission(creationID: .fresh(91), title: "First", body: "")
        _ = try await w.serve(p) { try await api.newTicket(draft) }
        let changed = NewTicketSubmission(creationID: draft.creationID, title: "Changed", body: "")
        await #expect(throws: ViewError.http(409, "creation_conflict")) { _ = try await w.serve(p) { try await api.newTicket(changed) } }
        #expect(try await p.session.pinFailures() == 0)
    }
    @Test func testForegroundPollingThirtyMinutesWithinQuota() async throws {
        let (w, p, api, _) = try await setup()
        let start = w.clock.nowMs
        let stream = await api.events()
        let count = try await w.serve(p, steps: 4000, timeout: .seconds(60)) {
            var snapshots = 0
            for await event in stream {
                if case .snapshot = event {
                    snapshots += 1
                    if w.clock.nowMs - start >= 1_800_000 { return snapshots }
                }
            }
            return snapshots
        }
        await p.session.setForeground(false)
        #expect(w.clock.nowMs - start >= 1_800_000)
        #expect((30...40).contains(count))
        let core = await w.host.coreState()
        #expect(core.rids.count < core.limits.perDevice)
        #expect(!core.rids.values.contains { if case .refusal(.busy) = $0.outcome { true } else { false } })
    }
    @Test func testEventsReturnsIndependentStreamsWithSharedPoller() async throws {
        let (w, p, api, _) = try await setup()
        let a = await api.events(), b = await api.events()
        let taskA = Task { for await event in a { if case .snapshot(let s) = event { return s.revision } }; return Int64(0) }
        let taskB = Task { for await event in b { if case .snapshot(let s) = event { return s.revision } }; return Int64(0) }
        let before = try await p.session.nextSeq()
        let result = try await w.serve(p) { (await taskA.value, await taskB.value) }
        #expect(result.0 == result.1 && result.0 > 0)
        #expect(try await p.session.nextSeq() == before + 1)
        await p.session.setForeground(false)
    }
}

extension FakeHost {
    fileprivate func clearViewHandler() { handler = nil }
    fileprivate func reopenQuestionsForTest() {
        guard var state = viewState else { return }
        state.questions = state.questions.map { v in
            var m = v.object!; m["state"] = "open"; m["resolution"] = .null; return .object(m)
        }
        viewState = state
    }
}
