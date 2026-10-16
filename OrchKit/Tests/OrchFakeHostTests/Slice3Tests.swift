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
        let snapshot = try #require(review.snapshot)
        await #expect(throws: ViewError.invalidReview) { _ = try await api.answer(snapshot, option: "approve") }
        #expect(try await api.pendingWrites().isEmpty)
    }
    @Test func testBidiReviewPreservesHash() async throws {
        let (w, p, api, s) = try await setup()
        let q = s.questions[2]
        let review = try await w.serve(p) { try await api.review(questionID: q.questionID) }
        #expect(review.question.text.utf8.elementsEqual(q.text.utf8))
        #expect(review.question.text.contains("\u{FF39}"))                 // look-alikes are kept byte for byte (F1 text has no bidi controls)
        #expect(review.question.options[0].label.contains("\u{FF0D}"))
        #expect(review.question.contentHash == q.contentHash)
        let snapshot = try #require(review.snapshot)
        guard case .landed = try await w.serve(p, { try await api.answer(snapshot, option: "approve") }) else { Issue.record("not landed"); return }
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
        await #expect(throws: (any Error).self) { _ = try await api.pendingWrites() }
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
