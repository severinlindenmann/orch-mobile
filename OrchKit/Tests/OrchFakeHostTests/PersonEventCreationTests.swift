import Foundation
import Testing
import OrchCustody
import OrchProtocol
@testable import OrchStore
@testable import OrchClient
@testable import OrchFakeHost

/// C2b increment 3: creation end to end against the FakeHost (Demo grant, passphrase custody): the review (type, prepared title, a fresh
/// `next_key`, one uid per review), the key disclosure, the key race (C-auto, at most 3 automatic re-signs), the `ticket.exists` retry
/// note with attribution by the review's own uid, crash safety and migration 16.
@Suite struct PersonEventCreationTests {
    struct Rig {
        let w: World
        let p: Phone
        let api: BridgeWorkspaceAPI
        let review: CreationReview
        let hooks: Hooks
        let ops: OpCounter
    }

    func rig(title: String = "Check the tariff seeds", type: String = "feature",
             _ serve: (@Sendable (HostRequest, FakeHost) async -> HostReply?)? = nil) async throws -> Rig {
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
        _ = try await w.serve(p) { try await api.snapshot() }
        let review = try await w.serve(p) { try await api.reviewCreation(type: type, title: title) }
        let hooks = Hooks()
        await p.session.setCrashHook { try hooks.hit($0) }
        return Rig(w: w, p: p, api: api, review: review, hooks: hooks, ops: ops)
    }

    func create(_ r: Rig, disclosed: String?? = .none, steps: Int = 400) async throws -> WriteOutcome {
        let api = r.api, rv = r.review
        let key: String? = disclosed ?? rv.nextKey
        return try await r.w.serve(r.p, steps: steps) { try await api.create(rv, disclosedKey: key) }
    }

    func rows(_ p: Phone, _ sql: String, _ args: [SQLValue] = []) async throws -> [SQLRow] { try await p.container.database().query(sql, args) }
    func attemptStates(_ p: Phone) async throws -> [String] { try await rows(p, "SELECT state FROM pe_attempts ORDER BY n").compactMap { $0.text("state") } }
    func attemptKeys(_ p: Phone) async throws -> [String] { try await rows(p, "SELECT key FROM pe_attempts ORDER BY n").compactMap { $0.text("key") } }
    /// The `log` (uid) every stored attempt was signed under.
    func attemptLogs(_ r: Rig) async throws -> [String] {
        try await rows(r.p, "SELECT event FROM pe_attempts ORDER BY n").compactMap { row in
            guard let b = row.blob("event") else { return nil }
            return try PhoneEvents.restore(bytes: b, kind: .ticketCreated, log: r.review.uid, workspace: r.w.ws).log
        }
    }

    func relaunch(_ r: Rig) async throws -> Phone {
        await r.p.session.setForeground(false)
        let s = try await WorkspaceSession(r.p.session.configuration)
        return Phone(session: s, container: r.p.container, clock: r.p.clock)
    }

    func settleAll(_ r: Rig, _ p: Phone) async throws -> [WriteOutcome] {
        let ids = try await p.session.pendingWrites().map(\.reviewID)
        var out: [WriteOutcome] = []
        for id in ids { out.append(try await r.w.serve(p, steps: 400) { try await p.session.settle(reviewID: id) }) }
        return out
    }

    // MARK: review

    @Test func theReviewPreparesTheTitleAndDisclosesTheAdvertisedNextKey() async throws {
        let r = try await rig(title: "Cafe\u{0301} tariffs")
        #expect(Array(r.review.title.unicodeScalars) == Array("Caf\u{00E9} tariffs".unicodeScalars))   // NFC: what is signed
        #expect(r.review.nextKey == "MOB-0002" && r.review.ticketType == "feature")
        #expect(r.review.disclosure == "The key is assigned when sent (next: MOB-0002)")
        let person = r.w.primary.personID
        #expect(r.review.owner == "p_" + person.hex)
        #expect(ULID.isValid(r.review.uid))
        // a new review has a new uid
        let api = r.api
        let other = try await r.w.serve(r.p) { try await api.reviewCreation(type: "bug", title: "Other") }
        #expect(other.uid != r.review.uid)
    }

    @Test func titleViolationsAndTypesAreRefusedAtReview() async throws {
        let r = try await rig()
        let api = r.api
        do { _ = try await r.w.serve(r.p) { try await api.reviewCreation(type: "feature", title: "two\nlines") }; Issue.record("accepted") }
        catch PhoneEvents.Failure.text(let v) { #expect(v.kind == .lineFeedInOneLine) }
        for title in ["", String(repeating: "a", count: 201)] {
            await #expect(throws: PhoneEvents.Failure.titleLength) { _ = try await r.w.serve(r.p) { try await api.reviewCreation(type: "feature", title: title) } }
        }
        await #expect(throws: PhoneEvents.Failure.badType) { _ = try await r.w.serve(r.p) { try await api.reviewCreation(type: "story", title: "t") } }
        #expect(r.hooks.count("pe.sign") == 0)
    }

    @Test func noNextKeyMeansNoReview() async throws {
        let r = try await rig()
        await r.w.host.setHandler(await r.w.host.tampering("workspace.show") { $0["next_key"] = .null })
        let api = r.api
        await #expect(throws: ViewError.writesUnavailable) { _ = try await r.w.serve(r.p) { try await api.reviewCreation(type: "feature", title: "t") } }
    }

    // MARK: basics

    @Test func aCreationLandsWithItsKeyAndIsConfirmed() async throws {
        let r = try await rig()
        let out = try await create(r)
        #expect(out == .landed(seq: 1, key: "MOB-0002"))
        #expect(r.hooks.count("pe.sign") == 1 && r.ops.value("new_ticket") == 1)
        #expect(try await attemptStates(r.p) == ["landed"])
        #expect(try await attemptKeys(r.p) == ["MOB-0002"])
        let rv = try #require(try await rows(r.p, "SELECT * FROM pe_reviews").first)
        #expect(rv.text("kind") == "new_ticket" && rv.text("log") == r.review.uid && rv.text("key_disclosed") == "MOB-0002" && rv.text("question") == nil)
        #expect(try await rows(r.p, "SELECT rid FROM bridge_requests").isEmpty)
        #expect(try await r.api.pendingWrites().isEmpty)
        let after = try await r.w.serve(r.p) { try await r.api.snapshot() }
        #expect(after.tickets.contains { $0.key == "MOB-0002" && $0.title == "Check the tariff seeds" })
        #expect(after.nextKey == "MOB-0003")
    }

    @Test func aReviewIsSignedOnceAndADisclosureOfAnotherKeyIsRefused() async throws {
        let r = try await rig()
        await #expect(throws: ViewError.invalidReview) { _ = try await create(r, disclosed: .some("MOB-0009")) }
        #expect(r.hooks.count("pe.sign") == 0)
        #expect(try await rows(r.p, "SELECT * FROM pe_reviews").isEmpty)
        // a wrong disclosure does not consume the review; a second create of the same review does
        _ = try await create(r)
        await #expect(throws: ViewError.invalidReview) { _ = try await create(r) }
        #expect(r.hooks.count("pe.sign") == 1)
    }

    @Test(arguments: ["pe.signed", "pe.inserted"])
    func aFailureInsideTheSigningTransactionLeavesNothing(_ point: String) async throws {
        let r = try await rig()
        r.hooks.fail(point)
        await #expect(throws: Hooks.Crash.self) { _ = try await create(r) }
        #expect(r.hooks.count("pe.sign") == 1)
        #expect(try await rows(r.p, "SELECT * FROM pe_attempts").isEmpty)
        #expect(try await rows(r.p, "SELECT * FROM pe_reviews").isEmpty)
        #expect(r.ops.value("new_ticket") == 0)
        #expect(await r.w.host.loggedCount() == 0)
    }

    @Test func aCrashRightAfterCommitSendsTheSameBytesAfterARelaunch() async throws {
        let r = try await rig()
        r.hooks.fail("post.precharge")
        #expect(try await create(r) == .checking)
        let stored = try #require(try await rows(r.p, "SELECT idem, event, dispatched FROM pe_attempts").first)
        #expect(stored.int("dispatched") == 0 && r.ops.value("new_ticket") == 0)
        // the pending creation shows what was reviewed
        let pending = try #require(try await r.api.pendingWrites().first)
        #expect(pending.creation == StoredCreationReview(ticketType: "feature", title: "Check the tariff seeds", owner: r.review.owner,
                                                         uid: r.review.uid, key: "MOB-0002"))
        let p2 = try await relaunch(r)
        #expect(try await settleAll(r, p2) == [.landed(seq: 1, key: "MOB-0002")])
        #expect(r.hooks.count("pe.sign") == 1 && r.ops.value("new_ticket") == 1)
        #expect(await r.w.host.outcomeRecord(device: r.w.phoneID, idem: try #require(stored.text("idem")))?.state == "committed")
        #expect(try await attemptLogs(r) == [r.review.uid])
    }

    @Test func aCrashAfterTheChargeIsSettledAndCreatesOnce() async throws {
        let r = try await rig()
        r.hooks.fail("post.charged")
        #expect(try await create(r) == .landed(seq: 1, key: "MOB-0002"))
        #expect(r.ops.value("outcome.get") >= 1 && r.ops.value("new_ticket") == 1 && r.hooks.count("pe.sign") == 1)
        #expect(await r.w.host.loggedCount() == 1)
    }

    @Test func aLostResponseIsResealedUnderTheSameUidAndCreatesOnce() async throws {
        let failed = Done()
        let r = try await rig { req, host in
            let op = req.meta.object?["op"]?.string
            if op == "new_ticket", !failed.value {
                failed.set()
                _ = await host.handleView(req)                     // it ran
                return .refuse(.alreadyDone(status: "unknown"))    // but the phone hears "unknown"
            }
            if op == "outcome.get" { return .refuse(.malformed) }  // and cannot read the outcome
            return nil
        }
        #expect(try await create(r) == .landed(seq: 1, key: "MOB-0002"))
        #expect(r.ops.value("new_ticket") == 2 && r.hooks.count("pe.sign") == 1)
        #expect(await r.w.host.loggedCount() == 1)
        #expect(try await attemptLogs(r) == [r.review.uid])
    }

    // MARK: the key race (C-auto)

    @Test(arguments: [1, 2, 3])
    func aKeyRaceIsReSignedWithTheAdvertisedNextKeyUnderTheSameUid(_ races: Int) async throws {
        let n = Seq()
        let r = try await rig { req, host in
            if req.meta.object?["op"] == "new_ticket", n.next() <= races { await host.demoTakeNextKey() }
            return nil
        }
        let expected = "MOB-" + String(format: "%04d", 2 + races)
        #expect(try await create(r) == .landedAfterResign(seq: 1, key: expected))
        #expect(r.hooks.count("pe.sign") == races + 1 && r.ops.value("new_ticket") == races + 1)
        #expect(try await attemptKeys(r.p) == (0...races).map { "MOB-" + String(format: "%04d", 2 + $0) })
        #expect(try await attemptStates(r.p) == Array(repeating: "superseded", count: races) + ["landed"])
        // one review = one uid, on every attempt
        #expect(try await attemptLogs(r) == Array(repeating: r.review.uid, count: races + 1))
        #expect(try await rows(r.p, "SELECT resigns FROM pe_reviews").first?.int("resigns") == Int64(races))
        #expect(await r.w.host.loggedCount() == 1)
    }

    @Test func aFourthKeyRaceAsksForANewReview() async throws {
        let r = try await rig { req, host in
            if req.meta.object?["op"] == "new_ticket" { await host.demoTakeNextKey() }
            return nil
        }
        #expect(try await create(r) == .needsReview(.workspaceChanged))
        #expect(r.hooks.count("pe.sign") == 4 && r.ops.value("new_ticket") == 4)
        #expect(await r.w.host.loggedCount() == 0)
    }

    @Test func membersStaleIsReSignedForACreationToo() async throws {
        let r = try await rig()
        await r.w.host.demoBumpMembersV()
        #expect(try await create(r) == .landedAfterResign(seq: 1, key: "MOB-0002"))
        #expect(r.hooks.count("pe.sign") == 2)
    }

    @Test func withoutTheDisclosureAKeyRaceIsNeverReSigned() async throws {
        let r = try await rig()
        await r.w.host.demoTakeNextKey()
        #expect(try await create(r, disclosed: .some(nil)) == .needsReview(.workspaceChanged))
        #expect(r.hooks.count("pe.sign") == 1)
        #expect(try await rows(r.p, "SELECT key_disclosed FROM pe_reviews").first?.text("key_disclosed") == nil)
    }

    @Test func aChangedDisplayedFieldBlocksTheAutomaticReSign() async throws {
        // the fresh read names keys of another workspace prefix than the one disclosed
        let r = try await rig()
        await r.w.host.demoTakeNextKey()
        let host = r.w.host
        await r.w.host.setHandler(await host.tampering("workspace.show") { $0["next_key"] = "OTH-0003"; $0["prefix"] = "OTH" })
        #expect(try await create(r) == .needsReview(.workspaceChanged))
        #expect(r.hooks.count("pe.sign") == 1)
    }

    @Test func aStoredTitleThatNoLongerMatchesItsEventIsNeverReSigned() async throws {
        // the displayed title (as stored) against the signed event: an unexpected changed field denies (14.4 item 3), nothing is signed
        let r = try await rig()
        await r.w.host.demoHoldNextWrite()
        #expect(try await create(r) == .checking)
        await r.w.host.demoTakeNextKey()                // the held write meets a key race when the host recovers it
        let db = try await r.p.container.database()
        let snap = try #require(try await rows(r.p, "SELECT snapshot FROM pe_reviews").first?.blob("snapshot"))
        var o = try #require(try StrictJSON.parse(snap).object)
        o["title"] = "Something else"
        try await db.execute("UPDATE pe_reviews SET snapshot=?", [.blob(try canonicalJSON(.object(o)))])
        await r.w.host.demoRecoverWrites()
        let out = try await settleAll(r, r.p)
        #expect(out == [.needsReview(.workspaceChanged)])
        #expect(r.hooks.count("pe.sign") == 1)
    }

    // MARK: ticket.exists (the retry note)

    /// The first attempt lands, but the phone hears a key race (a misreport) and its first `outcome.get` says the same; the re-sign under
    /// the same uid gets `ticket.exists`. Every earlier attempt is settled first: the first one's landing wins, and the review shows the
    /// ticket it created.
    @Test(arguments: [false, true])
    func ticketExistsAfterAReSignSettlesTheEarlierAttemptFirst(_ outcomeKeepsMisreporting: Bool) async throws {
        let firstIdem = IdemBox(), lied = Seq()
        let r = try await rig { req, host in
            let op = req.meta.object?["op"]?.string
            if op == "new_ticket", firstIdem.value == nil {
                firstIdem.set(req.meta.object?["idem"]?.string)
                _ = await host.handleView(req)                                   // landed as MOB-0002
                return .refuse(.host(code: "ticket.key_not_next", retryable: false, seqs: nil, nextKey: "MOB-0003"))
            }
            // the first attempt's outcome, misreported as the key race too (once, or always)
            if op == "outcome.get", req.meta.object?["args"]?.object?["idem"]?.string == firstIdem.value,
               outcomeKeepsMisreporting || lied.next() <= 1 {
                let r: JSONValue = ["data": ["state": "failed", "exit": 3, "error": ["code": "ticket.key_not_next"]], "key": .null, "seq": 0, "cursor": 0,
                                    "hints": [], "lines": [], "duplicate": false, "exit": 0, "head": .null]
                return .r2(try! canonicalJSON(r))
            }
            return nil
        }
        let out = try await create(r)
        #expect(out == .landed(seq: 1, key: "MOB-0002"))
        #expect(r.ops.value("new_ticket") == 2 && r.hooks.count("pe.sign") == 2)
        #expect(try await attemptStates(r.p) == ["landed", "superseded"])
        #expect(try await attemptLogs(r) == [r.review.uid, r.review.uid])
        #expect(await r.w.host.loggedCount() == 1)
        let src = try await rows(r.p, "SELECT evidence FROM pe_attempts WHERE n=1").first?.text("evidence") ?? ""
        #expect(src.contains(outcomeKeepsMisreporting ? "\"src\":\"log\"" : "\"src\":\"outcome\""))
    }

    @Test func ticketExistsWithNothingToAttributeShowsTheExistingTicket() async throws {
        // the uid exists under a key none of this review's attempts carries: `.ticketExists(key)`
        let r = try await rig { req, host in
            guard req.meta.object?["op"] == "new_ticket" else { return nil }
            return .refuse(.host(code: "ticket.exists", retryable: false, seqs: nil, nextKey: nil))
        }
        await r.w.host.demoPlantTicket(uid: r.review.uid, key: "MOB-0042")
        #expect(try await create(r) == .ticketExists(key: "MOB-0042"))
        #expect(try await attemptStates(r.p) == ["d"])
        #expect(try await rows(r.p, "SELECT state FROM pe_reviews").first?.text("state") == "refused")
    }

    // MARK: settlement by the log rule

    @Test func anExpiredIdemIsSettledByTheReviewsUid() async throws {
        // the response is lost and outcome.get answers idem.expired: the review's uid with this attempt's key is the landing
        let r = try await rig { req, host in
            if req.meta.object?["op"] == "outcome.get" { return .refuse(.host(code: "idem.expired", retryable: true, seqs: nil, nextKey: nil)) }
            return nil
        }
        await r.w.host.demoLoseNextWriteResponse()
        #expect(try await create(r) == .landed(seq: 1, key: "MOB-0002"))
        #expect(await r.w.host.loggedCount() == 1)
    }

    // MARK: migration 16

    @Test func migration16RetiresV0CreationRowsOnly() async throws {
        let w = try await World.make()
        let p = try await w.makePhone()
        let db = try await p.container.database()
        func frame(_ meta: JSONValue) throws -> Data { try Bridge.frame(meta: meta, data: Data()) }
        let v0 = try frame(["op": "new_ticket", "host_api": 0, "creation_id": .string(ID16.fresh(1).hex), "title": "x \"op\":\"new_ticket\"", "body": "", "epic_key": .null])
        let read = try frame(try R2.requestMeta(op: "ticket.query", args: [:]))
        let sneaky = try frame(try R2.requestMeta(op: "ticket.get", args: ["ref": "\"op\":\"new_ticket\",\"creation_id\":"]))
        for (rid, logical, pt) in [("r1", "l1", v0), ("r2", "l2", read), ("r3", "l3", sneaky)] {
            try await db.execute("INSERT INTO bridge_requests(rid, logical, seq, epoch, envelope, plaintext, sent_ms, created_ms, state) VALUES(?,?,1,1,x'00',?,0,0,'uncertain')",
                                 [.text(rid), .text(logical), .blob(pt)])
        }
        try await db.execute("INSERT INTO meta(key, value) VALUES('exhausted:l1', 1)")
        try await db.execute("INSERT INTO meta(key, value) VALUES('exhausted:l2', 1)")
        let m16 = try #require(WorkspaceContainer.migrations.first { $0.version == 16 })
        for st in m16.statements { try await db.execute(st) }
        #expect(try await db.query("SELECT rid FROM bridge_requests ORDER BY rid").compactMap { $0.text("rid") } == ["r2", "r3"])
        #expect(try await db.query("SELECT key FROM meta WHERE key LIKE 'exhausted:%'").compactMap { $0.text("key") } == ["exhausted:l2"])
    }
}

final class IdemBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: String?
    var value: String? { lock.withLock { v } }
    func set(_ s: String?) { lock.withLock { v = s } }
}

/// A thread-safe counter: `next()` returns 1, 2, 3, ...
final class Seq: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

extension FakeHost {
    /// Tests: a ticket at `uid` under `key` (the phone's uid already taken, as by an attempt the phone cannot attribute).
    fileprivate func demoPlantTicket(uid: String, key: String) {
        seedViews()
        var t = HostViewState.ticket(entropy, wall.nowMs, key, "Planted")
        t.uid = uid
        viewState!.tickets.append(t)
    }
}
