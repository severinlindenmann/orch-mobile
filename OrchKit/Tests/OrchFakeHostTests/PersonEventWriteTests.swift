import Foundation
import Testing
import OrchCustody
import OrchProtocol
import OrchStore
@testable import OrchClient
@testable import OrchFakeHost

/// C2b increment 2: answers end to end against the FakeHost (Demo grant, passphrase custody). The plan 9 list for answers: crash and
/// transaction failures, the window and clock, gate coverage, delivery outcomes, C-auto, the adversarial lifecycle and settlement.

/// Counts crash-hook points and fails chosen ones (once each).
final class Hooks: @unchecked Sendable {
    struct Crash: Error {}
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var failing: Set<String> = []
    private var cancelling: Set<String> = []
    init(fail: Set<String> = []) { failing = fail }
    func fail(_ name: String) { lock.withLock { _ = failing.insert(name) } }
    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    func hit(_ name: String) throws {
        let f: Bool = lock.withLock {
            counts[name, default: 0] += 1
            return failing.remove(name) != nil
        }
        if f { throw Crash() }
    }
}

/// Counts what reaches the host per op.
final class OpCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n: [String: Int] = [:]
    func bump(_ op: String) { lock.withLock { n[op, default: 0] += 1 } }
    func value(_ op: String) -> Int { lock.withLock { n[op] ?? 0 } }
}

extension FakeHost {
    /// A restore at the host: the question loses its answer (the landed event is no longer what the question shows).
    fileprivate func restoreAwayAnswers() {
        guard var s = viewState else { return }
        s.questions = s.questions.map { var q = $0; q.answer = nil; return q }
        viewState = s
    }
    /// An UNSELECTED option's cost changes (its hash changes with it).
    fileprivate func changeCost(question number: String, key: String, cost: String) {
        guard var s = viewState, let i = s.questions.firstIndex(where: { $0.number == number }) else { return }
        s.questions[i].options = s.questions[i].options.map { $0.key == key ? F1QuestionOption(key: $0.key, label: $0.label, cost: cost) : $0 }
        viewState = s
    }
    fileprivate func dropOutcomeRecords() { viewState?.outcomes = [:] }
}

@Suite struct PersonEventWriteTests {
    struct Rig {
        let w: World
        let p: Phone
        let api: BridgeWorkspaceAPI
        let snapshot: ReviewedSnapshot
        let hooks: Hooks
        let ops: OpCounter
    }

    /// A phone with Demo writes, the first seeded question reviewed, and a host that counts ops (then serves them as `serve` says).
    func rig(_ serve: (@Sendable (HostRequest, FakeHost) async -> HostReply?)? = nil, question: Int = 0) async throws -> Rig {
        let w = try await World.make()
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        let ops = OpCounter()
        let host = w.host
        await w.host.setHandler { req in
            ops.bump(req.meta.object?["op"]?.string ?? "?")
            if let serve, let r = await serve(req, host) { return r }
            return await host.handleView(req)
        }
        let s = try await w.serve(p) { try await api.snapshot() }
        let review = try await w.serve(p) { try await api.review(questionID: s.questions[question].questionID) }
        let hooks = Hooks()
        await p.session.setCrashHook { try hooks.hit($0) }
        return Rig(w: w, p: p, api: api, snapshot: try #require(review.snapshot), hooks: hooks, ops: ops)
    }

    func answer(_ r: Rig, _ option: String = "approve", steps: Int = 400) async throws -> WriteOutcome {
        let api = r.api, s = r.snapshot
        return try await r.w.serve(r.p, steps: steps) { try await api.answer(s, option: option) }
    }

    func rows(_ p: Phone, _ sql: String, _ args: [SQLValue] = []) async throws -> [SQLRow] { try await p.container.database().query(sql, args) }

    /// A new session over the same storage (an app relaunch); the old one goes to the background first so it sends nothing more.
    func relaunch(_ r: Rig, hooks: Hooks? = nil) async throws -> Phone {
        await r.p.session.setForeground(false)
        let s = try await WorkspaceSession(r.p.session.configuration)
        if let hooks { await s.setCrashHook { try hooks.hit($0) } }
        return Phone(session: s, container: r.p.container, clock: r.p.clock)
    }

    func settleAll(_ r: Rig, _ p: Phone) async throws -> [WriteOutcome] {
        let ids = try await p.session.pendingWrites().map(\.reviewID)
        var out: [WriteOutcome] = []
        for id in ids { out.append(try await r.w.serve(p, steps: 400) { try await p.session.settle(reviewID: id) }) }
        return out
    }

    func reviewState(_ p: Phone) async throws -> [String] { try await rows(p, "SELECT state FROM pe_reviews ORDER BY created_ms").compactMap { $0.text("state") } }
    func attemptStates(_ p: Phone) async throws -> [String] { try await rows(p, "SELECT state FROM pe_attempts ORDER BY n").compactMap { $0.text("state") } }

    // MARK: basics

    @Test func anAnswerLandsAndIsConfirmed() async throws {
        let r = try await rig()
        let out = try await answer(r)
        guard case .landed(let seq, let key) = out else { Issue.record("\(out)"); return }
        #expect(seq >= 1 && key == "MOB-0001")
        #expect(r.hooks.count("pe.sign") == 1 && r.ops.value("answer") == 1)
        #expect(try await r.api.pendingWrites().isEmpty)
        #expect(try await rows(r.p, "SELECT rid FROM bridge_requests").isEmpty)
        #expect(try await attemptStates(r.p) == ["landed"])
        #expect(try await reviewState(r.p) == ["landed"])
        #expect(try await r.p.session.writeOutcome(reviewID: try #require(try await rows(r.p, "SELECT review FROM pe_reviews").first?.text("review"))) == out)
        let after = try await r.w.serve(r.p) { try await r.api.snapshot() }
        #expect(after.questions.first { $0.questionID == r.snapshot.question.questionID }?.resolution?.byDeviceID == "d_" + r.w.phoneID.hex)
    }

    @Test func aLandingTheQuestionNoLongerShowsIsLandedUnconfirmed() async throws {
        let r = try await rig { req, host in
            guard req.meta.object?["op"] == "answer" else { return nil }
            let reply = await host.handleView(req)
            await host.restoreAwayAnswers()
            return reply
        }
        let out = try await answer(r)
        guard case .landedUnconfirmed(let seq, .changed) = out, seq != nil else { Issue.record("\(out)"); return }
        #expect(try await reviewState(r.p) == ["landed_unconfirmed"])
        // a landing is never downgraded 
        do { try await r.p.container.database().execute("UPDATE pe_reviews SET state='needs_review'"); Issue.record("not refused") }
        catch SQLiteError.constraint(_, let m) { #expect(m == "pe_reviews: a landing is final") }
    }

    /// The confirming read fails once after a landing: the review stays `landed` with no outcome (not `landed_unconfirmed`), the caller
    /// is told `landed` with the seq the write returned, and a later pass confirms it with the log's seq.
    @Test func aTransientConfirmFailureIsRetriedNotUnconfirmed() async throws {
        let landed = Done(), failed = Done()
        let r = try await rig { req, host in
            let op = req.meta.object?["op"]?.string
            if op == "answer" { landed.set(); return nil }
            if op == "ticket.get", landed.value, !failed.value { failed.set(); return .refuse(.malformed) }
            return nil
        }
        let out = try await answer(r)
        let written = try #require(try await rows(r.p, "SELECT evidence FROM pe_attempts").first.flatMap { AttemptSeq.of($0) })
        #expect(out == .landed(seq: written, key: "MOB-0001"))
        let review = try #require(try await rows(r.p, "SELECT review, state, outcome FROM pe_reviews").first)
        #expect(review.text("state") == "landed" && review.text("outcome") == nil)
        let again = try await r.w.serve(r.p) { try await r.p.session.settle(reviewID: review.text("review")!) }
        guard case .landed(let seq, _) = again else { Issue.record("\(again)"); return }
        #expect(seq >= 1)
        #expect(try await reviewState(r.p) == ["landed"])
    }

    @Test func freeTextIsAnsweredOnTheMac() async throws {
        let w = try await World.make()
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        _ = try await w.host.demoAskQuestion(DemoQuestionSeed(ticket: "MOB-0001", text: "Anything else?", options: [], createdAgoMs: 1000))
        let snap = try await w.serve(p) { try await api.snapshot() }
        // not listed, counted as "needs your Mac"
        #expect(snap.macOnlyCount == 2 && !snap.questions.contains { $0.text == "Anything else?" })
        // and even a snapshot of it built by hand is refused before anything is signed
        let get = try await w.serve(p) { try await p.session.ticketGet("MOB-0001") }
        let f1 = try #require(get.questions.compactMap(\.question).first { $0.options.isEmpty })
        let reviewed = try f1.reviewed(ticketUID: get.uid, workspace: w.ws, basedOn: get.headHash, rosterV: get.membersV)
        let q = try Question(f1, ticketKey: get.key, ticketUID: get.uid, workspace: w.ws, createdMs: 0, deviceLabel: { _, _ in "" })
        let s = ReviewedSnapshot(reviewed: reviewed, token: UUID(), question: q, realm: .demo, workspaceID: w.ws, generation: 1)
        #expect(!s.answerable)
        await #expect(throws: ViewError.invalidOption) { _ = try await api.answer(s, option: "anything") }
        #expect(try await p.container.database().query("SELECT * FROM pe_attempts").isEmpty)
    }

    /// Until the phone renders every bound field, a choice question with details (or why, recommended, option text, facts) is Mac-only on the
    /// direct path, with the constant reason; a plain one is still answerable. The fake host seeds one of each.
    @Test func aQuestionWithPartsThePhoneDoesNotShowIsAnsweredOnTheMac() async throws {
        let w = try await World.make()
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        let snap = try await w.serve(p) { try await api.snapshot() }
        #expect(snap.questions.count == 3 && snap.macOnlyCount == 1)
        #expect(snap.cannotVerify.map(\.reason) == [F1Question.Content.cannotShowAllReason])
        #expect(!snap.questions.contains { $0.details != nil || $0.why != nil || $0.recommended != nil })
        let get = try await w.serve(p) { try await p.session.ticketGet("MOB-0001") }
        let f1 = try #require(get.questions.compactMap(\.question).first { $0.details != nil })
        let reviewed = try f1.reviewed(ticketUID: get.uid, workspace: w.ws, basedOn: get.headHash, rosterV: get.membersV)
        let q = try Question(f1, ticketKey: get.key, ticketUID: get.uid, workspace: w.ws, createdMs: 0, deviceLabel: { _, _ in "" })
        let s = ReviewedSnapshot(reviewed: reviewed, token: UUID(), question: q, realm: .demo, workspaceID: w.ws, generation: 1)
        #expect(!s.answerable)
        await #expect(throws: ViewError.invalidOption) { _ = try await api.answer(s, option: "approve") }
        // a plain one stays answerable
        let plain = try #require(get.questions.compactMap(\.question).first { $0.details == nil })
        let pr = try plain.reviewed(ticketUID: get.uid, workspace: w.ws, basedOn: get.headHash, rosterV: get.membersV)
        let pq = try Question(plain, ticketKey: get.key, ticketUID: get.uid, workspace: w.ws, createdMs: 0, deviceLabel: { _, _ in "" })
        #expect(ReviewedSnapshot(reviewed: pr, token: UUID(), question: pq, realm: .demo, workspaceID: w.ws, generation: 1).answerable)
    }

    // MARK: crash and transaction failures

    @Test(arguments: ["pe.signed", "pe.inserted"])
    func aFailureInsideTheSigningTransactionLeavesNothing(_ point: String) async throws {
        let r = try await rig()
        r.hooks.fail(point)
        await #expect(throws: Hooks.Crash.self) { _ = try await answer(r) }
        #expect(r.hooks.count("pe.sign") == 1)                  // a signature existed, but never became durable or sent
        #expect(try await rows(r.p, "SELECT * FROM pe_attempts").isEmpty)
        #expect(try await rows(r.p, "SELECT * FROM pe_reviews").isEmpty)
        #expect(try await rows(r.p, "SELECT * FROM bridge_requests WHERE attempt IS NOT NULL").isEmpty)
        #expect(r.ops.value("answer") == 0)
    }

    /// COMMIT itself fails (the body ran to its end; a deferred foreign key only checked at COMMIT refuses it): as distinct from a
    /// rollback inside the body, and with the same result: nothing durable, nothing sent.
    @Test func aCommitFailureLeavesNothing() async throws {
        let r = try await rig()
        let db = try await r.p.container.database()
        try await db.execute("CREATE TABLE commit_bomb (x TEXT REFERENCES pe_reviews(review) DEFERRABLE INITIALLY DEFERRED)")
        try await db.execute("CREATE TRIGGER commit_bomb_arm AFTER INSERT ON pe_attempts BEGIN INSERT INTO commit_bomb VALUES ('no such review'); END")
        do { _ = try await answer(r); Issue.record("committed") }
        catch SQLiteError.constraint(_, let m) { #expect(m.contains("FOREIGN KEY")) }
        #expect(r.hooks.count("pe.inserted") == 1)              // the body completed: it is the COMMIT that failed
        #expect(r.hooks.count("pe.sign") == 1)
        #expect(try await rows(r.p, "SELECT * FROM pe_attempts").isEmpty)
        #expect(try await rows(r.p, "SELECT * FROM pe_reviews").isEmpty)
        #expect(try await rows(r.p, "SELECT * FROM bridge_requests WHERE attempt IS NOT NULL").isEmpty)
        #expect(r.ops.value("answer") == 0)
    }

    /// Cancelled after the commit: of the caller (the review's driver goes on), or of the driver itself after the charge. Either way the
    /// committed attempt is settled, never lost or re-signed.
    @Test(arguments: ["pe.driver", "post.charged"])
    func aCancellationAfterCommitIsSettled(_ point: String) async throws {
        let r = try await rig()
        let hooks = r.hooks
        await r.p.session.setCrashHook { name in
            try hooks.hit(name)
            if name == point, hooks.count(name) == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        _ = try? await answer(r)
        let out = try await settleAll(r, r.p)
        let state = try await reviewState(r.p)
        #expect(state == ["landed"])
        if !out.isEmpty { guard case .landed = out.first else { Issue.record("\(out)"); return } }
        #expect(r.hooks.count("pe.sign") == 1 && r.ops.value("answer") == 1)
        #expect(try await rows(r.p, "SELECT * FROM pe_attempts").count == 1)
    }

    @Test func aCrashRightAfterCommitSendsTheSameBytesOnTheFirstPost() async throws {
        let r = try await rig()
        r.hooks.fail("post.precharge")
        #expect(try await answer(r) == .checking)
        let stored = try #require(try await rows(r.p, "SELECT event, digest, dispatched FROM pe_attempts").first)
        #expect(stored.int("dispatched") == 0 && r.ops.value("answer") == 0)
        let p2 = try await relaunch(r)
        let out = try await settleAll(r, p2)
        guard case .landed = out.first else { Issue.record("\(out)"); return }
        #expect(try await rows(r.p, "SELECT * FROM pe_attempts").count == 1)
        #expect(r.hooks.count("pe.sign") == 1 && r.ops.value("answer") == 1)
        // what landed is exactly the stored event
        let idem = try #require(try await rows(r.p, "SELECT idem FROM pe_attempts").first?.text("idem"))
        #expect(await r.w.host.outcomeRecord(device: r.w.phoneID, idem: idem)?.state == "committed")
    }

    @Test func aCrashAfterTheChargeIsSettledNeverDiscarded() async throws {
        let r = try await rig()
        r.hooks.fail("post.charged")
        // charged (possibly sent) but never handed over: settled by reading, then the same bytes under a new rid in the window
        let out = try await answer(r)
        guard case .landed = out else { Issue.record("\(out)"); return }
        #expect(r.ops.value("outcome.get") >= 1 && r.ops.value("answer") == 1 && r.hooks.count("pe.sign") == 1)
        let a = try #require(try await rows(r.p, "SELECT dispatched, state FROM pe_attempts").first)
        #expect(a.int("dispatched") == 1)
        #expect(a.text("state") == "landed")
        // the marker never falls
        do { try await r.p.container.database().execute("UPDATE pe_attempts SET dispatched=0"); Issue.record("not refused") }
        catch SQLiteError.constraint(_, let m) { #expect(m == "pe_attempts: dispatched never falls") }
    }

    @Test func aCrashWhileTerminalEvidenceIsPersistedLosesNothing() async throws {
        let r = try await rig()
        r.hooks.fail("pe.evidence")
        do { _ = try await answer(r); Issue.record("no failure") }
        catch let e as AnswerCommitted { #expect(e.underlying is Hooks.Crash) }     // after the commit: never "nothing signed"
        #expect(try await attemptStates(r.p) == ["sent"])        // rolled back with its evidence
        let out = try await settleAll(r, r.p)
        guard case .landed = out.first else { Issue.record("\(out)"); return }
        #expect(await r.w.host.loggedCount() == 1)
        #expect(r.ops.value("answer") == 1)
    }

    // MARK: window and clock

    @Test func theWindowEdges() {
        let signedAt: Int64 = 10_000_000
        func holds(wall: Int64, offset: Int64 = 0, mono: Int64 = 0, ulid: Int64 = signedAt, signedWall: Int64 = signedAt) -> Bool {
            WriteClock(wallMs: wall, offsetMs: offset, monoMs: mono).holds(ulidMs: ulid, signedWallMs: signedWall)
        }
        #expect(holds(wall: signedAt + 840_000))
        #expect(!holds(wall: signedAt + 840_001))
        #expect(!holds(wall: signedAt + 900_000))
        #expect(holds(wall: signedAt, ulid: signedAt + 300_000))
        #expect(!holds(wall: signedAt, ulid: signedAt + 300_001))
        // the monotonic term alone: wall and host ages are well inside (100 s), only the monotonic age is past 840 s
        #expect(holds(wall: signedAt + 100_000, mono: 840_000))
        #expect(!holds(wall: signedAt + 100_000, mono: 840_001))
        #expect(!holds(wall: signedAt + 100_000, mono: 841_000))
        // a backward wall jump cannot extend it: the monotonic age still counts
        #expect(!holds(wall: signedAt - 3_600_000, mono: 841_000))
        // nor can an offset adopted later that shrinks the host age: the wall age since signing counts
        #expect(!holds(wall: signedAt + 841_000, offset: -600_000))
        // a forward wall jump ends it at once
        #expect(!holds(wall: signedAt + 7_200_000, mono: 1_000))
    }

    /// SH5: a write still being settled exposes what was signed, from `pe_reviews.snapshot`, after a relaunch and after the question
    /// changed at the host.
    @Test func aPendingWriteShowsTheStoredReviewNotTheCurrentQuestion() async throws {
        let r = try await rig()
        r.hooks.fail("post.precharge")
        #expect(try await answer(r) == .checking)
        await r.w.host.changeCost(question: r.snapshot.reviewed.question.id, key: "reject", cost: "$999")
        let p2 = try await relaunch(r)
        _ = try await r.w.serve(p2) { try await BridgeWorkspaceAPI(session: p2.session).snapshot() }
        let status = try #require(try await p2.session.pendingWrites().first)
        let stored = try #require(status.review)
        #expect(stored.text.utf8.elementsEqual(r.snapshot.text.utf8))
        #expect(stored.option == "approve" && stored.qid == r.snapshot.qid && stored.hash == r.snapshot.hash)
        #expect(stored.options.map(\.id) == r.snapshot.reviewed.question.options.map(\.key))
        #expect(stored.options.map(\.cost) == r.snapshot.reviewed.question.options.map(\.cost))
        #expect(!stored.options.contains { $0.cost == "$999" })
    }

    @Test func aJobDelayedPastTheWindowIsNeverSentAndAsksForANewReview() async throws {
        let r = try await rig()
        r.hooks.fail("post.precharge")
        #expect(try await answer(r) == .checking)
        let rid = try #require(try await rows(r.p, "SELECT rid FROM bridge_requests WHERE attempt IS NOT NULL").first?.text("rid").flatMap(ID16.init(hex:)))
        // resend of the raw stored envelope while the event is past the window by the host clock (the row itself is young): the gate
        let offset = try await r.p.session.clockOffsetMs()
        try await r.p.session.setClockOffset(offset + 850_000)
        await #expect(throws: WriteGateError.windowPassed) { _ = try await r.w.serve(r.p) { try await r.p.session.resend(rid: rid) } }
        try await r.p.session.setClockOffset(offset)
        r.w.clock.advance(milliseconds: 841_000); r.p.clock.advance(milliseconds: 841_000)
        let p2 = try await relaunch(r)
        #expect(try await settleAll(r, p2) == [.needsReview(.notSent)])
        #expect(r.ops.value("answer") == 0)
        #expect(try await attemptStates(r.p) == ["discarded"])
        #expect(try await reviewState(r.p) == ["needs_review"])
        #expect(try await rows(r.p, "SELECT rid FROM bridge_requests WHERE attempt IS NOT NULL").isEmpty)
    }

    @Test func aStaleTimestampNeverChangesTheEventID() async throws {
        let r = try await rig()
        try await r.p.session.setClockOffset(-350_000)       // a wrong offset: the bridge stamp is refused, the event id stays as signed
        let out = try await answer(r)
        guard case .landed = out else { Issue.record("\(out)"); return }
        let ids = try await rows(r.p, "SELECT idem, ulid_ms, signed_offset_ms FROM pe_attempts")
        #expect(ids.count == 1 && ids[0].int("signed_offset_ms") == -350_000)
        #expect(try await r.p.session.clockOffsetMs() != -350_000)       // adopted from the host's stale_timestamp
        #expect(r.hooks.count("pe.sign") == 1)
    }

    // MARK: gate coverage

    @Test func aRawWriteMetaIsRefusedEverywhere() async throws {
        let r = try await rig()
        let actor = try PhoneActor(person: await r.w.primary.personID, device: r.w.phoneID, auth: .passphrase)
        let id = try ULID.make(timeMs: r.w.clock.nowMs, random: Data(repeating: 4, count: 10))
        let e = try PhoneEvents.sign(try PhoneEvents.unsignedAnswer(r.snapshot.reviewed, option: "approve", text: nil, id: id, actor: actor, workspace: r.w.ws),
                                     signer: r.w.env.device.sig)
        await #expect(throws: ViewError.writesUnavailable) { _ = try await r.w.serve(r.p) { try await r.p.session.exchange(meta: try R2.writeMeta(e)) } }
        #expect(r.ops.value("answer") == 0)
    }

    /// MUST 1: a write row with no attempt never reaches `bridgePost` (the permit follows the row's kind).
    @Test func aWriteRowStrippedOfItsAttemptIsNeverPosted() async throws {
        let r = try await rig()
        r.hooks.fail("post.precharge")
        #expect(try await answer(r) == .checking)
        let rid = try #require(try await rows(r.p, "SELECT rid FROM bridge_requests WHERE attempt IS NOT NULL").first?.text("rid").flatMap(ID16.init(hex:)))
        try await r.p.container.database().execute("UPDATE bridge_requests SET attempt=NULL")
        await #expect(throws: ViewError.writesUnavailable) { _ = try await r.w.serve(r.p) { try await r.p.session.resend(rid: rid) } }
        #expect(r.ops.value("answer") == 0)
    }

    @Test func aReSealOfANonCurrentAttemptIsRefused() async throws {
        let r = try await rig()
        r.hooks.fail("post.precharge")
        #expect(try await answer(r) == .checking)
        let row = try #require(try await rows(r.p, "SELECT rid FROM bridge_requests WHERE attempt IS NOT NULL").first?.text("rid").flatMap(ID16.init(hex:)))
        let stored = try #require(try await r.p.session.loadRow(row))
        try await r.p.container.database().execute("UPDATE pe_reviews SET current_idem='01ARZ3NDEKTSV4RRFFQ69G5FAV'")
        await #expect(throws: WriteGateError.notCurrent) {
            _ = try await r.p.session.prepare(logical: stored.logical, plaintext: stored.plaintext, replacing: row, reconciled: true)
        }
        await #expect(throws: WriteGateError.notCurrent) { _ = try await r.w.serve(r.p) { try await r.p.session.resend(rid: row) } }
        #expect(r.ops.value("answer") == 0)
    }

    /// Each re-seal path on its own (same rid: WS stale-epoch re-seal; new rid: replace, reconcile) refuses a non-current attempt.
    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func everyReSealPathRefusesANonCurrentAttempt(_ reconciled: Bool, _ reuseRid: Bool) async throws {
        let r = try await rig()
        r.hooks.fail("post.precharge")
        #expect(try await answer(r) == .checking)
        let row = try #require(try await rows(r.p, "SELECT rid FROM bridge_requests WHERE attempt IS NOT NULL").first?.text("rid").flatMap(ID16.init(hex:)))
        let stored = try #require(try await r.p.session.loadRow(row))
        // superseded by a (hand-made) newer attempt: the review's current_idem moved on
        try await r.p.container.database().execute("UPDATE pe_reviews SET current_idem='01ARZ3NDEKTSV4RRFFQ69G5FAV'")
        await #expect(throws: WriteGateError.notCurrent) {
            _ = try await r.p.session.prepare(logical: stored.logical, plaintext: stored.plaintext, replacing: row, reconciled: reconciled, reuseRid: reuseRid)
        }
        #expect(try await rows(r.p, "SELECT rid FROM bridge_requests WHERE attempt IS NOT NULL").count == 1)
        #expect(r.ops.value("answer") == 0)
    }

    /// MUST 4: the stored event must re-bind to its reviewed snapshot byte for byte at every send.
    @Test func anEventThatNoLongerMatchesItsSnapshotIsNeverSent() async throws {
        let r = try await rig()
        r.hooks.fail("post.precharge")
        #expect(try await answer(r) == .checking)
        let db = try await r.p.container.database()
        let snap = try #require(try await rows(r.p, "SELECT snapshot FROM pe_reviews").first?.blob("snapshot"))
        var o = try #require(try StrictJSON.parse(snap).object)
        o["option"] = "reject"
        try await db.execute("UPDATE pe_reviews SET snapshot=?", [.blob(try canonicalJSON(.object(o)))])
        let p2 = try await relaunch(r)
        #expect(try await settleAll(r, p2) == [.needsReview(.notSent)])
        #expect(r.ops.value("answer") == 0)
    }

    @Test func aGrantForAnotherTransportIsRefusedAtInit() async throws {
        let w = try await World.make()
        let p = try await w.makePhone()
        let otherRelay = try FakeRelay(capability: w.env.capability, context: w.env.context, clock: w.clock, wall: w.clock, entropy: SystemEntropy())
        var cfg = p.session.configuration
        cfg.transport = try InProcessRelayTransport(context: w.env.context, relay: otherRelay)
        await #expect(throws: RealmViolation.wrongTransport) { _ = try await WorkspaceSession(cfg) }
        cfg.processLocalWriteGrant = nil
        let noWrites = try await WorkspaceSession(cfg)
        #expect(await !noWrites.writesAvailable())
    }

    // MARK: delivery outcomes

    @Test func aLostResponseIsSettledByOutcomeGetAndRunsOnce() async throws {
        let r = try await rig()
        await r.w.host.demoLoseNextWriteResponse()
        let out = try await answer(r)
        guard case .landed = out else { Issue.record("\(out)"); return }
        #expect(await r.w.host.loggedCount() == 1)
        #expect(r.hooks.count("pe.sign") == 1)
        #expect(r.ops.value("outcome.get") >= 1)
    }

    @Test func aPendingRecordStaysCheckingAtAnyAgeAndIsNeverReReviewed() async throws {
        let r = try await rig()
        await r.w.host.demoHoldNextWrite()
        #expect(try await answer(r) == .checking)
        r.w.clock.advance(milliseconds: 1_300_000); r.p.clock.advance(milliseconds: 1_300_000)
        #expect(try await settleAll(r, r.p) == [.checking])
        #expect(try await reviewState(r.p) == ["active"])
        #expect(try await attemptStates(r.p) == ["sent"])
        #expect(r.hooks.count("pe.sign") == 1)
        // the host recovers the admitted submission only after the window: it never runs (spec 14.4), and that is definite
        await r.w.host.demoRecoverWrites()
        #expect(try await settleAll(r, r.p) == [.needsReview(.changed(code: "event.expired"))])
        #expect(await r.w.host.loggedCount() == 0)
    }

    @Test func aHeldWriteRecoveredInTheWindowLands() async throws {
        let r = try await rig()
        await r.w.host.demoHoldNextWrite()
        #expect(try await answer(r) == .checking)
        await r.w.host.demoRecoverWrites()
        let out = try await settleAll(r, r.p)
        guard case .landed = out.first else { Issue.record("\(out)"); return }
        #expect(await r.w.host.loggedCount() == 1)
    }

    @Test func aReSealInTheWindowGetsTheStoredOutcome() async throws {
        let failed = Done()
        let r = try await rig { req, host in
            let op = req.meta.object?["op"]?.string
            if op == "answer", !failed.value {
                failed.set()
                _ = await host.handleView(req)                     // it ran
                return .refuse(.alreadyDone(status: "unknown"))    // but the phone hears "unknown"
            }
            if op == "outcome.get" { return .refuse(.malformed) }  // and cannot read the outcome
            return nil
        }
        let out = try await answer(r)
        guard case .landed = out else { Issue.record("\(out)"); return }
        #expect(r.ops.value("answer") == 2)
        #expect(await r.w.host.loggedCount() == 1)
        #expect(try await rows(r.p, "SELECT * FROM pe_attempts").count == 1)
    }

    // MARK: C-auto

    @Test func membersStaleIsReSignedAutomatically() async throws {
        let r = try await rig()
        await r.w.host.demoBumpMembersV()
        let out = try await answer(r)
        guard case .landedAfterResign = out else { Issue.record("\(out)"); return }
        #expect(try await attemptStates(r.p) == ["superseded", "landed"])
        #expect(try await rows(r.p, "SELECT origin FROM pe_attempts ORDER BY n").compactMap { $0.text("origin") } == ["tap", "auto"])
        #expect(r.hooks.count("pe.sign") == 2)
    }

    @Test func atMostThreeAutomaticReSigns() async throws {
        let r = try await rig { req, host in
            if req.meta.object?["op"] == "answer" { await host.demoBumpMembersV() }
            return nil
        }
        #expect(try await answer(r) == .needsReview(.workspaceChanged))
        #expect(r.hooks.count("pe.sign") == 4 && r.ops.value("answer") == 4)
    }

    @Test func aChangedUnselectedCostBlocksTheAutomaticReSign() async throws {
        let r = try await rig()
        await r.w.host.demoBumpMembersV()
        await r.w.host.changeCost(question: r.snapshot.reviewed.question.id, key: "reject", cost: "$5")
        #expect(try await answer(r) == .needsReview(.workspaceChanged))
        #expect(r.hooks.count("pe.sign") == 1)
    }

    @Test(arguments: ["inactive", "protectedData", "locked", "invalidate"])
    func lifecycleEventsEndTheEligibility(_ event: String) async throws {
        let box = SessionBox()
        let r = try await rig { req, host in
            if req.meta.object?["op"] == "answer", let s = box.session {
                switch event {
                case "inactive": s.noteInactive()
                case "protectedData": s.noteProtectedDataUnavailable()
                case "locked": s.noteCustodyLocked()
                default: await s.invalidateReviews()
                }
                await host.demoBumpMembersV()
            }
            return nil
        }
        box.session = r.p.session
        #expect(try await answer(r) == .needsReview(.workspaceChanged))
        #expect(r.hooks.count("pe.sign") == 1)
    }

    /// A realm reset (generation invalidated) while the tap is answered C-auto: no automatic re-sign.
    @Test func aRealmResetEndsTheEligibility() async throws {
        let env = SessionBox()
        let r = try await rig { req, host in
            if req.meta.object?["op"] == "answer" { await host.demoBumpMembersV(); env.invalidate?() }
            return nil
        }
        let generation = r.w.env.generation
        env.invalidate = { generation.invalidate() }
        _ = try? await answer(r)
        #expect(r.hooks.count("pe.sign") == 1 && r.ops.value("answer") == 1)
        #expect(r.p.session.lifecycleFence.ticket() == nil)
    }

    /// C-auto while an earlier attempt of the review is still unresolved (its outcome cannot be read): no further re-sign, and (MUST-1)
    /// no final "workspace changed" either while that attempt may still land: the review stays checking.
    @Test func noAutoReSignWhileAnEarlierAttemptIsUnresolved() async throws {
        let box = SessionBox()
        let first = RequestBox()
        let r = try await rig { req, host in
            let op = req.meta.object?["op"]?.string
            if op == "outcome.get" { return .refuse(.malformed) }
            guard op == "answer" else { return nil }
            if first.request == nil { first.request = req }
            else if let p = box.container, let k1 = first.request?.meta.object?["idem"]?.string {
                // K1 is possibly sent and unsettled while K2 is refused C-auto again
                try? await p.database().execute("UPDATE pe_attempts SET state='sent' WHERE idem=?", [.text(k1)])
            }
            await host.demoBumpMembersV()
            return nil
        }
        box.container = r.p.container
        #expect(try await answer(r) == .checking)
        #expect(try await reviewState(r.p) == ["active"])
        #expect(r.hooks.count("pe.sign") == 2 && r.ops.value("answer") == 2)
    }

    @Test func aRelaunchEndsTheEligibility() async throws {
        let r = try await rig()
        await r.w.host.demoBumpMembersV()
        r.hooks.fail("post.precharge")
        #expect(try await answer(r) == .checking)
        let p2 = try await relaunch(r)
        // the tap attempt is still sent (same bytes), refused members.stale; no automatic re-sign after a relaunch
        #expect(try await settleAll(r, p2) == [.needsReview(.workspaceChanged)])
        #expect(r.hooks.count("pe.sign") == 1 && r.ops.value("answer") == 1)
    }

    // MARK: adversarial lifecycle

    @Test func aDoubleTapSignsOnce() async throws {
        let r = try await rig()
        let api = r.api, s = r.snapshot
        let results = try await r.w.serve(r.p, steps: 400) { () -> [Bool] in
            async let a = try? api.answer(s, option: "approve")
            async let b = try? api.answer(s, option: "approve")
            return [await a != nil, await b != nil]
        }
        #expect(results.filter { $0 }.count == 1)
        #expect(r.hooks.count("pe.sign") == 1)
        #expect(try await rows(r.p, "SELECT * FROM pe_attempts").count == 1)
    }

    @Test func concurrentSettlesShareOneDriver() async throws {
        let r = try await rig()
        await r.w.host.demoHoldNextWrite()
        #expect(try await answer(r) == .checking)
        let posted = r.ops.value("answer"), drivers = r.hooks.count("pe.driver")
        let id = try #require(try await r.api.pendingWrites().first?.reviewID)
        let session = r.p.session
        let both = try await r.w.serve(r.p, steps: 400) { () -> [WriteOutcome] in
            async let a = session.settle(reviewID: id)
            async let b = session.settle(reviewID: id)
            return [try await a, try await b]
        }
        #expect(both[0] == both[1])
        #expect(r.hooks.count("pe.driver") - drivers == 1)   // one driver started; the second settle joined it
        #expect(r.ops.value("answer") - posted == 2)          // exactly that driver's two re-seals, not four
    }

    /// K1 is refused C-auto (the host misreports it), the review re-signs K2, and then K1 is delivered late and lands. `delayK2`: K2 is
    /// still unresolved when K1 lands (the `earlier` branch of settlement); otherwise K2 is refused `question.answered` by K1's landing.
    /// Either way the review is landed WITH K1, and K2's refusal does not override it.
    @Test(arguments: [false, true])
    func anEarlierAttemptLandingAfterTheReSignWins(_ delayK2: Bool) async throws {
        let stash = RequestBox()
        let r = try await rig { req, host in
            guard req.meta.object?["op"] == "answer" else { return nil }
            guard let k1 = stash.request else {
                stash.request = req
                return .refuse(.host(code: "members.stale", retryable: false, seqs: nil, nextKey: nil))
            }
            if !stash.delivered { stash.delivered = true; _ = await host.handleView(k1) }          // K1, late
            return delayK2 ? .refuse(.alreadyDone(status: "unknown")) : nil
        }
        let out = try await answer(r)
        let k1 = try #require(stash.request?.meta.object?["idem"]?.string)
        if delayK2 {
            #expect(out == .checking)
            // K1 is superseded (refused C-auto, re-signed as K2) but was dispatched: settlement reads it again and finds it landed
            #expect(try await rows(r.p, "SELECT state, dispatched FROM pe_attempts WHERE idem=?", [.text(k1)]).first?.text("state") == "superseded")
            let settled = try await settleAll(r, r.p)
            guard case .landed = settled.first else { Issue.record("\(settled)"); return }
        } else {
            // landed by the log read of `question.answered`: its seq is the log's, never a made-up 0
            guard case .landed(let seq, _) = out else { Issue.record("\(out)"); return }
            #expect(seq >= 1)
        }
        #expect(try await rows(r.p, "SELECT landed_idem FROM pe_reviews").first?.text("landed_idem") == k1)
        #expect(try await rows(r.p, "SELECT state FROM pe_attempts WHERE idem=?", [.text(k1)]).first?.text("state") == "landed")
        #expect(r.hooks.count("pe.sign") == 2)
        #expect(await r.w.host.loggedCount() == 1)
    }

    /// MUST-1: K1 is refused C-auto (misreported), re-signed as K2, and delivered late. K2 is refused (`question.answered`, or
    /// `question.stale`) while K1's `outcome.get` fails once (and, for `answered`, the read of who answered fails once too). That
    /// transient read never finalizes the refusal: the review stays checking, and settles landed WITH K1.
    @Test(arguments: ["answered", "stale"])
    func aTransientReadNeverRefusesWhileAnEarlierAttemptMayLand(_ variant: String) async throws {
        let stash = RequestBox()
        let outcomeFailed = Done(), ticketFailed = Done()
        let r = try await rig { req, host in
            let op = req.meta.object?["op"]?.string
            if op == "outcome.get", stash.delivered, !outcomeFailed.value { outcomeFailed.set(); return .refuse(.malformed) }
            if op == "ticket.get", variant == "answered", stash.delivered, !ticketFailed.value { ticketFailed.set(); return .refuse(.malformed) }
            guard op == "answer" else { return nil }
            guard let k1 = stash.request else {
                stash.request = req
                return .refuse(.host(code: "members.stale", retryable: false, seqs: nil, nextKey: nil))
            }
            if !stash.delivered { stash.delivered = true; _ = await host.handleView(k1) }          // K1, late: it lands at the host
            if variant == "stale" { return .refuse(.host(code: "question.stale", retryable: false, seqs: nil, nextKey: nil)) }
            return nil                                                                            // K2: refused question.answered
        }
        let out = try await answer(r)
        #expect(out == .checking)
        #expect(outcomeFailed.value)
        #expect(try await reviewState(r.p) == ["active"])
        let k1 = try #require(stash.request?.meta.object?["idem"]?.string)
        let settled = try await settleAll(r, r.p)
        guard case .landed = settled.first else { Issue.record("\(settled)"); return }
        #expect(try await rows(r.p, "SELECT landed_idem FROM pe_reviews").first?.text("landed_idem") == k1)
        #expect(try await rows(r.p, "SELECT state FROM pe_attempts WHERE idem=?", [.text(k1)]).first?.text("state") == "landed")
        #expect(try await reviewState(r.p) == ["landed"])
        #expect(await r.w.host.loggedCount() == 1)
    }

    /// MUST-1: `question.answered` whose answerer cannot be read (a transient failure) is not final: the review stays checking and
    /// settles with who answered once the read succeeds.
    @Test func anUnreadableAnswererKeepsTheReviewChecking() async throws {
        let answered = Done(), failed = Done()
        let r = try await rig { req, host in
            let op = req.meta.object?["op"]?.string
            if op == "answer" { answered.set(); return nil }
            if op == "ticket.get", answered.value, !failed.value { failed.set(); return .refuse(.malformed) }
            return nil
        }
        try await r.w.host.demoAnswerOnHost(question: r.snapshot.question.questionID, optionID: "reject", byLabel: "Lena's Mac")
        #expect(try await answer(r) == .checking)
        #expect(failed.value)
        #expect(try await reviewState(r.p) == ["active"])
        let out = try await settleAll(r, r.p)
        guard case .alreadyAnswered(let label, _) = out.first else { Issue.record("\(out)"); return }
        #expect(label == "Lena's Mac")
        #expect(try await reviewState(r.p) == ["refused"])
    }

    /// The last-moment check: the app goes to the background while `prepare` is suspended (key recovery, offset, database): no signature.
    @Test func backgroundDuringPreparationSignsNothing() async throws {
        let r = try await rig()
        let session = r.p.session
        await session.setBeforeWriteTransaction { await session.setForeground(false) }
        await #expect(throws: ViewError.invalidReview) { _ = try await answer(r) }
        #expect(r.hooks.count("pe.sign") == 0)
        #expect(try await rows(r.p, "SELECT * FROM pe_attempts").isEmpty)
        #expect(r.ops.value("answer") == 0)
    }

    // MARK: the lifecycle invariant (LifecycleFence): an invalidation in any await window stops the signature or the first dispatch

    /// Runs `act` synchronously from inside the session's hook point `point`, on its `nth` hit (the invalidation lands exactly in the
    /// window that point sits in).
    func trip(_ r: Rig, at point: String, nth: Int = 1, _ act: @escaping @Sendable (WorkspaceSession) -> Void) async {
        let hooks = r.hooks, session = r.p.session
        await session.setCrashHook { name in
            try hooks.hit(name)
            if name == point, hooks.count(name) == nth { act(session) }
        }
    }

    static let invalidations: [String] = ["inactive", "protectedData", "locked"]
    static func invalidate(_ s: WorkspaceSession, _ how: String) {
        switch how {
        case "inactive": s.noteInactive()
        case "protectedData": s.noteProtectedDataUnavailable()
        default: s.noteCustodyLocked()
        }
    }

    /// The database hop of the signing transaction (the body runs off the session actor, after `prepare`'s suspensions): a tap signs nothing.
    @Test(arguments: invalidations)
    func aTapInvalidatedBeforeTheSignatureSignsNothing(_ how: String) async throws {
        let r = try await rig()
        await trip(r, at: "pe.presign") { Self.invalidate($0, how) }
        do { _ = try await answer(r); Issue.record("signed") }
        catch {
            // a lock is surfaced as the lock it is; any other invalidation as an expired review
            if how == "locked" { #expect(error as? CustodyError == .locked) } else { #expect(error as? ViewError == .invalidReview) }
        }
        #expect(r.hooks.count("pe.sign") == 0)
        #expect(try await rows(r.p, "SELECT * FROM pe_attempts").isEmpty)
        #expect(r.ops.value("answer") == 0)
    }

    /// The charge transaction: the fence is checked inside it, right before `dispatched=1`. A tap stopped there rolls the charge back,
    /// stays dispatched=0 and is discarded ("not sent"); nothing is sent later.
    @Test func aTapInvalidatedInTheChargeTransactionIsDiscarded() async throws {
        let r = try await rig()
        await trip(r, at: "post.charging") { $0.noteInactive() }
        #expect(try await answer(r) == .needsReview(.notSent))
        #expect(r.ops.value("answer") == 0)
        let a = try #require(try await rows(r.p, "SELECT dispatched, state FROM pe_attempts").first)
        #expect(a.int("dispatched") == 0 && a.text("state") == "discarded")
        #expect(try await reviewState(r.p) == ["needs_review"])
        #expect(try await rows(r.p, "SELECT * FROM bridge_requests").isEmpty)
        #expect(try await settleAll(r, r.p).isEmpty)
        #expect(r.hooks.count("pe.sign") == 1 && r.ops.value("answer") == 0)
    }

    /// #84 SHOULD-B, one rule: a tap whose lifecycle ENDED between its Sign tap and its first charge is never sent, even when the app is
    /// already usable again by the time the gate runs (the actor hop won the race): `notSent`, discarded, nothing sent later.
    @Test func aTapWhoseLifecycleEndedIsNotSentWhenTheAppIsBackBeforeTheGate() async throws {
        let r = try await rig()
        await trip(r, at: "pe.signed") { s in s.noteInactive(); s.lifecycleFence.foregrounded() }
        #expect(try await answer(r) == .needsReview(.notSent))
        #expect(r.ops.value("answer") == 0)
        let a = try #require(try await rows(r.p, "SELECT dispatched, state FROM pe_attempts").first)
        #expect(a.int("dispatched") == 0 && a.text("state") == "discarded")
        #expect(try await settleAll(r, r.p).isEmpty)
        #expect(r.ops.value("answer") == 0)
    }

    /// The `ensureCurrent` after the charge: the accepted crash-after-charge window. The attempt stays dispatched (conservative) and is
    /// settled later.
    @Test func aTapInvalidatedAfterTheChargeIsSettledLater() async throws {
        let r = try await rig()
        await trip(r, at: "post.charged") { $0.noteInactive() }
        do { _ = try await answer(r); Issue.record("sent") }
        catch let e as AnswerCommitted { #expect(e.underlying as? WriteGateError == .lifecycleEnded) }
        #expect(r.ops.value("answer") == 0)
        let a = try #require(try await rows(r.p, "SELECT dispatched, state FROM pe_attempts").first)
        #expect(a.int("dispatched") == 1 && a.text("state") == "sent")
        let out = try await settleAll(r, r.p)
        guard case .landed = out.first else { Issue.record("\(out)"); return }
        #expect(r.hooks.count("pe.sign") == 1 && r.ops.value("answer") == 1)
    }

    /// SHOULD-3: a realm generation that ends on the database hop before a TAP's signature: nothing is signed, stored or sent.
    @Test func aGenerationEndBeforeTheTapSignatureSignsNothing() async throws {
        let r = try await rig()
        let generation = r.w.env.generation
        await trip(r, at: "pe.presign") { _ in generation.invalidate() }
        do { _ = try await answer(r); Issue.record("signed") } catch {}
        #expect(r.hooks.count("pe.sign") == 0)
        #expect(try await rows(r.p, "SELECT * FROM pe_attempts").isEmpty)
        #expect(r.ops.value("answer") == 0)
    }

    /// The automatic re-sign: an invalidation on the database hop before its signature means no second signature.
    @Test(arguments: invalidations)
    func anAutoReSignInvalidatedBeforeTheSignatureSignsNothing(_ how: String) async throws {
        let r = try await rig()
        await r.w.host.demoBumpMembersV()
        await trip(r, at: "pe.presign", nth: 2) { Self.invalidate($0, how) }
        #expect(try await answer(r) == .needsReview(.workspaceChanged))
        #expect(r.hooks.count("pe.sign") == 1)
        #expect(try await attemptStates(r.p) == ["c_auto"])
        #expect(r.ops.value("answer") == 1)
    }

    /// The automatic attempt's first dispatch: an invalidation in the charge transaction or `ensureCurrent` stops it before `bridgePost`.
    /// Then it is settled: stopped in the charge transaction it was never sent (discarded, "not sent", nothing pending); stopped after
    /// the charge it is dispatched and settles by reading and re-sealing the same bytes (landed).
    @Test(arguments: ["post.charging", "post.charged"])
    func anAutoAttemptInvalidatedBeforeItsFirstDispatchIsNotSentAndSettles(_ point: String) async throws {
        let r = try await rig()
        await r.w.host.demoBumpMembersV()
        await trip(r, at: point, nth: 2) { $0.noteInactive() }
        let review: String
        if point == "post.charging" {
            #expect(try await answer(r) == .needsReview(.notSent))
            let auto = try #require(try await rows(r.p, "SELECT dispatched, state FROM pe_attempts WHERE origin='auto'").first)
            #expect(auto.int("dispatched") == 0 && auto.text("state") == "discarded")
            review = try #require(try await rows(r.p, "SELECT review FROM pe_reviews").first?.text("review"))
        } else {
            do { _ = try await answer(r); Issue.record("sent") }
            catch let e as AnswerCommitted { #expect(e.underlying as? WriteGateError == .lifecycleEnded) }
            let auto = try #require(try await rows(r.p, "SELECT dispatched, state FROM pe_attempts WHERE origin='auto'").first)
            #expect(auto.int("dispatched") == 1 && auto.text("state") == "sent")
            review = try #require(try await rows(r.p, "SELECT review FROM pe_reviews").first?.text("review"))
        }
        #expect(r.hooks.count("pe.sign") == 2)
        #expect(r.ops.value("answer") == 1)                     // the tap's only
        let settled = try await settleAll(r, r.p)
        if point == "post.charging" {
            #expect(settled.isEmpty)
            #expect(try await r.p.session.writeOutcome(reviewID: review) == .needsReview(.notSent))
            #expect(r.ops.value("answer") == 1)
        } else {
            guard case .landedAfterResign = settled.first else { Issue.record("\(settled)"); return }
            #expect(try await attemptStates(r.p) == ["superseded", "landed"])
        }
        #expect(r.hooks.count("pe.sign") == 2)
    }

    /// A custody lock reported before the tap is surfaced as `CustodyError.locked` ("Unlock to continue"), signs nothing, and a new
    /// review is the way back.
    @Test func aLockIsSurfacedAndANewReviewIsTheWayBack() async throws {
        let r = try await rig()
        r.p.session.noteCustodyLocked()
        await #expect(throws: CustodyError.locked) { _ = try await answer(r) }
        #expect(r.hooks.count("pe.sign") == 0)
        let fresh = try await r.w.serve(r.p) { try await r.api.review(questionID: r.snapshot.question.questionID) }
        let s = try #require(fresh.snapshot)
        let api = r.api
        let out = try await r.w.serve(r.p, steps: 400) { try await api.answer(s, option: "approve") }
        guard case .landed = out else { Issue.record("\(out)"); return }
        #expect(r.hooks.count("pe.sign") == 1)
    }

    /// SH1: a lock inside the automatic re-sign (the signer refuses) ends the eligibility in the session itself; a later foreground
    /// never re-signs.
    @Test func aLockInsideTheAutoReSignEndsTheEligibility() async throws {
        let r = try await rig()
        await r.w.host.demoBumpMembersV()
        let hooks = r.hooks
        await r.p.session.setCrashHook { name in
            try hooks.hit(name)
            if name == "pe.sign", hooks.count(name) == 2 { throw CustodyError.locked }
        }
        #expect(try await answer(r) == .needsReview(.workspaceChanged))
        let review = try #require(try await rows(r.p, "SELECT review FROM pe_reviews").first?.text("review"))
        #expect(!r.p.session.lifecycleFence.hasEligibility(review: review))
        #expect(r.p.session.lifecycleFence.ticket() == nil)       // locked until the foreground (or a new review) returns
        await r.p.session.setForeground(false)
        await r.p.session.setForeground(true)
        _ = try await r.w.serve(r.p) { try await r.p.session.settle(reviewID: review) }
        #expect(try await rows(r.p, "SELECT * FROM pe_attempts").count == 1)
        #expect(hooks.count("pe.signed") == 1)
    }

    @Test func alreadyAnsweredAtTheMacNamesWhoAnswered() async throws {
        let r = try await rig()
        try await r.w.host.demoAnswerOnHost(question: r.snapshot.question.questionID, optionID: "reject", byLabel: "Lena's Mac")
        let out = try await answer(r)
        guard case .alreadyAnswered(let label, _) = out else { Issue.record("\(out)"); return }
        #expect(label == "Lena's Mac")
        #expect(try await reviewState(r.p) == ["refused"])
    }

    @Test func aChangedQuestionNeedsANewReview() async throws {
        let r = try await rig()
        try await r.w.host.replaceQuestionText(r.snapshot.question.questionID, text: "Ship it now?")
        #expect(try await answer(r) == .needsReview(.changed(code: "question.stale")))
    }

    // MARK: settlement

    @Test(arguments: [true, false])
    func unknownIdemAfterTheBoundIsSettledByTheLog(_ landed: Bool) async throws {
        let r = try await rig { req, host in
            guard req.meta.object?["op"] == "answer" else { return nil }
            if landed { _ = await host.handleView(req); await host.dropOutcomeRecords() }
            return .refuse(.alreadyDone(status: "unknown"))
        }
        #expect(try await answer(r) == .checking)                 // before the bound: pending, unresolved
        r.w.clock.advance(milliseconds: 1_250_000); r.p.clock.advance(milliseconds: 1_250_000)
        let out = try await settleAll(r, r.p)
        if landed {
            guard case .landed = out.first else { Issue.record("\(out)"); return }
            #expect(try await rows(r.p, "SELECT evidence FROM pe_attempts").first?.text("evidence")?.contains("\"log\"") == true)
        } else {
            #expect(out == [.needsReview(.changed(code: "outcome.unknown_idem"))])
        }
    }

    @Test(arguments: [true, false])
    func idemExpiredIsSettledByTheLog(_ landed: Bool) async throws {
        let r = try await rig { req, host in
            let op = req.meta.object?["op"]?.string
            if op == "answer" {
                if landed { _ = await host.handleView(req) }
                return .refuse(.alreadyDone(status: "unknown"))
            }
            if op == "outcome.get" { return .refuse(.host(code: "idem.expired", retryable: true, seqs: nil, nextKey: nil)) }
            return nil
        }
        let out = try await answer(r)
        if landed { guard case .landed = out else { Issue.record("\(out)"); return } }
        else { #expect(out == .needsReview(.changed(code: "idem.expired"))) }
    }

    @Test func aMalformedOutcomeStaysUnresolved() async throws {
        let r = try await rig { req, host in
            let op = req.meta.object?["op"]?.string
            if op == "answer" { return .refuse(.alreadyDone(status: "unknown")) }
            if op == "outcome.get" {
                return .r2(try! canonicalJSON(["data": ["state": "committed", "exit": 0, "result": ["data": ["log": "x", "seqs": [0]], "exit": 0]], "exit": 0]))
            }
            return nil
        }
        #expect(try await answer(r) == .checking)
        #expect(try await reviewState(r.p) == ["active"])
    }
}

final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var s: WorkspaceSession?
    private var c: WorkspaceContainer?
    private var i: (@Sendable () -> Void)?
    var session: WorkspaceSession? {
        get { lock.withLock { s } }
        set { lock.withLock { s = newValue } }
    }
    var container: WorkspaceContainer? {
        get { lock.withLock { c } }
        set { lock.withLock { c = newValue } }
    }
    var invalidate: (@Sendable () -> Void)? {
        get { lock.withLock { i } }
        set { lock.withLock { i = newValue } }
    }
}

enum AttemptSeq {
    /// The landed seq an attempt's evidence names (nil without one).
    static func of(_ row: SQLRow) -> Int64? {
        guard let e = row.text("evidence"), let a = (try? StrictJSON.parse(Data(e.utf8)))?.array else { return nil }
        return a.reversed().compactMap { $0.object?["seqs"]?.array?.first?.int }.first
    }
}

final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var r: HostRequest?
    private var d = false
    var request: HostRequest? { get { lock.withLock { r } } set { lock.withLock { r = newValue } } }
    var delivered: Bool { get { lock.withLock { d } } set { lock.withLock { d = newValue } } }
}
