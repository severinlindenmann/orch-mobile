import Foundation
import Testing
import OrchProtocol
@testable import OrchClient
@testable import OrchFakeHost

private actor Calls {
    private(set) var ops: [String] = []
    private(set) var times: [Int64] = []
    func add(_ op: String, at ms: Int64 = 0) { ops.append(op); times.append(ms) }
    func count(_ op: String) -> Int { ops.filter { $0 == op }.count }
    func timesOf(_ op: String) -> [Int64] { zip(ops, times).filter { $0.0 == op }.map(\.1) }
}

/// Review round of PR #80: one enforcement point per invariant (the op table in `prepare`, the failure handling in `callRead`), caps and
/// visibility of what the phone cannot show, and the reader-declaration rules.
@Suite struct HostReadsHardeningTests {
    private func world() async throws -> (World, Phone) {
        let w = try await World.make()
        return (w, try await w.makePhone())
    }
    /// A session as Live builds it: every request must be an op of the closed table.
    private func liveStyle(_ p: Phone) async throws -> WorkspaceSession {
        var cfg = p.session.configuration
        cfg.enforcesOpTable = true
        return try await WorkspaceSession(cfg)
    }

    // MARK: M1

    @Test func liveRefusesTheInterimV0WritesBeforeAnythingIsSignedOrSealed() async throws {
        let (w, p) = try await world()
        let live = try await liveStyle(p)
        let api = BridgeWorkspaceAPI(session: live)
        let s = try await w.serve(p) { try await BridgeWorkspaceAPI(session: p.session).snapshot() }
        let review = try await w.serve(p) { try await BridgeWorkspaceAPI(session: p.session).review(questionID: s.questions[0].questionID) }
        let sent = await w.host.coreState().rids.count
        await #expect(throws: ViewError.writesUnavailable) { _ = try await api.decide(review, optionID: "approve") }
        await #expect(throws: ViewError.writesUnavailable) {
            _ = try await api.newTicket(NewTicketSubmission(creationID: .fresh(7), title: "t", body: "user text"))
        }
        // not even a hand-built v0 meta gets through the one choke point: no row, no seq, no decision
        let v0: JSONValue = ["op": "new_ticket", "host_api": 0, "creation_id": .string(ID16.fresh(8).hex), "title": "x", "body": "user text", "epic_key": .null]
        await #expect(throws: R2.MetaError.reqInvalid) { _ = try await w.serve(p) { try await live.exchange(meta: v0) } }
        await #expect(throws: R2.MetaError.forbiddenScope) { _ = try await w.serve(p) { try await live.exchange(meta: ["op": "decision"]) } }
        let decisions = try await p.container.database().query("SELECT * FROM decisions")
        let pending = try await live.pendingRequests()
        #expect(decisions.isEmpty && pending.isEmpty)
        #expect(await w.host.coreState().rids.count == sent)    // nothing new reached the host
    }

    @Test func aClassDRefusalOnADecisionIsTerminalNotUncertain() async throws {
        let (w, p) = try await world()
        let api = BridgeWorkspaceAPI(session: p.session)
        let s = try await w.serve(p) { try await api.snapshot() }
        let review = try await w.serve(p) { try await api.review(questionID: s.questions[0].questionID) }
        await w.host.setHandler { req in
            if req.meta.object?["op"] == "decision" { return .refuse(.host(code: "op.not_allowed", retryable: false, seqs: nil, nextKey: nil)) }
            return await w.host.handleView(req)
        }
        #expect(try await w.serve(p) { try await api.decide(review, optionID: "approve") } == .notApplied)
        #expect(try await api.pendingDecisions().isEmpty)
        await w.host.setHandler { req in
            if req.meta.object?["op"] == "decision" { return .refuse(.forbiddenScope) }
            return await w.host.handleView(req)
        }
        let again = try await w.serve(p) { try await api.review(questionID: s.questions[0].questionID) }
        #expect(try await w.serve(p) { try await api.decide(again, optionID: "approve") } == .notApplied)
    }

    // MARK: M2

    @Test func aPollerRefusalClearsTheCacheAndAnnouncesIt() async throws {
        let (w, p) = try await world()
        let api = BridgeWorkspaceAPI(session: p.session)
        let first = try await w.serve(p) { try await api.snapshot() }
        let stream = await api.events()
        let refusal = HostRefusal.reader(code: "sign.convenience_readers", reason: "no_declaration", required: nil, declared: nil)
        await w.host.setHandler { req in
            if req.meta.object?["op"] == "activity.list" { return .refuse(refusal) }
            return await w.host.handleView(req)
        }
        let saw = try await w.serve(p, steps: 400) { () -> Bool in
            for await e in stream { if e == .readerRefused { return true } }
            return false
        }
        #expect(saw)
        #if DEBUG
        let st = await p.session.identityCacheState()
        #expect(st.indexed == 0 && st.tickets == 0 && st.cursor == nil)
        #endif
        // the cached view is not replayed as current to a new subscriber
        let later = await api.events()
        var it = later.makeAsyncIterator()
        let e1 = await it.next()
        #expect(e1 != .snapshot(first))
        await api.setForeground(false)
    }

    @Test func aRefusalOnAQuestionReadDoesTheSame() async throws {
        let (w, p) = try await world()
        let api = BridgeWorkspaceAPI(session: p.session)
        let s = try await w.serve(p) { try await api.snapshot() }
        let stream = await api.events()
        var it = stream.makeAsyncIterator()
        _ = await it.next()          // the cached snapshot
        _ = await it.next()          // the connection state
        let refusal = HostRefusal.reader(code: "reader.decl_invalid", reason: "kat_mismatch", required: nil, declared: nil)
        await w.host.setHandler { req in
            if req.meta.object?["op"] == "ticket.get" { return .refuse(refusal) }
            return await w.host.handleView(req)
        }
        await #expect(throws: ClientError.host(refusal)) { _ = try await w.serve(p) { try await api.review(questionID: s.questions[0].questionID) } }
        var announced = false
        for _ in 0..<5 { if await it.next() == .readerRefused { announced = true; break } }
        #expect(announced)
        await api.setForeground(false)
    }

    // MARK: SH1, SH2

    @Test func aV0ShapedAnswerIsNotAnAnswerToARead() async throws {
        let (w, p) = try await world()
        await w.host.setHandler { req in
            let r = await w.host.handleView(req)
            guard case .r2(let bytes) = r else { return r }
            return .response(status: 200, headers: [:], data: bytes)          // v0 first-chunk meta {status, headers:{}}
        }
        await #expect(throws: ViewError.malformed) { _ = try await w.serve(p) { try await p.session.needs() } }
    }

    @Test func noReadLeavesAnAttemptRowWhateverTheOutcome() async throws {
        let (w, p) = try await world()
        for refusal in [HostRefusal.alreadyDone(status: "unknown"), .host(code: "validation.event", retryable: false, seqs: nil, nextKey: nil), .busy] {
            await w.host.setHandler { _ in .refuse(refusal) }
            _ = try? await w.serve(p, steps: 60) { try await p.session.needs() }
            let pending = try await p.session.pendingRequests(), uncertain = try await p.session.uncertainRequests()
            #expect(pending.isEmpty && uncertain.isEmpty)
        }
    }

    @Test func busyIsRetriedBoundedlyAndThenSurfaced() async throws {
        let (w, p) = try await world()
        let calls = Calls()
        await w.host.setHandler { _ in await calls.add("x"); return .refuse(.busy) }
        await #expect(throws: ClientError.host(.busy)) { _ = try await w.serve(p, steps: 400) { try await p.session.needs() } }
        #expect(await calls.count("x") == WorkspaceSession.maxBusyRetries + 1)
    }

    // MARK: reader rules (SH3, SH5, nits)

    private func declared(_ w: World) async throws -> (Phone, ReaderDeclaration) {
        let cap = try #require(ReaderKAT.current)
        let p = try await w.makePhone(sendsReaderDigest: true)
        let keys = w.env.device.publicKeys
        let decl = try ReaderDeclaration.make(workspace: w.ws, dkSig: keys.sig, dkKx: keys.kx, who: .person(w.primary.personID), level: cap.level, kat: cap.kat,
                                              bind: .declare, createdMs: w.clock.nowMs, signer: w.env.device.sig)
        try ReaderStore.save(w.vault.scoped(to: .demo), ws: w.ws, ReaderStateRecord(decl: decl, highest: decl.level, build: p.session.configuration.reader.build, acked: true))
        try w.vault.scoped(to: .demo).put(try canonicalJSON(["pk_pub": .string(B64U.encode(await w.primary.publicKey.x963))]), purpose: "device.cert")
        return (p, decl)
    }

    @Test func theDowngradeMarkerAlsoGuardsReaderDeclare() async throws {
        let w = try await World.make()
        let (p, _) = try await declared(w)
        try ReaderStore.save(w.vault.scoped(to: .demo), ws: w.ws, ReaderStateRecord(decl: nil, highest: 9, build: "newer", acked: true))
        await #expect(throws: SessionError.readerDowngrade) { _ = try await w.serve(p) { try await p.session.declareReader(force: true) } }
        #expect(await w.host.coreState().rids.isEmpty)
    }

    @Test func aDeclareAnswerIsAcceptedOnlyForThisDeviceAndLevel() async throws {
        let w = try await World.make()
        let (p, decl) = try await declared(w)
        let good: [String: JSONValue] = ["device": .string("d_" + w.phoneID.hex), "reader": .int(Int64(decl.level)), "level": .int(Int64(decl.level)),
                                         "digest": .string("sha256:" + String(repeating: "ab", count: 32))]
        for bad in [["device": .string("d_" + String(repeating: "0", count: 32))], ["reader": .int(Int64(decl.level) + 1)], ["level": .int(Int64(decl.level) + 1)]] as [[String: JSONValue]] {
            await w.host.setHandler { _ in
                var o = good; for (k, v) in bad { o[k] = v }
                let r: JSONValue = ["data": .object(o), "key": .null, "seq": 0, "cursor": 0, "hints": [], "lines": [], "duplicate": false, "exit": 0, "head": .null]
                return .r2(try! canonicalJSON(r))
            }
            await #expect(throws: ViewError.malformed) { _ = try await w.serve(p) { try await p.session.declareReader(force: true) } }
            #expect(try await p.session.readerState()?.hostDigest == nil)
        }
    }

    @Test func aRepeatedDeclarationUnknownDeclaresOncePerInterval() async throws {
        let w = try await World.make()
        let (p, _) = try await declared(w)
        let calls = Calls()
        let refusal = HostRefusal.reader(code: "sign.convenience_readers", reason: "declaration_unknown", required: nil, declared: nil)
        await w.host.setHandler { req in
            let op = req.meta.object?["op"]?.string ?? ""
            await calls.add(op)
            if op == "reader.declare" { return await w.host.handleView(req) }
            return .refuse(refusal)
        }
        await #expect(throws: ClientError.host(refusal)) { _ = try await w.serve(p) { try await p.session.needs() } }
        await #expect(throws: ClientError.host(refusal)) { _ = try await w.serve(p) { try await p.session.needs() } }
        #expect(await calls.count("reader.declare") == 1)
        // after the interval one more is allowed
        w.clock.advance(milliseconds: 301_000); p.clock.advance(milliseconds: 301_000)
        await #expect(throws: ClientError.host(refusal)) { _ = try await w.serve(p) { try await p.session.needs() } }
        #expect(await calls.count("reader.declare") == 2)
    }

    @Test func readerDeclareIsAReadOnTheWireWithNoIdemAndNoRd() async throws {
        let w = try await World.make()
        let (p, decl) = try await declared(w)
        let calls = Calls()
        let seen = Meta()
        await w.host.setHandler { req in await calls.add(req.meta.object?["op"]?.string ?? ""); await seen.set(req.meta); return await w.host.handleView(req) }
        let r = try await w.serve(p) { try await p.session.callRead("reader.declare", args: ["reader_decl": decl.json]) }
        #expect(ReaderDeclareResult(r.data)?.digest == decl.digest)
        let m = try #require(await seen.value?.object)
        #expect(m["idem"] == nil && m["rd"] == nil && Set(m.keys) == ["op", "args"])
    }

    // MARK: SH3 (Sonnet), SH4, SH5, SH6

    private func manyTickets(_ w: World, count: Int) async throws {
        let questions = (1...count).map { DemoQuestionSeed(ticket: String(format: "BIG-%04d", $0), text: "Question \($0)?",
                                                           options: [DemoOptionSeed("yes", "Yes"), DemoOptionSeed("no", "No")], createdAgoMs: Int64($0) * 1000) }
        let tickets = (1...count).map { DemoTicketSeed(key: String(format: "BIG-%04d", $0), title: "Ticket \($0)", body: "") }
        try await w.host.demoSeedViews(questions: questions, tickets: tickets)
    }

    @Test func questionsThePhoneCannotShowAreCountedNotDropped() async throws {
        let (w, p) = try await world()
        let api = BridgeWorkspaceAPI(session: p.session)
        let before = try await w.serve(p) { try await api.snapshot() }
        #expect(before.macOnlyCount == 0 && before.questions.count == 3)
        let fresh = try await w.makePhone(install: false)            // no cached ticket reads
        let api2 = BridgeWorkspaceAPI(session: fresh.session)
        // one question fails its hash, one is free text (no options)
        await w.host.setHandler(await w.host.tampering("ticket.get") { d in
            var qs = d["questions"]!.array!
            var a = qs[0].object!; a["hash"] = .string("sha256:" + String(repeating: "0", count: 64)); qs[0] = .object(a)
            var b = qs[1].object!; b["options"] = nil; b["qid"] = nil; b["hash"] = nil; qs[1] = .object(b)
            d["questions"] = .array(qs)
        })
        let s = try await w.serve(fresh) { try await api2.snapshot() }
        #expect(s.macOnlyCount >= 1 && s.questions.count < before.questions.count)
        #expect(s.questions.count + s.macOnlyCount >= before.questions.count - 1)
    }

    @Test func ticketGetsAreCappedAndCachedAcrossSnapshots() async throws {
        let (w, p) = try await world()
        try await manyTickets(w, count: 40)
        let calls = Calls()
        await w.host.setHandler { req in await calls.add(req.meta.object?["op"]?.string ?? ""); return await w.host.handleView(req) }
        let api = BridgeWorkspaceAPI(session: p.session)
        let s = try await w.serve(p) { try await api.snapshot() }
        #expect(await calls.count("ticket.get") == WorkspaceSession.maxTicketGets)
        #expect(s.questions.count == WorkspaceSession.maxTicketGets && s.macOnlyCount == 10 && s.tickets.count == 40)
        // nothing moved: the second snapshot reads no ticket again
        _ = try await w.serve(p) { try await api.snapshot() }
        #expect(await calls.count("ticket.get") == WorkspaceSession.maxTicketGets)
    }

    @Test func aTruncatedTicketListSaysSo() async throws {
        let (w, p) = try await world()
        await w.host.setHandler(await w.host.tampering("ticket.query") { $0["total"] = 99 })
        let s = try await w.serve(p) { try await BridgeWorkspaceAPI(session: p.session).snapshot() }
        #expect(s.ticketsIncomplete)
        await w.host.clearHandlerForTest()
        let ok = try await w.serve(p) { try await BridgeWorkspaceAPI(session: p.session).snapshot() }
        #expect(!ok.ticketsIncomplete)
    }

    @Test func theRevisionStaysMonotonicAcrossADroppedCache() async throws {
        let (w, p) = try await world()
        let api = BridgeWorkspaceAPI(session: p.session)
        let a = try await w.serve(p) { try await api.snapshot() }
        let refusal = HostRefusal.reader(code: "sign.convenience_readers", reason: "no_declaration", required: nil, declared: nil)
        await w.host.setHandler { _ in .refuse(refusal) }
        _ = try? await w.serve(p) { try await api.snapshot() }
        await w.host.clearHandlerForTest()
        let b = try await w.serve(p) { try await api.snapshot() }
        #expect(b.revision > a.revision)
    }

    @Test func keysFollowTheSpecThroughEveryView() async throws {
        let (w, p) = try await world()
        #expect(validTicketKey("MOB-0001") && validTicketKey("DEMO-0007") && !validTicketKey("MOB-1") && !validTicketKey("mob-0001") && !validTicketKey("A-0001"))
        #expect(advisoryKeyHint("DEMO-42") && !advisoryKeyHint("demo-42"))
        let s = try await w.serve(p) { try await BridgeWorkspaceAPI(session: p.session).snapshot() }
        #expect(s.tickets.map(\.key).contains("MOB-0001") && s.questions.allSatisfy { $0.ticket == "MOB-0001" } && s.nextKey == "MOB-0002")
        let g = try await w.serve(p) { try await p.session.ticketGet("MOB-0001") }
        #expect(g.key == "MOB-0001")
        // `next_key` of workspace.show is strict; the loose hint is only for the refusal
        await w.host.setHandler(await w.host.tampering("workspace.show") { $0["next_key"] = "MOB-2" })
        await #expect(throws: ViewError.malformed) { _ = try await w.serve(p) { try await p.session.workspaceShow() } }
        #expect(HostRefusal(meta: ["refusal": "ticket.key_not_next", "retryable": false, "next_key": "DEMO-42"]) != nil)
    }

    @Test func pollingBacksOffFifteenThirtySixtyAndResets() async throws {
        let (w, p) = try await world()
        let api = BridgeWorkspaceAPI(session: p.session)
        _ = try await w.serve(p) { try await api.snapshot() }
        let calls = Calls()
        await w.host.setHandler { req in
            let op = req.meta.object?["op"]?.string ?? ""
            await calls.add(op, at: w.clock.nowMs)
            return await w.host.handleView(req)
        }
        let stream = await api.events()
        _ = try await w.serve(p, steps: 900) { () -> Int in
            var polls = 0
            for await e in stream {
                if case .connection(.online) = e { polls += 1 }
                if polls == 6 { return polls }
            }
            return polls
        }
        let feed = await calls.timesOf("activity.list")
        let gaps = zip(feed.dropFirst(), feed).map { $0 - $1 }
        #expect(gaps.prefix(3).allSatisfy { $0 >= 14_500 })
        #expect(gaps.count >= 3 && gaps[1] >= 29_000 && gaps[2] >= 59_000)
        await api.setForeground(false)
    }
}

private actor Meta {
    private(set) var value: JSONValue?
    func set(_ v: JSONValue) { value = v }
}

extension FakeHost {
    func clearHandlerForTest() { handler = nil }
}
