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

private actor Seen {
    private(set) var value: String?
    private(set) var count = 0
    func set(_ v: String?) { value = v }
    func bump() -> Int { count += 1; return count }
}
