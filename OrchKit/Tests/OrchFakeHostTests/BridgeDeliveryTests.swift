import Foundation
import OrchCustody
import Testing
import OrchProtocol
import OrchStore
@testable import OrchClient
@testable import OrchFakeHost

/// Protocol-v2 section 19 bridge delivery on the phone (PR5): the same-rid rule after 202, 429 and 409 `retry_exhausted`, the
/// unsigned `stale_epoch` hint with its bounded refetch, and terminal host refusals such as `not_visible`. Clocks are injected.
@Suite struct BridgeDeliveryTests {
    // MARK: the refetch limiter (P3-D8)

    @Test func limiterAllowsThreeRefetchesPerMinuteThenBacksOffTwentyFortySixty() {
        var l = EpochRefetchLimiter()
        func t(_ s: Int) -> Duration { .seconds(s) }
        func admit(_ s: Int) -> Bool { l.admit(at: t(s)) }
        // Three per minute.
        #expect([admit(0), admit(1), admit(2)] == [true, true, true])
        #expect(!admit(3) && l.nextAllowed(at: t(3)) == t(22))                  // the fourth waits 20 s after the third
        #expect([admit(21), admit(22)] == [false, true])
        #expect(l.nextAllowed(at: t(23)) == t(62))                              // then 40 s
        #expect([admit(61), admit(62)] == [false, true])
        #expect(l.nextAllowed(at: t(63)) == t(122) && admit(122))               // then 60 s
        #expect(l.nextAllowed(at: t(123)) == t(182) && admit(182))              // and 60 s from then on
        // Two quiet minutes: the full budget again, and again only three.
        #expect([admit(302), admit(303), admit(304), admit(305)] == [true, true, true, false])
        // A refetch that confirmed a newer SIGNED epoch resets it (a relay cannot forge one).
        l.reset()
        #expect(admit(306))
    }

    @Test func limiterRefusalsRecordNothing() {
        var l = EpochRefetchLimiter()
        var results: [Bool] = []
        for s in 0..<3 { results.append(l.admit(at: .seconds(s))) }
        for _ in 0..<50 { results.append(l.admit(at: .seconds(10))) }          // hammering does not push the next slot out
        #expect(results == Array(repeating: true, count: 3) + Array(repeating: false, count: 50))
        #expect(l.nextAllowed(at: .seconds(10)) == .seconds(22))
    }

    // MARK: the FakeRelay's replay store through HTTP (P3-D9, P3-D22)

    @Test func fakeRelayCoalescesRequeuesAtMostEveryTenSecondsEightTimesAndNeverRefreshesTheRid() async throws {
        var lim = RelayLimits(); lim.sessionLifetimeMs = 7_200_000            // the sessions outlive the 900 s rid
        let w = try await World.make(limits: lim)
        let rid = ID16.fresh(0xB1), route = BridgeRoute(workspaceID: w.ws, requestID: rid)
        let env = try w.envelope(rid: rid)
        func post() async throws -> WireReply { try await w.transport.bridgePost(env, route: route, session: w.phoneSession) }
        func record() async -> RelayRidRecord? { await w.relay.ridRecord(workspace: w.ws, device: w.phoneID, rid: rid) }
        let first = w.clock.nowMs
        #expect(try await post().status == 202)
        // A live undelivered copy: an identical resend is coalesced, nothing new is queued.
        #expect(try await post().status == 202)
        #expect(await record()?.copies.count == 1)
        #expect(try await w.relay.pendingRequests(workspace: w.ws, token: w.hostSession.token).count == 1)
        try await acknowledgeAll(w)
        // Delivered: requeued at most once per 10 s, with Retry-After the rest of the interval rounded up.
        w.clock.advance(milliseconds: 8_500)
        let early = try await post()
        #expect(early.status == 429 && early.header("retry-after") == "2" && errorCode(early) == "rate_limited")
        for i in 1...8 {
            w.clock.advance(milliseconds: i == 1 ? 1_500 : 10_000)
            #expect(try await post().status == 202, "requeue \(i)")
            try await acknowledgeAll(w)
        }
        let afterEight = await record()
        #expect(afterEight?.requeues == 8 && afterEight?.copies.count == 9)
        w.clock.advance(milliseconds: 10_000)
        let exhausted = try await post()
        #expect(exhausted.status == 409 && errorCode(exhausted) == "retry_exhausted")
        // No TTL refresh: the record still ends 900 s after the FIRST receipt (its copies ended long before).
        #expect(await record()?.keepUntilMs == first + 900_000)
        // Other bytes for the rid are a conflict while the record lives; at 900 s the rid is new again.
        let other = try w.envelope(rid: rid)
        #expect(errorCode(try await w.transport.bridgePost(other, route: route, session: w.phoneSession)) == "rid_conflict")
        w.clock.advance(milliseconds: first + 900_000 - w.clock.nowMs)
        #expect(try await w.transport.bridgePost(other, route: route, session: w.phoneSession).status == 202)
        let fresh = await record()
        #expect(fresh?.requeues == 0 && fresh?.firstMs == first + 900_000)
    }

    @Test func fakeRelayAnswersAnUnknownOrExpiredRidWith410AndNeverResurrectsAChunk() async throws {
        var lim = RelayLimits(); lim.sessionLifetimeMs = 7_200_000            // the sessions outlive the 900 s rid
        let w = try await World.make(limits: lim)
        let rig = HostRig()
        let rid = ID16.fresh(0xB2), route = BridgeRoute(workspaceID: w.ws, requestID: rid)
        let chunk = try w.sealedResponse(rig: rig, rid: rid, seq: 0, flags: [.last])
        let unknown = try await w.transport.bridgePost(chunk, route: route, session: w.hostSession)
        #expect(unknown.status == 410 && errorCode(unknown) == "expired")
        #expect(try await w.postRequest(rid: rid).status == 202)
        #expect(try await w.transport.bridgePost(chunk, route: route, session: w.hostSession).status == 202)
        w.clock.advance(milliseconds: 60_000)
        // A stored replay of the expired chunk is accepted (202) but brings nothing back.
        #expect(try await w.transport.bridgePost(chunk, route: route, session: w.hostSession).status == 202)
        #expect(try chunkList(try await w.transport.bridgePoll(route: route, after: nil, session: w.phoneSession)).isEmpty)
        w.clock.advance(milliseconds: 840_000)                               // 900 s after the request: the rid is gone
        let gone = try await w.transport.bridgePost(chunk, route: route, session: w.hostSession)
        #expect(gone.status == 410 && errorCode(gone) == "expired")
    }

    @Test func onlyAQuietHintFreeTwoMinutesResetsTheBackoff() {
        var l = EpochRefetchLimiter()
        var got: [Bool] = []
        for t in [0, 1, 2, 22, 62] { got.append(l.admit(at: .seconds(t))) }       // three, then 20 s, then 40 s
        // Refused hints keep arriving (every 100 s): no quiet two minutes, so the backoff is not reset; 60 s apart from now on.
        for t in [122, 222] { got.append(l.admit(at: .seconds(t))) }
        got.append(l.admit(at: .seconds(223)))
        #expect(got == [true, true, true, true, true, true, true, false])
        #expect(l.nextAllowed(at: .seconds(223)) == .seconds(282))
    }

    // MARK: helpers

    /// Runs `body` while only the phone's clock ticks: nobody serves, so nothing answers.
    func tick<T: Sendable>(_ phone: Phone, steps: Int = 200, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let done = Done()
        let task = Task { () -> Result<T, Error> in
            defer { done.set() }
            do { return .success(try await body()) } catch { return .failure(error) }
        }
        for _ in 0..<steps {
            var spins = 0
            while !done.value && phone.clock.sleeperCount == 0 && spins < 10_000 { await Task.yield(); spins += 1 }
            if done.value { break }
            phone.clock.advance(milliseconds: 500)
            await Task.yield()
        }
        return try await task.value.get()
    }

    /// The host took every queued copy (its cursor acknowledges them) and then lost them: nothing undelivered is left.
    func acknowledgeAll(_ w: World) async throws {
        let n = try await w.relay.pendingRequests(workspace: w.ws, token: w.hostSession.token).map(\.arrival).max() ?? 0
        _ = try await w.relay.pendingRequests(workspace: w.ws, after: n, token: w.hostSession.token)
    }

    func setRequeues(_ w: World, rid: ID16, _ n: Int) async throws {
        var r = try #require(await w.relay.ridRecord(workspace: w.ws, device: w.phoneID, rid: rid))
        r.requeues = n
        await w.relay.seedRid(workspace: w.ws, device: w.phoneID, rid: rid, record: r)
    }

    // MARK: the same-rid rule (section 19.6)

    @Test func afterA202WithoutAnAnswerTheSameRidStaysPendingAndAResendCoalesces() async throws {
        let w = try await World.make()
        let phone = try await w.makePhone(timeout: .seconds(3))
        let s = phone.session
        do { _ = try await tick(phone) { try await s.exchange(meta: httpGet) }; Issue.record("expected noResponse") }
        catch let e as SessionError { guard case .noResponse = e else { Issue.record("\(e)"); return } }
        let p = try #require(try await s.pendingRequests().first)
        #expect(try await s.nextSeq() == 2)
        let pendingNow = try await s.pendingRequests()
        #expect(pendingNow.count == 1)
        await #expect(throws: SessionError.noResponse(rid: p.rid)) { _ = try await tick(phone) { try await s.resend(rid: p.rid) } }
        // Same rid, same bytes: the relay coalesced the resend into the undelivered copy; nothing new was minted or queued.
        let record = try #require(await w.relay.ridRecord(workspace: w.ws, device: w.phoneID, rid: p.rid))
        #expect(record.copies.count == 1 && record.requeues == 0)
        #expect(await w.relay.ridRecordCount() == 1)
        #expect(try await s.nextSeq() == 2)
        let pendingAfter = try await s.pendingRequests()
        #expect(pendingAfter.map(\.rid) == [p.rid])
    }

    @Test func after429TheDeviceKeepsPollingTheSameRidAndNeverMintsANewOne() async throws {
        let w = try await World.make()
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .response(status: 200, headers: [:], data: Data("once".utf8)) })
        let phone = try await w.makePhone(timeout: .seconds(3))
        let s = phone.session
        _ = try? await tick(phone) { try await s.exchange(meta: httpGet) }
        let p = try #require(try await s.pendingRequests().first)
        try await acknowledgeAll(w)                                   // the host took the copy, then crashed before answering
        w.clock.advance(milliseconds: 4_000)
        // Inside the ten-second requeue interval: 429 rate_limited with the rest of the interval rounded up.
        do { _ = try await tick(phone) { try await s.resend(rid: p.rid) }; Issue.record("expected 429") }
        catch let e as ClientError {
            #expect(e == .relay(RelayRefusal(status: 429, code: .rateLimited, retryAfter: 6)))
        }
        #expect(try await s.pendingRequests().map(\.rid) == [p.rid])
        let seqNow = try await s.nextSeq()
        #expect(seqNow == 2)
        #expect(await w.relay.ridRecord(workspace: w.ws, device: w.phoneID, rid: p.rid)?.requeues == 0)
        // After the interval the same bytes are requeued once, the host runs the request once and the phone reads the answer.
        w.clock.advance(milliseconds: 6_000)
        let r = try await w.serve(phone) { try await s.resend(rid: p.rid) }
        #expect(r.data == Data("once".utf8) && counter.value == 1)
        #expect(await w.relay.ridRecord(workspace: w.ws, device: w.phoneID, rid: p.rid)?.requeues == 1)
        #expect(await w.relay.ridRecordCount() == 1)
        let seqAfter = try await s.nextSeq()
        #expect(seqAfter == 2)
    }

    @Test func retryExhaustedIsTerminalUncertainAndNothingIsReSentOrReSigned() async throws {
        let w = try await World.make()
        let phone = try await w.makePhone(timeout: .seconds(3))
        let s = phone.session
        _ = try? await tick(phone) { try await s.exchange(meta: httpGet) }
        let p = try #require(try await s.pendingRequests().first)
        try await acknowledgeAll(w)
        try await setRequeues(w, rid: p.rid, 8)
        w.clock.advance(milliseconds: 10_000)
        await #expect(throws: SessionError.retryExhausted(logical: p.logical)) { _ = try await tick(phone) { try await s.resend(rid: p.rid) } }
        #expect(try await s.pendingRequests().isEmpty)
        let u = try await s.uncertainRequests()
        #expect(u.map(\.rid) == [p.rid] && u[0].seq == p.seq)                  // the exact bytes are kept for an explicit retry
        #expect(try await s.nextSeq() == 2)
        let records = await w.relay.ridRecordCount()
        #expect(records == 1)
        // Terminal: a later resend sends nothing at all.
        let before = await w.relay.requestsReceived
        await #expect(throws: SessionError.uncertain(logical: p.logical)) { _ = try await s.resend(rid: p.rid) }
        #expect(await w.relay.requestsReceived == before)
    }

    @Test func retryExhaustedStillReadsAnAnswerTheRelayRetains() async throws {
        let w = try await World.make()
        await w.host.setHandler({ _ in .response(status: 200, headers: [:], data: Data("kept".utf8)) })
        let phone = try await w.makePhone(timeout: .seconds(3))
        let s = phone.session
        _ = try? await tick(phone) { try await s.exchange(meta: httpGet) }
        let p = try #require(try await s.pendingRequests().first)
        #expect(try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) == 1)   // answered, chunk stored
        try await acknowledgeAll(w)
        try await setRequeues(w, rid: p.rid, 8)
        let r = try await tick(phone) { try await s.resend(rid: p.rid) }          // 409 retry_exhausted, then the poll finds the answer
        #expect(r.data == Data("kept".utf8))
        #expect(try await s.pendingRequests().isEmpty)
        let uncertainNow = try await s.uncertainRequests()
        #expect(uncertainNow.isEmpty)
    }

    // MARK: decisions: exhausted is never reissued automatically (U8)

    /// A decision whose delivery the relay ended with 409 `retry_exhausted`: the host forgot the attempt, its answer never reached the
    /// relay and the relay used up all eight requeues. `apply` makes the host apply decisions from then on.
    func exhaustedDecision() async throws -> (w: World, p: Phone, api: BridgeWorkspaceAPI, id: ID16, old: PendingRequestInfo, runs: Counter, apply: Done) {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        let snap = try await w.serve(p) { try await api.snapshot() }
        let review = try await w.serve(p) { try await api.review(questionID: snap.questions[0].questionID) }
        let decisionsRun = Counter()
        let apply = Done()
        await w.host.setHandler { req in
            guard req.meta.object?["op"] == "decision" else { return await w.host.handleView(req) }
            decisionsRun.bump()
            if apply.value { return await w.host.handleView(req) }
            faults.enqueue(.disconnect, at: .pollDelivery)                     // the answer to the first attempt is lost
            return .response(status: 200, headers: ["content-type": "application/json"], data: Data())
        }
        #expect(try await w.serve(p) { try await api.decide(review, optionID: "approve") } == .uncertain)
        let id = try #require(try await api.pendingDecisions().first?.decisionID)
        let old = try #require(try await p.session.pendingRequests().first { $0.logical == id })
        await w.host.forgetOutcome(rid: old.rid)
        await w.relay.forgetResponses(workspace: w.ws, device: w.phoneID, rid: old.rid)
        try await acknowledgeAll(w)
        try await setRequeues(w, rid: old.rid, 8)
        w.clock.advance(milliseconds: 10_000); p.clock.advance(milliseconds: 10_000)
        #expect(try await w.serve(p) { try await api.reconcile(decisionID: id) } == .needsRetry)
        return (w, p, api, id, old, decisionsRun, apply)
    }

    func attempts(_ p: Phone, _ id: ID16) async throws -> [String] {
        try await p.container.database().query("SELECT rid FROM bridge_requests WHERE logical=?", [.text(id.hex)]).compactMap { $0.text("rid") }
    }

    @Test func anExhaustedDecisionWaitsForAnExplicitRetryAndIsAppliedOnce() async throws {
        let (w, p, api, id, old, decisionsRun, apply) = try await exhaustedDecision()
        let db = try await p.container.database()
        #expect(try await db.query("SELECT state FROM decisions WHERE id=?", [.text(id.hex)]).first?.text("state") == "exhausted")
        #expect(try await p.session.isExhausted(id))
        #expect(try await api.pendingDecisions().first?.state == .needsRetry)
        // Automatic reconciliation only reads: the question is still open, so it needs a retry and nothing is reissued.
        #expect(try await w.serve(p) { try await api.reconcile(decisionID: id) } == .needsRetry)
        #expect(try await attempts(p, id) == [old.rid.hex] && decisionsRun.value == 1)
        // The user's explicit retry sends the SAME signed decision under a new rid; the host applies it exactly once.
        apply.set()
        #expect(try await w.serve(p) { try await api.retry(decisionID: id) } == .accepted)
        #expect(decisionsRun.value == 2)
        let stillPending = try await api.pendingDecisions()
        #expect(stillPending.isEmpty)
        #expect(try await !p.session.isExhausted(id))
        let after = try await w.serve(p) { try await api.snapshot() }
        #expect(after.revision == 2 && after.questions.filter { $0.resolution?.decisionID == id }.count == 1)
    }

    /// Security review F1 PoC: a crash between the attempt's `uncertain` and the decision's `exhausted` state used to let automatic
    /// reconciliation reissue it. The marker is now written in the same transaction as the attempt and is what reconciliation reads.
    @Test func pocCrashBetweenMarkUncertainAndExhaustedFlag() async throws {
        let (w, p, api, id, old, decisionsRun, _) = try await exhaustedDecision()
        let db = try await p.container.database()
        // Simulate the old crash window: decisions.state never reached 'exhausted'.
        try await db.execute("UPDATE decisions SET state='uncertain' WHERE id=?", [.text(id.hex)])
        _ = try? await w.serve(p) { try await api.reconcile(decisionID: id) }
        #expect(try await attempts(p, id) == [old.rid.hex], "automatic reissue under a new rid after retry_exhausted")
        #expect(decisionsRun.value == 1)
    }

    @Test func anExhaustedDecisionSurvivesARestartAndRecoveryNeverReissuesIt() async throws {
        let (w, p, _, id, old, decisionsRun, _) = try await exhaustedDecision()
        // App restart: a new session over the same container; foreground recovery reconciles every pending decision.
        let restarted = try await WorkspaceSession(p.session.cfg)
        let status = try await restarted.pendingDecisions()
        #expect(status.map(\.state) == [.needsRetry])
        await restarted.startViews()
        #expect(try await w.serve(p) { try await restarted.reconcileDecision(id) } == .needsRetry)
        for _ in 0..<20 { _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession); await Task.yield() }
        #expect(try await attempts(p, id) == [old.rid.hex])
        #expect(decisionsRun.value == 1)
        #expect(try await restarted.isExhausted(id))
    }

    // MARK: the unsigned stale_epoch hint (P3-D8)

    @Test func theRelaysStaleEpochHintNeverRaisesTheEpochAndItsRefetchIsBounded() async throws {
        let w = try await World.make()
        let phone = try await w.makePhone()
        let s = phone.session
        // The relay claims epoch 5 for new rids; the signed list and the grants still say 1.
        await w.relay.seedMembership(workspace: w.ws, devices: [w.phoneID, w.primaryID], epoch: 5)
        let hint = SessionError.awaitingSignedEpoch(hint: 5)                  // typed: waiting for the signed list
        for _ in 0..<3 {
            let before = await w.relay.requestsReceived
            await #expect(throws: hint) { _ = try await s.exchange(meta: httpGet) }
            #expect(await w.relay.requestsReceived - before == 3)           // the post, then the signed grants and member list
            #expect(try await s.currentEpoch() == 1)
        }
        // The fourth within the minute: no refetch, only the refused post; 20 s to wait.
        let before = await w.relay.requestsReceived
        await #expect(throws: SessionError.epochRefetchDeferred(retryAfterMs: 20_000)) { _ = try await s.exchange(meta: httpGet) }
        #expect(await w.relay.requestsReceived - before == 1)
        phone.clock.advance(by: .seconds(20))
        await #expect(throws: hint) { _ = try await s.exchange(meta: httpGet) }
        #expect(try await s.currentEpoch() == 1)
        // Nothing reached the host, and every refused attempt is still its own pending rid (none was re-sealed).
        #expect(await w.host.coreState().rids.isEmpty)
        let pending = try await s.pendingRequests()
        #expect(pending.count == 5 && Set(pending.map(\.logical)).count == 5 && pending.allSatisfy { $0.epoch == 1 })
        // A RESEND refused by the hint is never re-signed: it becomes uncertain.
        let seq = try await s.nextSeq()
        await #expect(throws: SessionError.uncertain(logical: pending[0].logical)) { _ = try await s.resend(rid: pending[0].rid) }
        #expect(try await s.nextSeq() == seq)
    }

    @Test func aRealRotationSeenThroughTheHintReSealsOnceUnderTheSignedEpoch() async throws {
        let w = try await World.make()
        let counter = Counter()
        await w.host.setHandler({ req in counter.bump(); return .response(status: 200, headers: [:], data: Data("e\(req.epoch)".utf8)) })
        let phone = try await w.makePhone()
        let s = phone.session
        try await w.host.rotate(remaining: [(w.primary.deviceKeys, World.all), (w.phone, ["look", "decide"])], relay: w.relay, session: w.hostSession)
        let r = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        #expect(r.data == Data("e2".utf8) && counter.value == 1)
        #expect(try await s.currentEpoch() == 2)    // seq 1 refused by the relay, seq 2 ran
        let seqNow = try await s.nextSeq()
        #expect(seqNow == 3)
        // Re-sealed under the SAME rid (orch-29 Q14): the relay and the host know exactly one rid, and it is that one.
        let hostRids = Set(await w.host.coreState().rids.keys)
        let relayRids = await w.relay.ridKeys(workspace: w.ws)
        #expect(hostRids.count == 1 && relayRids.isSuperset(of: hostRids))
        // The confirmed rotation reset the limiter.
        #expect(await s.epochHintLimiterState() == EpochRefetchLimiter())
    }

    /// orch-29 Q14: after the unsigned hint the request is re-sealed under the SAME rid. A lying relay that queued the first copy
    /// anyway and let the host run it gets the host's `rid_conflict` for the re-sealed copy: uncertain, and nothing ran twice.
    @Test func aLyingRelaysHintEndsInRidConflictAndTheHandlerRunsOnce() async throws {
        let w = try await World.make()
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .response(status: 200, headers: [:], data: Data("ran".utf8)) })
        let phone = try await w.makePhone()
        let s = phone.session
        let (host, relay, transport, hostSession, primary, phoneKeys) = (w.host, w.relay, w.transport, w.hostSession, w.primary, w.phone)
        await w.relay.lieWithStaleEpochOnNextRequest(epoch: 2) {
            // The liar delivered the epoch-1 request: the host runs it, then rotates, so the signed list really moves to epoch 2.
            _ = try await host.pump(relay: relay, transport: transport, session: hostSession)
            try await host.rotate(remaining: [(primary.deviceKeys, World.all), (phoneKeys, ["look", "decide"])], relay: relay, session: hostSession)
        }
        do { _ = try await w.serve(phone) { try await s.exchange(meta: httpGet) }; Issue.record("expected uncertain") }
        catch let e as SessionError { guard case .uncertain = e else { Issue.record("\(e)"); return } }
        #expect(counter.value == 1)
        // The relay misbehaved: the ORIGINAL attempt (seq 1, epoch 1, its bytes) is what stays, uncertain, so its answer can verify.
        let u = try await s.uncertainRequests()
        #expect(u.count == 1 && u[0].epoch == 1 && u[0].seq == 1)
        let hostRids = await w.host.coreState().rids
        #expect(Set(hostRids.keys) == [u[0].rid])                                // one rid, the same one both times
        #expect(hostRids[u[0].rid]?.outcome != nil)
    }

    /// orch-29 Q14 bound: the same-rid re-seal happens only within 240 s of the first copy. The relay holds its stale_epoch answer
    /// while the host rotates; at 239 s the phone re-seals and the request runs once, at 241 s it reconciles instead.
    @Test(arguments: [(239_000 as Int64, true), (241_000, false)])
    func theSameRidReSealIsBoundedTo240Seconds(heldMs: Int64, reseals: Bool) async throws {
        var lim = RelayLimits(); lim.sessionLifetimeMs = 7_200_000
        let w = try await World.make(limits: lim)
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .response(status: 200, headers: [:], data: Data("ran".utf8)) })
        let phone = try await w.makePhone()
        let s = phone.session
        let (host, relay, hostSession, primary, phoneKeys, clock, pclock) = (w.host, w.relay, w.hostSession, w.primary, w.phone, w.clock, phone.clock)
        await w.relay.lieWithStaleEpochOnNextRequest(epoch: 2, deliver: false) {
            try await host.rotate(remaining: [(primary.deviceKeys, World.all), (phoneKeys, ["look", "decide"])], relay: relay, session: hostSession)
            clock.advance(milliseconds: heldMs); pclock.advance(milliseconds: heldMs)          // the relay held its answer this long
        }
        if reseals {
            let r = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
            #expect(r.data == Data("ran".utf8) && counter.value == 1)
            let seqNow = try await s.nextSeq()
            #expect(seqNow == 3)                                                 // seq 1 refused by the relay, seq 2 re-sealed
            let hostRids = Set(await w.host.coreState().rids.keys)
            #expect(hostRids.count == 1)
        } else {
            do { _ = try await w.serve(phone) { try await s.exchange(meta: httpGet) }; Issue.record("expected uncertain") }
            catch let e as SessionError { guard case .uncertain = e else { Issue.record("\(e)"); return } }
            #expect(counter.value == 0)
            let seqNow = try await s.nextSeq()
            #expect(seqNow == 2)                                                 // nothing re-sealed
            let u = try await s.uncertainRequests()
            #expect(u.count == 1 && u[0].epoch == 1)
        }
    }

    /// A lying relay that delivered the first copy and held its stale_epoch answer past 240 s: no re-seal, so even the host's
    /// `rid_conflict` safety net is not needed; the request ran exactly once and the phone reconciles.
    @Test func aLateHeldHintCannotCauseADoubleExecution() async throws {
        var lim = RelayLimits(); lim.sessionLifetimeMs = 7_200_000
        let w = try await World.make(limits: lim)
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .response(status: 200, headers: [:], data: Data()) })
        let phone = try await w.makePhone()
        let s = phone.session
        let (host, relay, transport, hostSession, primary, phoneKeys, clock, pclock) =
            (w.host, w.relay, w.transport, w.hostSession, w.primary, w.phone, w.clock, phone.clock)
        await w.relay.lieWithStaleEpochOnNextRequest(epoch: 2) {
            _ = try await host.pump(relay: relay, transport: transport, session: hostSession)
            try await host.rotate(remaining: [(primary.deviceKeys, World.all), (phoneKeys, ["look", "decide"])], relay: relay, session: hostSession)
            clock.advance(milliseconds: 241_000); pclock.advance(milliseconds: 241_000)
        }
        do { _ = try await w.serve(phone) { try await s.exchange(meta: httpGet) }; Issue.record("expected uncertain") }
        catch let e as SessionError { guard case .uncertain = e else { Issue.record("\(e)"); return } }
        for _ in 0..<5 { _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }
        #expect(counter.value == 1)
        let seqNow = try await s.nextSeq()
        #expect(seqNow == 2)
    }

    // MARK: terminal host refusals

    /// orch-29 Q2: `not_visible` is sealed, terminal and definite: the decision ends "not applied", never uncertain, never re-sent.
    @Test func aNotVisibleDecisionIsDefinitelyNotApplied() async throws {
        let w = try await World.make()
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        let snap = try await w.serve(p) { try await api.snapshot() }
        let review = try await w.serve(p) { try await api.review(questionID: snap.questions[0].questionID) }
        let runs = Counter()
        await w.host.setHandler { req in
            guard req.meta.object?["op"] == "decision" else { return await w.host.handleView(req) }
            runs.bump(); return .refuse(.notVisible)
        }
        #expect(try await w.serve(p) { try await api.decide(review, optionID: "approve") } == .notApplied)
        let pending = try await api.pendingDecisions()
        #expect(pending.isEmpty && runs.value == 1)
        let left = try await p.container.database().query("SELECT rid FROM bridge_requests")
        #expect(left.isEmpty)
    }

    @Test func notVisibleIsTerminalAndFailsClosed() async throws {
        let w = try await World.make()
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .refuse(.notVisible) })
        let phone = try await w.makePhone()
        let s = phone.session
        await #expect(throws: ClientError.host(.notVisible)) { _ = try await w.serve(phone) { try await s.exchange(meta: httpGet) } }
        #expect(counter.value == 1)
        let seqNow = try await s.nextSeq()
        #expect(seqNow == 2)
        #expect(try await s.pendingRequests().isEmpty)
        let uncertainNow = try await s.uncertainRequests()
        #expect(uncertainNow.isEmpty)
        #expect(await w.host.coreState().rids.count == 1)
    }
}
