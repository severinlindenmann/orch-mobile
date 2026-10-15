import Foundation
import Testing
import OrchProtocol
@testable import OrchClient
@testable import OrchFakeHost

/// The op client against the FakeHost's core-op emulation: every read of the R2 table through real sealed bytes, the read retry classes, and
/// the one place a question can be reached for signing (`F1Question.reviewed`).
@Suite struct HostReadsFlowTests {
    private func setup() async throws -> (World, Phone) {
        let w = try await World.make()
        return (w, try await w.makePhone())
    }

    @Test func everyReadOfTheTableAnswersInTheR2Format() async throws {
        let (w, p) = try await setup()
        let s = p.session
        let needs = try await w.serve(p) { try await s.needs() }
        #expect(needs.items.count == 3 && needs.items.allSatisfy { $0.kind == .question && $0.key == "MOB-1" })
        let q = try await w.serve(p) { try await s.ticketQuery() }
        #expect(q.rows.map(\.key).sorted() == ["FAC-1", "MOB-1"] && q.total == 2)
        let g = try await w.serve(p) { try await s.ticketGet("MOB-1") }
        #expect(g.questions.count == 3 && g.uid == needs.items[0].uid)
        let m = try await w.serve(p) { try await s.memberList() }
        #expect(m.members.count == 1 && m.members[0].devices.contains { $0.id == "d_" + w.phoneID.hex && $0.label == "Demo iPhone" })
        let show = try await w.serve(p) { try await s.workspaceShow() }
        #expect(show.id == w.ws.hex && show.nextKey == "MOB-2")             // this device holds decide
        let a = try await w.serve(p) { try await s.activityList(limit: 1) }
        #expect(a.items.count == 1 && a.subCursor.hasPrefix("j:"))
        let who = try await w.serve(p) { try await s.whoami() }
        #expect(who.principal == "r:d_" + w.phoneID.hex)
        await #expect(throws: ClientError.host(.host(code: "outcome.unknown_idem", retryable: false, seqs: nil, nextKey: nil))) {
            _ = try await w.serve(p) { try await s.outcomeGet(idem: "01J9ZK4Q7M3R8T2V6X0B5N1C9D") }
        }
        // no `idem` on a read, ever: the host's own meta check would refuse it
        let withIdem = try JSONValue.object(["op": "whoami", "args": .object([:]), "idem": "01J9ZK4Q7M3R8T2V6X0B5N1C9D"])
        await #expect(throws: ClientError.host(.host(code: "req.invalid", retryable: false, seqs: nil, nextKey: nil))) {
            _ = try await w.serve(p) { try await s.exchange(meta: withIdem) }
        }
    }

    @Test func rdTravelsAsAMetaFieldAndNowhereElse() async throws {
        let (w, p) = try await setup()
        let rd = "sha256:" + String(repeating: "ab", count: 32)
        let seen = Seen()
        await w.host.setHandler { req in
            await seen.set(req.meta.object?["rd"]?.string)
            return await w.host.handleView(req)
        }
        let r = try await w.serve(p) { try await p.session.exchange(meta: R2.requestMeta(op: "whoami", rd: rd)) }
        #expect(r.status == 200 && r.headers.isEmpty)
        #expect(await seen.value == rd)
        let bad = JSONValue.object(["op": "whoami", "args": .object([:]), "rd": "not-a-digest"])
        await #expect(throws: ClientError.host(.host(code: "req.invalid", retryable: false, seqs: nil, nextKey: nil))) {
            _ = try await w.serve(p) { try await p.session.exchange(meta: bad) }
        }
    }

    @Test func aReadAnsweredAlreadyDoneUnknownIsIssuedAgainUnderANewRid() async throws {
        let (w, p) = try await setup()
        let n = Seen()
        await w.host.setHandler { req in
            if await n.bump() == 1 { return .refuse(.alreadyDone(status: "unknown")) }
            return await w.host.handleView(req)
        }
        let r = try await w.serve(p) { try await p.session.needs() }
        #expect(r.items.count == 3)
        #expect(await n.count == 2)
        let uncertain = try await p.session.uncertainRequests(), pending = try await p.session.pendingRequests()
        #expect(uncertain.isEmpty && pending.isEmpty)
        #expect(await w.host.coreState().rids.count == 2)         // two rids, one read each
    }

    @Test func classAIsSentAgainAndClassDIsDefinite() async throws {
        let (w, p) = try await setup()
        let n = Seen()
        await w.host.setHandler { req in
            if await n.bump() == 1 { return .refuse(.busy) }
            return await w.host.handleView(req)
        }
        #expect(try await w.serve(p) { try await p.session.workspaceShow() }.id == w.ws.hex)
        #expect(await n.count == 2)
        let m = Seen()
        await w.host.setHandler { _ in _ = await m.bump(); return .refuse(.host(code: "validation.event", retryable: false, seqs: nil, nextKey: nil)) }
        await #expect(throws: ClientError.host(.host(code: "validation.event", retryable: false, seqs: nil, nextKey: nil))) {
            _ = try await w.serve(p) { try await p.session.workspaceShow() }
        }
        #expect(await m.count == 1)
    }

    @Test func aQuestionIsSignableOnlyThroughTheF1Gate() async throws {
        let (w, p) = try await setup()
        let api = BridgeWorkspaceAPI(session: p.session)
        let s = try await w.serve(p) { try await api.snapshot() }
        #expect(s.questions.count == 3 && s.tickets.count == 2 && s.nextKey == "MOB-2")
        let review = try await w.serve(p) { try await api.review(questionID: s.questions[0].questionID) }
        let reviewed = try #require(review.reviewed)
        #expect(reviewed.qid == s.questions[0].questionID.hex && reviewed.rosterV == 1 && reviewed.ticketUID == s.questions[0].ticketUID)
        // an answered question is shown but carries no gate: nothing to sign
        try await w.host.demoAnswerOnHost(question: s.questions[1].questionID, optionID: "reject")
        let closed = try await w.serve(p) { try await api.review(questionID: s.questions[1].questionID) }
        #expect(closed.reviewed == nil && closed.question.resolution?.byDeviceLabel == "Demo Mac")
    }
}

/// Identity-derived caches belong to one verified epoch and die with any failed read; the attestation (`rd`) fails closed.
@Suite struct HostReadsFailClosedTests {
    @Test func aNewEpochDropsEveryIdentityCache() async throws {
        let w = try await World.make()
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        _ = try await w.serve(p) { try await api.snapshot() }
        let before = await p.session.identityCacheState()
        #expect(before.epoch == 1 && before.labels > 0 && before.indexed == 3 && before.tickets == 1)
        // a rotation (a removal or revocation publishes a new epoch): the phone takes it only through the signed list and grants
        try await w.host.rotate(remaining: await w.host.rosterEntries(), relay: w.relay, session: w.hostSession)
        _ = try await w.serve(p) { try await p.session.refreshGrants(forceList: true) }
        let probe = Seen()
        await w.host.setHandler { req in _ = await probe.bump(); return .refuse(.malformed) }
        _ = try? await w.serve(p) { try await api.snapshot() }          // fails: the first read is refused
        let after = await p.session.identityCacheState()
        #expect(after.epoch == 2 && after.labels == 0 && after.indexed == 0 && after.tickets == 0 && after.cursor == nil)
    }

    @Test func aFailedReadKeepsNothingAndWhoamiNeverGrantsScopes() async throws {
        let w = try await World.make()
        let p = try await w.makePhone()
        let api = BridgeWorkspaceAPI(session: p.session)
        _ = try await w.serve(p) { try await api.snapshot() }
        #expect(await p.session.identityCacheState().indexed == 3)
        await w.host.setHandler { _ in .refuse(.host(code: "internal", retryable: false, seqs: nil, nextKey: nil)) }
        await #expect(throws: (any Error).self) { _ = try await w.serve(p) { try await api.snapshot() } }
        let s = await p.session.identityCacheState()
        #expect(s.labels == 0 && s.indexed == 0 && s.tickets == 0 && s.cursor == nil)
        await #expect(throws: (any Error).self) { _ = try await w.serve(p) { try await p.session.whoami() } }
        // scopes are the certificate's and the verified list's (the pairing), never a host view: the session has no scope derived from `whoami`,
        // `member.list` or `workspace.show`, and `next_key` is only advice
        #expect(!Mirror(reflecting: await p.session.configuration).children.contains { $0.label == "scopes" })
    }

    private func reader(_ w: World, level: Int? = nil) -> ReaderRuntime { .production }

    @Test func noDeclarationMeansNoRdAndAHostReaderRefusalIsSurfacedNotRetried() async throws {
        let w = try await World.make()
        let p = try await w.makePhone(reader: ReaderRuntime(capability: nil, build: "t"), sendsReaderDigest: true)
        let seen = Seen()
        await w.host.setHandler { req in
            await seen.set(req.meta.object?["rd"]?.string)
            _ = await seen.bump()
            return .refuse(.host(code: "sign.convenience_readers", retryable: false, seqs: nil, nextKey: nil))
        }
        await #expect(throws: ClientError.host(.host(code: "sign.convenience_readers", retryable: false, seqs: nil, nextKey: nil))) {
            _ = try await w.serve(p) { try await p.session.workspaceShow() }
        }
        let rdSeen = await seen.value, calls = await seen.count
        #expect(rdSeen == nil && calls == 1)          // no `rd` invented, and the refusal was not sent again
    }

    @Test func aCorruptOrForeignDeclarationFailsClosed() async throws {
        let w = try await World.make()
        let p = try await w.makePhone(sendsReaderDigest: true)
        try w.vault.scoped(to: .demo).put(Data("garbage".utf8), ws: w.ws.hex, purpose: "reader.state")
        await #expect(throws: SessionError.readerStateUnreadable) { _ = try await w.serve(p) { try await p.session.workspaceShow() } }
        // a declaration made by ANOTHER device key for this workspace claims a level this device never proved
        let other = SoftwareSigner(), kx = SoftwareKeyAgreer()
        guard let cap = ReaderKAT.current else { return }                   // a build whose KAT cannot run declares nothing
        let decl = try ReaderDeclaration.make(workspace: w.ws, dkSig: other.publicKey, dkKx: kx.publicKey, who: .person(w.primary.personID), level: cap.level,
                                              kat: cap.kat, bind: .declare, createdMs: w.clock.nowMs, signer: other)
        try ReaderStore.save(w.vault.scoped(to: .demo), ws: w.ws, ReaderStateRecord(decl: decl, highest: decl.level, build: BuildIdentity.current, acked: true))
        let q = try await w.makePhone(install: false, sendsReaderDigest: true)
        await #expect(throws: SessionError.readerStateUnreadable) { _ = try await w.serve(q) { try await q.session.workspaceShow() } }
    }

    @Test func rdSwitchesToTheDigestOfTheDeclareAnswer() async throws {
        let w = try await World.make()
        let p = try await w.makePhone(sendsReaderDigest: true)
        guard let cap = ReaderKAT.current else { return }
        let keys = w.env.device.publicKeys
        let decl = try ReaderDeclaration.make(workspace: w.ws, dkSig: keys.sig, dkKx: keys.kx, who: .person(w.primary.personID), level: cap.level, kat: cap.kat,
                                              bind: .declare, createdMs: w.clock.nowMs, signer: w.env.device.sig)
        let vault = w.vault.scoped(to: .demo)
        try ReaderStore.save(vault, ws: w.ws, ReaderStateRecord(decl: decl, highest: decl.level, build: p.session.configuration.reader.build, acked: true))
        // until the first declare answer: the pair declaration's own digest
        #expect(try await p.session.readerDigestForRequest() == decl.digest)
        // the host kept the bytes it already held for this body under another signature: its digest is the one `rd` carries from then on
        let hostDigest = "sha256:" + String(repeating: "cd", count: 32)
        #expect(try await p.session.readerDeclareAcknowledged(digest: hostDigest, level: decl.level))
        #expect(try await p.session.readerDigestForRequest() == hostDigest)
        let resigned = try decl.resigned(createdMs: decl.createdMs + 1, dkSig: keys.sig, dkKx: keys.kx, signer: w.env.device.sig)
        #expect(resigned.digest != decl.digest && resigned.digest != hostDigest)         // a re-sign differs; it is never what `rd` carries
        #expect(try await p.session.readerDigestForRequest() == hostDigest)
        // an answer for another level (an older declaration) changes nothing
        #expect(try await p.session.readerDeclareAcknowledged(digest: "sha256:" + String(repeating: "ef", count: 32), level: decl.level + 1) == false)
        #expect(try await p.session.readerDigestForRequest() == hostDigest)
        // and the request really carries it, as a meta field
        let seen = Seen()
        await w.host.setHandler { req in await seen.set(req.meta.object?["rd"]?.string); return await w.host.handleView(req) }
        _ = try await w.serve(p) { try await p.session.workspaceShow() }
        #expect(await seen.value == hostDigest)
    }

    private func declaredPhone(_ w: World) async throws -> (Phone, ReaderDeclaration)? {
        guard let cap = ReaderKAT.current else { return nil }
        let p = try await w.makePhone(sendsReaderDigest: true)
        let keys = w.env.device.publicKeys
        let decl = try ReaderDeclaration.make(workspace: w.ws, dkSig: keys.sig, dkKx: keys.kx, who: .person(w.primary.personID), level: cap.level, kat: cap.kat,
                                              bind: .declare, createdMs: w.clock.nowMs, signer: w.env.device.sig)
        try ReaderStore.save(w.vault.scoped(to: .demo), ws: w.ws, ReaderStateRecord(decl: decl, highest: decl.level, build: p.session.configuration.reader.build, acked: true))
        // the realm's certificate record: the person a re-declaration is for
        let pk = B64U.encode(await w.primary.publicKey.x963)
        try w.vault.scoped(to: .demo).put(try canonicalJSON(["pk_pub": .string(pk)]), purpose: "device.cert")
        return (p, decl)
    }

    @Test func declarationUnknownDeclaresAgainAndResendsTheOriginalUnderANewRid() async throws {
        let w = try await World.make()
        guard let (p, decl) = try await declaredPhone(w) else { return }
        let log = ReqLog()
        await w.host.setHandler { req in
            let op = req.meta.object?["op"]?.string ?? ""
            await log.add(op, rd: req.meta.object?["rd"]?.string, idem: req.meta.object?["idem"] != nil)
            if op == "needs", await log.count(of: "needs") == 1 {
                return .refuse(.reader(code: "sign.convenience_readers", reason: "declaration_unknown", required: nil, declared: nil))
            }
            return await w.host.handleView(req)
        }
        let r = try await w.serve(p) { try await p.session.needs() }
        #expect(r.items.count == 3)
        let entries = await log.entries
        #expect(entries.map(\.op) == ["needs", "reader.declare", "needs"])
        #expect(entries[1].rd == nil && !entries[1].idem)                  // the declare is exempt from rd and has no idem
        #expect(entries[0].rd == decl.digest && entries[2].rd != nil)
        #expect(await w.host.coreState().rids.count == 3)                   // the original went again under a NEW rid
    }

    @Test func noDeclarationAndReaderTooOldAreNotRetried() async throws {
        let w = try await World.make()
        guard let (p, _) = try await declaredPhone(w) else { return }
        for refusal in [HostRefusal.reader(code: "sign.convenience_readers", reason: "no_declaration", required: nil, declared: nil),
                        .reader(code: "sign.convenience_readers", reason: "reader_too_old", required: 1, declared: 0)] {
            let n = ReqLog()
            await w.host.setHandler { req in await n.add(req.meta.object?["op"]?.string ?? "", rd: nil, idem: false); return .refuse(refusal) }
            await #expect(throws: ClientError.host(refusal)) { _ = try await w.serve(p) { try await p.session.needs() } }
            #expect(await n.entries.map(\.op) == ["needs"])               // no re-declare, no resend: "Update orch to use this workspace"
        }
    }

    @Test func declarationUnknownIsSurfacedAndFailsClosedWhenThisBuildDeclaresNothing() async throws {
        let w = try await World.make()
        let p = try await w.makePhone(reader: ReaderRuntime(capability: nil, build: "t"), sendsReaderDigest: true)
        let seen = Seen()
        let refusal = HostRefusal.reader(code: "sign.convenience_readers", reason: "declaration_unknown", required: nil, declared: nil)
        await w.host.setHandler { _ in _ = await seen.bump(); return .refuse(refusal) }
        await #expect(throws: ClientError.host(refusal)) { _ = try await w.serve(p) { try await p.session.needs() } }
        let calls = await seen.count
        #expect(calls == 1)                                       // no new rid, no silent retry, until `reader.declare` can be sent
        let pending = try await p.session.pendingRequests()
        #expect(pending.isEmpty)
        let state = await p.session.identityCacheState()
        #expect(state.tickets == 0 && state.cursor == nil)
    }

    @Test func theDowngradeMarkerIsCheckedBeforeEveryRequest() async throws {
        let w = try await World.make()
        let p = try await w.makePhone(reader: ReaderRuntime(capability: nil, build: "t"), sendsReaderDigest: true)
        // the marker rises after the session was built (a newer build declared level 1): this build, at level 0, sends nothing
        try ReaderStore.save(w.vault.scoped(to: .demo), ws: w.ws, ReaderStateRecord(decl: nil, highest: 1, build: "newer", acked: true))
        await #expect(throws: SessionError.readerDowngrade) { _ = try await w.serve(p) { try await p.session.workspaceShow() } }
        #expect(await w.host.coreState().rids.isEmpty)
    }
}

private actor ReqLog {
    struct Entry: Sendable { let op: String; let rd: String?; let idem: Bool }
    private(set) var entries: [Entry] = []
    func add(_ op: String, rd: String?, idem: Bool) { entries.append(Entry(op: op, rd: rd, idem: idem)) }
    func count(of op: String) -> Int { entries.filter { $0.op == op }.count }
}

private actor Seen {
    private(set) var value: String?
    private(set) var count = 0
    func set(_ v: String?) { value = v }
    func bump() -> Int { count += 1; return count }
}
