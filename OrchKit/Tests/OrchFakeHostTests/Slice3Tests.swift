import Foundation
import OrchCustody
import Testing
import OrchProtocol
import OrchStore
import OrchTestVectors
@testable import OrchClient
@testable import OrchFakeHost

extension FakeHost {
    /// A handler that serves the view and lets `change` rewrite the `data` of an R2 result of `op` (nil: any op) on its way out.
    func tampering(_ op: String? = nil, _ change: @escaping @Sendable (inout [String: JSONValue]) -> Void) -> HostHandler {
        { [self] req in
            let reply = await self.handleView(req)
            guard case .r2(let bytes) = reply, op == nil || req.meta.object?["op"]?.string == op,
                  var r = try? StrictJSON.parse(bytes).object, var data = r["data"]?.object else { return reply }
            change(&data)
            r["data"] = .object(data)
            return .r2(try! canonicalJSON(.object(r)))
        }
    }
}

@Suite struct Slice3Tests {
    private func setup() async throws -> (World, Phone, BridgeWorkspaceAPI, WorkspaceSnapshot) {
        let w = try await World.make()
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        let s = try await w.serve(p) { try await api.snapshot() }
        return (w, p, api, s)
    }
    @Test func neverSentSignatureIsNotQueued() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        let snapshot = try await w.serve(p) { try await api.snapshot() }
        let review = try await w.serve(p) { try await api.review(questionID: snapshot.questions[0].questionID) }
        let reads = ReadCounter()
        await w.host.setHandler { req in
            if req.meta.object?["op"] != "decision", await reads.next() == 2 { return .refuse(.malformed) }
            return await w.host.handleView(req)
        }
        _ = try? await w.serve(p) { try await api.decide(review, optionID: "approve") }
        let orphan = try await p.container.database().query("SELECT id FROM decisions WHERE state <> 'resolved' AND NOT EXISTS (SELECT 1 FROM bridge_requests WHERE logical=decisions.id)")
        #expect(orphan.isEmpty)
        await p.session.setForeground(false)
        w.clock.advance(milliseconds: 86_400_000); p.clock.advance(milliseconds: 86_400_000)
        for row in try await p.container.database().query("SELECT id FROM decisions WHERE state <> 'resolved'") {
            if let id = row.text("id").flatMap(ID16.init(hex:)) {
                do { _ = try await w.serve(p) { try await p.session.reconcileDecision(id) }; Issue.record("Background reconciliation sent a decision") }
                catch { }
            }
        }
    }
    @Test func ownDecisionRacesFreshEnvelope() async throws {
        let (w, p, api, s) = try await setup()
        let review = try await w.serve(p) { try await api.review(questionID: s.questions[0].questionID) }
        await w.host.setHandler { req in
            if req.meta.object?["op"] == "decision" {
                _ = await w.host.handleView(req)
                return .refuse(.alreadyAnswered(byDeviceLabel: "Demo iPhone", atMs: w.clock.nowMs))
            }
            return await w.host.handleView(req)
        }
        #expect(try await w.serve(p) { try await api.decide(review, optionID: "approve") } == .accepted)
    }
    @Test func unsignedViewsIgnoreUnknownKeysButBoundFieldsAreChecked() async throws {
        let (w, p, api, before) = try await setup()
        // section 0.4: a key the phone does not read is ignored in every view it reads
        await w.host.setHandler(await w.host.tampering { $0["surprise"] = true })
        let s = try await w.serve(p) { try await api.snapshot() }
        #expect(s.questions == before.questions && s.tickets == before.tickets)
        // a bound or displayed field that is wrong is not
        await w.host.setHandler(await w.host.tampering("ticket.query") { d in
            var rows = d["rows"]!.array!; var r = rows[0].object!; r["head_seq"] = "x"; rows[0] = .object(r); d["rows"] = .array(rows)
        })
        await #expect(throws: ViewError.malformed) { _ = try await w.serve(p) { try await api.snapshot() } }
    }
    @Test func testSnapshotTakesItsIdentityFromThePairingNotTheHost() async throws {
        let (w, p, api, snapshot) = try await setup()
        #expect(snapshot.workspaceID == w.ws)
        await w.host.setHandler(await w.host.tampering("workspace.show") { $0["id"] = .string(String(repeating: "a", count: 32)) })
        let s = try await w.serve(p) { try await api.snapshot() }
        #expect(s.workspaceID == w.ws)          // the id of the view is display data; the workspace is the one this device is paired to
    }
    @Test func testReviewRereadsAndRecomputesHash() async throws {
        let (w, p, api, s) = try await setup()
        let id = s.questions[0].questionID
        try await w.host.replaceQuestionText(id, text: "New authoritative text")
        let review = try await w.serve(p) { try await api.review(questionID: id) }
        #expect(review.question.text == "New authoritative text")
        #expect(review.question.contentHash != s.questions[0].contentHash)
        await w.host.setHandler(await w.host.tampering("ticket.get") { d in
            var qs = d["questions"]!.array!
            for i in qs.indices { var q = qs[i].object!; q["hash"] = .string("sha256:" + String(repeating: "0", count: 64)); qs[i] = .object(q) }
            d["questions"] = .array(qs)
        })
        await #expect(throws: ViewError.malformed) { _ = try await w.serve(p) { try await api.review(questionID: id) } }
    }
    @Test func testUIOnlyUsesUnsignedReviewAPI() async throws {
        let (w, p, concrete, s) = try await setup()
        let api: any WorkspaceAPI = concrete
        let review = try await w.serve(p) { try await api.review(questionID: s.questions[0].questionID) }
        #expect(!Mirror(reflecting: review).children.contains { $0.label == "sig" || $0.label == "operation" })
        #expect(review.reviewed != nil)          // the F1 gate was passed: qid and hash recomputed, bound to doc.head and members_v
        await p.session.invalidateReviews()
        await #expect(throws: ViewError.invalidReview) { _ = try await api.decide(review, optionID: "approve") }
        #expect(try await api.pendingDecisions().isEmpty)
    }
    @Test func testBidiReviewPreservesHash() async throws {
        let (w, p, api, s) = try await setup()
        let q = s.questions[2]
        let review = try await w.serve(p) { try await api.review(questionID: q.questionID) }
        #expect(review.question.text.utf8.elementsEqual(q.text.utf8))
        #expect(review.question.text.contains("\u{FF39}"))                 // look-alikes are kept byte for byte (F1 text has no bidi controls)
        #expect(review.question.options[0].label.contains("\u{FF0D}"))
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
        let v = J(try StrictJSON.parse(Vectors.data, maxBytes: .max, maxDepth: 64))["suites"]["2"]
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
    private func lostDecision(apply: Bool = true) async throws -> (World, Phone, BridgeWorkspaceAPI, ID16, PendingRequestInfo, Data) {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        let s = try await w.serve(p) { try await api.snapshot() }
        let review = try await w.serve(p) { try await api.review(questionID: s.questions[0].questionID) }
        await w.host.setHandler { req in
            let response: HostReply
            if !apply, req.meta.object?["op"] == "decision" {
                response = .response(status: 200, headers: ["content-type": "application/json"], data: Data())
            } else { response = await w.host.handleView(req) }
            if req.meta.object?["op"] == "decision" { faults.enqueue(.disconnect, at: .pollDelivery) }
            return response
        }
        #expect(try await w.serve(p) { try await api.decide(review, optionID: "approve") } == .uncertain)
        let rows = try await api.pendingDecisions()
        let id = try #require(rows.first?.decisionID)
        let pending = try #require(try await p.session.pendingRequests().first { $0.logical == id })
        let envelope = try #require(try await p.session.storedEnvelope(rid: pending.rid))
        return (w, p, api, id, pending, envelope)
    }
    @Test func testLostResponseReplaysStoredEnvelope() async throws {
        let (w, p, api, id, pending, envelope) = try await lostDecision()
        let db = try await p.container.database()
        let charges = try await db.query("SELECT COUNT(*) AS n FROM bridge_charges").first?.int("n") ?? 0
        // Inside the stored answer's 60 s lifetime (P3-D22 never resurrects an expired chunk): the same rid reads it.
        w.clock.advance(milliseconds: 30_000); p.clock.advance(milliseconds: 30_000)
        #expect(try await w.serve(p) { try await p.session.reconcileDecision(id) } == .accepted)
        #expect(try await db.query("SELECT COUNT(*) AS n FROM bridge_charges").first?.int("n") == charges + 2)   // the resend and the confirming read
        #expect(await w.host.coreState().rids[pending.rid]?.digest == (try Bridge.Parts(envelope: envelope)).digest)
        #expect(try await api.pendingDecisions().isEmpty)
    }
    @Test func testExpiredOrUnknownRidReconcilesByQuestion() async throws {
        for expired in [false, true] {
            let (w, p, api, id, pending, envelope) = try await lostDecision(apply: false)
            await w.host.forgetOutcome(rid: pending.rid)
            await w.relay.forgetResponses(workspace: w.ws, device: w.phoneID, rid: pending.rid)     // the answer never reached the relay
            let captured = DecisionCapture()
            await w.host.setHandler { req in
                if req.meta.object?["op"] == "decision" {
                    await captured.save(try! await p.session.pendingRequests().first { $0.logical == id }, operation: try! canonicalJSON(req.meta))
                }
                return await w.host.handleView(req)
            }
            let elapsed: Int64 = expired ? 901_000 : 61_000
            w.clock.advance(milliseconds: elapsed); p.clock.advance(milliseconds: elapsed)
            #expect(try await w.serve(p) { try await api.reconcile(decisionID: id) } == .accepted)
            let replacement = try #require(await captured.attempt)
            #expect(replacement.rid != pending.rid && replacement.seq > pending.seq)
            #expect(try await p.session.storedEnvelope(rid: pending.rid) == nil)
            #expect(try Bridge.Parts(envelope: envelope).header.rid == pending.rid)
            #expect(try await p.session.uncertainRequests().isEmpty)
            let snapshot = try await w.serve(p) { try await api.snapshot() }
            #expect(snapshot.revision == 2) // exactly one successful CAS
            #expect(snapshot.questions.filter { $0.resolution?.byDeviceID == "d_" + w.phoneID.hex }.count == 1)
        }
    }
    @Test func testPendingDecisionsSurviveRestart() async throws {
        let (w, p, _, id, _, envelope) = try await lostDecision()
        let restarted = try await WorkspaceSession(p.session.cfg)
        let pending = try await restarted.pendingDecisions()
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
        await w.relay.forgetResponses(workspace: w.ws, device: w.phoneID, rid: pending.rid)
        try await w.host.rotate(remaining: await w.host.rosterEntries(), relay: w.relay, session: w.hostSession)
        w.clock.advance(milliseconds: 61_000); p.clock.advance(milliseconds: 61_000)
        // Remove the fault wrapper so a newly applied decision can return normally.
        let captured = DecisionCapture()
        await w.host.setHandler { req in
            if req.meta.object?["op"] == "decision" {
                let attempt = try! await p.session.pendingRequests().first { $0.logical == id }
                await captured.save(attempt, operation: try! canonicalJSON(req.meta))
            }
            return await w.host.handleView(req)
        }
        #expect(try await w.serve(p) { try await p.session.reconcileDecision(id) } == .accepted)
        let after = try #require(try await db.query("SELECT operation FROM decisions WHERE id=?", [.text(id.hex)]).first?.blob("operation"))
        #expect(before == after)
        #expect(try await p.session.currentEpoch() == 2)
        let replacement = try #require(await captured.attempt)
        #expect(replacement.rid != pending.rid && replacement.seq > pending.seq)
        #expect(await captured.operation == before)
        // The replacement's first rid (still at epoch 1) was refused by the RELAY's unsigned stale_epoch hint (P3-D8) and never
        // reached the host; the phone moved to epoch 2 only through the signed list and grants, then re-sealed the same operation.
        #expect(replacement.epoch == 2)
        #expect(await !w.host.coreState().rids.values.contains { if case .refusal(.staleEpoch) = $0.outcome { true } else { false } })
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
        let secondSigner = SoftwareSigner()
        let secondKeys = DemoKeys(sig: secondSigner.publicKey, kx: SoftwareKeyAgreer().publicKey)
        await w.host.setRoster([(w.phone, World.all), (secondKeys, World.all)])
        await w.host.setHandler { req in
            if req.meta.object?["op"] == "decision" {
                let op = try! Decisions.makeOp(workspace: w.ws, questionID: q, contentHash: r.question.contentHash,
                    decisionID: .fresh(211), answer: ["option_id": "approve"], signer: secondSigner)
                _ = await w.host.handleView(HostRequest(device: secondKeys.deviceID, scopes: World.all, meta: op, data: Data(), epoch: 1))
            }
            return await w.host.handleView(req)
        }
        let result = try await w.serve(p) { try await api.decide(r, optionID: "reject") }
        guard case .alreadyAnswered(let label, let at) = result else { Issue.record("Missing actor"); return }
        #expect(label == "Demo iPhone" && at > 0)
        let closed = try await w.serve(p) { try await api.review(questionID: q) }
        #expect(closed.question.resolution?.byDeviceID == "d_" + secondKeys.deviceID.hex)
        #expect(closed.question.resolution?.atMs == at)
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
        #expect(try await api.pendingDecisions().isEmpty)
    }
    @Test func offlineSubmissionRemainsUnsigned() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        let snapshot = try await w.serve(p) { try await api.snapshot() }
        let review = try await w.serve(p) { try await api.review(questionID: snapshot.questions[0].questionID) }
        faults.enqueue(.disconnect, at: .beforeQueue)
        await #expect(throws: ViewError.offline) { _ = try await api.decide(review, optionID: "approve") }
        #expect(try await p.container.database().query("SELECT * FROM decisions").isEmpty)
    }
    @Test func unsafeDraftsAreRejectedWithoutRewrite() async throws {
        let (w, _, api, _) = try await setup()
        await w.host.setRoster([(w.phone, World.all)])
        for title in ["", "Unsafe\u{202E}", String(repeating: "x", count: 201)] {
            let draft = NewTicketSubmission(creationID: .fresh(92), title: title, body: "")
            await #expect(throws: ViewError.invalidDraft) { _ = try await api.newTicket(draft) }
        }
        #expect(!validTicketKey("MOB-0001\n"))
    }
    @Test func testNewTicketRetryCreatesOnce() async throws {
        let (w, p, api, s) = try await setup()
        await w.host.setRoster([(w.phone, World.all), (w.primary.deviceKeys, World.all)])
        let draft = NewTicketSubmission(creationID: .fresh(90), title: "A ticket", body: "Text", epicKey: "FAC-0001")
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
    @Test func signatureAndEnvelopeRollbackTogether() async throws {
        let (w, p, api, s) = try await setup()
        let review = try await w.serve(p) { try await api.review(questionID: s.questions[0].questionID) }
        await p.session.setCrashHook { point in if point == "decision.inserted" { throw ViewError.malformed } }
        await #expect(throws: ViewError.offline) { _ = try await w.serve(p) { try await api.decide(review, optionID: "approve") } }
        #expect(try await p.container.database().query("SELECT * FROM decisions").isEmpty)
        #expect(try await p.session.pendingRequests().isEmpty)
    }
    @Test func reconciliationRefusesBackgroundAndNeverSentRows() async throws {
        let (w, p, api, id, _, _) = try await lostDecision()
        await api.setForeground(false)
        await #expect(throws: ViewError.offline) { _ = try await api.reconcile(decisionID: id) }
        #expect(try await api.pendingDecisions().count == 1)
        // Simulate a crash after atomic preparation but before the dispatch boundary.
        try await p.container.database().execute("UPDATE decisions SET dispatched=0 WHERE id=?", [.text(id.hex)])
        let restarted = try await WorkspaceSession(p.session.cfg)
        await #expect(throws: ViewError.offline) { _ = try await restarted.reconcileDecision(id) }
        #expect(try await restarted.pendingDecisions().isEmpty)
        #expect(try await restarted.pendingRequests().isEmpty)
        #expect(await w.host.coreState().epoch == 1)
    }
    @Test func pendingDecisionsPropagatesRemovalStateUnknown() async throws {
        let (w, _, api, _) = try await setup()
        await w.env.index.close()
        await #expect(throws: StoreError.removalStateUnknown(ws: w.ws.hex, generation: 1)) { _ = try await api.pendingDecisions() }
    }
    @Test func fakeHostOwnDecisionCASIsIdempotent() async throws {
        let (w, p, api, s) = try await setup()
        let review = try await w.serve(p) { try await api.review(questionID: s.questions[0].questionID) }
        await w.host.setHandler { req in
            if req.meta.object?["op"] == "decision" { _ = await w.host.handleView(req) }
            return await w.host.handleView(req)
        }
        #expect(try await w.serve(p) { try await api.decide(review, optionID: "approve") } == .accepted)
        #expect(try await w.serve(p) { try await api.snapshot() }.revision == 2)
    }
    /// Change detection by polling the activity cursor (`wait` is not served): while nothing changes the poller reads `activity.list` only
    /// and emits no snapshot; the interval backs off from 15 s toward 60 s; a host-side change is picked up within one interval and
    /// resets it to 15 s.
    @Test func aHostChangeIsPickedUpByTheCursorAndOnlyThen() async throws {
        let (w, p, api, initial) = try await setup()
        let stream = await api.events()
        let box = SnapCount()
        let result = try await w.serve(p, steps: 900) { () -> (Int, Int64) in
            var snapshots = 0
            for await event in stream {
                guard case .snapshot(let s) = event else { continue }
                snapshots += 1
                if snapshots == 1 {
                    // quiet for four intervals (>= 15+30+60+60 s on the fake clock), then the host changes
                    let start = p.clock.nowMs
                    while p.clock.nowMs - start < 170_000 { try Task.checkCancellation(); await Task.yield() }
                    try await w.host.replaceQuestionText(initial.questions[0].questionID, text: "Polling reset")
                    box.set(snapshots)
                    continue
                }
                return (snapshots, s.revision)
            }
            return (snapshots, 0)
        }
        #expect(box.value == 1)                    // nothing but the replayed cache until the host changed
        #expect(result.0 == 2 && result.1 == initial.revision + 1)
        await api.setForeground(false)
    }
    @Test func rejectsAmbiguousOptionsAndUnsafeKeys() async throws {
        let (w, p, api, snapshot) = try await setup()
        let original = snapshot.questions[0]
        // a stored review (`wire`) is re-checked as a host view is: colliding labels, duplicate or unclean keys, or a hash that no longer
        // reproduces are refused
        for options: JSONValue in [
            [["id": "a", "label": "\u{C9}"], ["id": "b", "label": "e\u{301}\u{301}"]],
            [["id": "a", "label": "YES"], ["id": "b", "label": "yes"]],
            [["id": "a", "label": "One"], ["id": "a", "label": "Two"]],
            [["id": "a\u{202E}", "label": "One"]], [["id": "", "label": "One"]]
        ] {
            var q = original.wire.object!
            q["options"] = options
            #expect(throws: ViewError.malformed) { _ = try Question(wire: .object(q), workspace: w.ws) }
        }
        var ok = original.wire.object!; ok["options"] = [["id": "approve", "label": "Approve"]]
        #expect(throws: ViewError.malformed) { _ = try Question(wire: .object(ok), workspace: w.ws) }      // another option list: another hash
        _ = try Question(wire: original.wire, workspace: w.ws)
        // ... and so is a host view carrying them
        await w.host.setHandler(await w.host.tampering("ticket.get") { d in
            var qs = d["questions"]!.array!
            var q = qs[0].object!
            q["options"] = [["key": "a", "label": "YES"], ["key": "b", "label": "yes"]]
            qs[0] = .object(q); d["questions"] = .array(qs)
        })
        await #expect(throws: ViewError.malformed) { _ = try await w.serve(p) { try await api.review(questionID: original.questionID) } }
    }
    @Test func snapshotRejectsDuplicatesAndInvalidTimes() async throws {
        let (w, p, api, _) = try await setup()
        for field in ["rows", "as_of", "updated_at"] {
            await w.host.setHandler(await w.host.tampering("ticket.query") { d in
                if field == "as_of" { d[field] = "yesterday" }
                else if field == "updated_at" {
                    var rows = d["rows"]!.array!; var r = rows[0].object!; r[field] = "2026-13-45T00:00:00Z"; rows[0] = .object(r); d["rows"] = .array(rows)
                } else { var rows = d["rows"]!.array!; rows.append(rows[0]); d["rows"] = .array(rows) }
            })
            await #expect(throws: ViewError.malformed) { _ = try await w.serve(p) { try await api.snapshot() } }
        }
    }
    @Test func newTicketLostResponseRetriesWithoutOrphan() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let p = try await w.makePhone()
        await w.host.setRoster([(w.phone, World.all)])
        let api = BridgeWorkspaceAPI(session: p.session)
        let draft = NewTicketSubmission(creationID: .fresh(209), title: "Persisted draft", body: "Body")
        await w.host.setHandler { req in
            let reply = await w.host.handleView(req)
            if req.meta.object?["op"] == "new_ticket" { faults.enqueue(.disconnect, at: .pollDelivery) }
            return reply
        }
        await #expect(throws: (any Error).self) { _ = try await w.serve(p) { try await api.newTicket(draft) } }
        #expect(try await p.session.pendingRequests().count == 1)
        await w.host.clearViewHandler()
        w.clock.advance(milliseconds: 901_000); p.clock.advance(milliseconds: 901_000)
        let ticket = try await w.serve(p) { try await api.newTicket(draft) }
        #expect(ticket.title == draft.title)
        #expect(try await p.session.pendingRequests().isEmpty)
        #expect(try await w.serve(p) { try await api.snapshot() }.tickets.count == 3)
    }
    @Test func newTicketRejectsCanonicalEquivalentReturnedText() async throws {
        let (w, p, api, _) = try await setup()
        await w.host.setRoster([(w.phone, World.all)])
        await w.host.setHandler { req in
            guard case .response(let status, let headers, let data) = await w.host.handleView(req),
                  var m = try? StrictJSON.parse(data).object, var ticket = m["ticket"]?.object else { return .refuse(.malformed) }
            ticket["title"] = "e\u{301}"; m["ticket"] = .object(ticket)
            return .response(status: status, headers: headers, data: try! canonicalJSON(.object(m)))
        }
        await #expect(throws: ViewError.malformed) {
            _ = try await w.serve(p) { try await api.newTicket(NewTicketSubmission(creationID: .fresh(208), title: "é", body: "")) }
        }
    }
    @Test func restartRedrivesPendingOnStartAndForeground() async throws {
        for useStart in [true, false] {
            let (w, p, _, id, _, _) = try await lostDecision()
            try await p.container.database().execute("UPDATE decisions SET state='pending' WHERE id=?", [.text(id.hex)])
            let restarted = try await WorkspaceSession(p.session.cfg)
            let api: any WorkspaceAPI = BridgeWorkspaceAPI(session: restarted)
            try await w.serve(p) {
                if useStart { await api.start() } else { await api.setForeground(true) }
                while !(try await api.pendingDecisions()).isEmpty { try Task.checkCancellation(); await Task.yield() }
            }
            #expect(try await api.pendingDecisions().isEmpty)
        }
    }
    @Test func backgroundCancelsPollerAndSubscriptionReplaysCache() async throws {
        let (w, p, api, snapshot) = try await setup()
        await api.setForeground(false)
        let stream = await api.events()
        var events = stream.makeAsyncIterator()
        #expect(await events.next() == .snapshot(snapshot))
        #expect(await events.next() == .connection(.online))
        #expect(p.clock.sleeperCount == 0)
        await api.setForeground(true)
        try await w.serve(p) {
            for await event in stream { if case .connection(.online) = event { return } }
            Issue.record("the event stream ended or was cancelled before the poller reported")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while p.clock.sleeperCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
        #expect(p.clock.sleeperCount == 1) // the live poller is parked on its next interval
        await api.setForeground(false)
        let seq = try await p.session.nextSeq()
        p.clock.advance(milliseconds: 120_000)
        for _ in 0..<100 { await Task.yield() }
        #expect(try await p.session.nextSeq() == seq)
        #expect(p.clock.sleeperCount == 0)
    }
    @Test func generationEndEmitsRemoved() async throws {
        let (w, _, api, _) = try await setup()
        await api.setForeground(false)
        let stream = await api.events()
        w.env.generation.invalidate()
        await #expect(throws: (any Error).self) { _ = try await api.pendingDecisions() }
        let removed = await boundedWait("the .removed event and stream end") {
            var removed = false
            for await event in stream { if event == .removed { removed = true } }
            return removed
        }
        #expect(removed == true)
    }
    @Test func testForegroundPollingThirtyMinutesWithinQuota() async throws {
        let (w, p, api, _) = try await setup()
        let start = w.clock.nowMs
        let stream = await api.events()
        let consumed = Consumed()
        let count = try await w.serve(p, steps: 4000, timeout: .seconds(60), consumed: consumed) {
            var polls = 0
            for await event in stream {
                if case .snapshot = event { consumed.bump() }
                if case .connection(.online) = event {
                    polls += 1
                    if w.clock.nowMs - start >= 1_800_000 { return polls }
                }
            }
            return polls
        }
        await p.session.setForeground(false)
        #expect(w.clock.nowMs - start >= 1_800_000)
        #expect((25...45).contains(count))      // 15 s doubling to 60 s: one feed read per interval, no snapshot while nothing changes
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
        // serve cancels its body on timeout but not these unstructured tasks, so cancel them with it.
        let result = try await w.serve(p) {
            await withTaskCancellationHandler { (await taskA.value, await taskB.value) } onCancel: { taskA.cancel(); taskB.cancel() }
        }
        #expect(result.0 == result.1 && result.0 > 0)
        #expect(try await p.session.nextSeq() <= before + 1)
        await p.session.setForeground(false)
    }
}

extension FakeHost {
    fileprivate func clearViewHandler() { handler = nil }
    fileprivate func reopenQuestionsForTest() {
        guard var state = viewState else { return }
        state.questions = state.questions.map { var q = $0; q.answer = nil; return q }
        viewState = state
    }
}

final class SnapCount: @unchecked Sendable {
    private let lock = NSLock(); private var v = 0
    var value: Int { lock.withLock { v } }
    func set(_ n: Int) { lock.withLock { v = n } }
}
private actor ReadCounter { var count = 0; func next() -> Int { count += 1; return count } }

private actor DecisionCapture {
    var attempt: PendingRequestInfo?
    var operation: Data?
    func save(_ attempt: PendingRequestInfo?, operation: Data) { self.attempt = attempt; self.operation = operation }
}
