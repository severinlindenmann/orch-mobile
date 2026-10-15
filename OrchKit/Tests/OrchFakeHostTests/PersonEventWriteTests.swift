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

    func rows(_ p: Phone, _ sql: String) async throws -> [SQLRow] { try await p.container.database().query(sql) }

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
        await #expect(throws: (any Error).self) { try await r.p.container.database().execute("UPDATE pe_reviews SET state='needs_review'") }
    }

    @Test func freeTextIsAnsweredOnTheMac() async throws {
        let w = try await World.make()
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        _ = try await w.host.demoAskQuestion(DemoQuestionSeed(ticket: "MOB-0001", text: "Anything else?", options: [], createdAgoMs: 1000))
        let snap = try await w.serve(p) { try await api.snapshot() }
        // not listed, counted as "needs your Mac"
        #expect(snap.macOnlyCount == 1 && !snap.questions.contains { $0.text == "Anything else?" })
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
        await #expect(throws: (any Error).self) { try await r.p.container.database().execute("UPDATE pe_attempts SET dispatched=0") }
    }

    @Test func aCrashWhileTerminalEvidenceIsPersistedLosesNothing() async throws {
        let r = try await rig()
        r.hooks.fail("pe.evidence")
        await #expect(throws: Hooks.Crash.self) { _ = try await answer(r) }
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
        // a backward wall jump cannot extend it: the monotonic age still counts
        #expect(!holds(wall: signedAt - 3_600_000, mono: 841_000))
        // nor can an offset adopted later that shrinks the host age: the wall age since signing counts
        #expect(!holds(wall: signedAt + 841_000, offset: -600_000))
        // a forward wall jump ends it at once
        #expect(!holds(wall: signedAt + 7_200_000, mono: 1_000))
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
                case "inactive": await s.noteInactive()
                case "protectedData": await s.noteProtectedDataUnavailable()
                case "locked": await s.noteCustodyLocked()
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
        let posted = r.ops.value("answer")
        let id = try #require(try await r.api.pendingWrites().first?.reviewID)
        let session = r.p.session
        let both = try await r.w.serve(r.p, steps: 400) { () -> [WriteOutcome] in
            async let a = session.settle(reviewID: id)
            async let b = session.settle(reviewID: id)
            return [try await a, try await b]
        }
        #expect(both[0] == both[1])
        #expect(r.ops.value("answer") - posted <= 2)       // one driver's re-seals, not two
    }

    @Test func aLaterRefusalNeverOverwritesALanding() async throws {
        let r = try await rig()
        guard case .landed = try await answer(r) else { Issue.record("not landed"); return }
        let db = try await r.p.container.database()
        await #expect(throws: (any Error).self) { try await db.execute("UPDATE pe_attempts SET state='d'") }
        await #expect(throws: (any Error).self) { try await db.execute("UPDATE pe_reviews SET state='refused'") }
        await #expect(throws: (any Error).self) { try await db.execute("DELETE FROM pe_attempts") }
        await #expect(throws: (any Error).self) { try await db.execute("UPDATE pe_attempts SET event=x'00'") }
        await #expect(throws: (any Error).self) { try await db.execute("UPDATE pe_attempts SET evidence='[]'") }
        #expect(try await attemptStates(r.p) == ["landed"])
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
    var session: WorkspaceSession? {
        get { lock.withLock { s } }
        set { lock.withLock { s = newValue } }
    }
}
