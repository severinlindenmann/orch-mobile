import Foundation
import LocalAuthentication
import OrchCustody
import OrchFakeHost
import OrchProtocol
import Testing
@testable import OrchClient

/// Selective workspaces on the phone (design B5, protocol 8.6 and 10.2b): only shared items and summaries; a summary is never signable; a
/// shared item whose `f1` names the target is signed through the same `HubSignSession` as in full mode, with `item` in the action, text only
/// for an answer, and `item_hash` in the event.
private final class Clock: WallClock, @unchecked Sendable {
    var nowMs: Int64 { 1_790_000_000_000 }
}

private final class Face: BiometricContext, @unchecked Sendable {
    nonisolated(unsafe) static var evaluations = 0
    var localizedFallbackTitle: String?
    var evaluatedPolicyDomainState: Data? { Data("faces-1".utf8) }
    func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool { true }
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool { Face.evaluations += 1; return true }
}

private struct Rig {
    let hub: FakeHub
    let home: HubHomeCoordinator
    let session: HubSignSession
    let backend = InMemoryVaultBackend()

    init(mode: @escaping @Sendable (String) async -> HubWorkspace.Mode? = { _ in nil }) async throws {
        Face.evaluations = 0
        let clock = Clock()
        let h = FakeHub(origin: "https://hub.dev.orch.example", wall: clock)
        h.seedHome(); h.seedSelective()
        hub = h
        let custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        let make: @Sendable (String) throws -> any RequestSender = { o in guard o == h.origin else { throw TransportError.disconnected }; return h }
        let pairing = HubPairingCoordinator(HubPairingConfig(custody: custody, verifier: HubVerifier(devMode: true), wall: clock, makeSender: make,
                                                             biometryBaseline: { Data("faces-1".utf8) }))
        _ = await pairing.begin(link: h.pairingLink)
        guard case .paired(let s) = await pairing.complete(password: h.password, totp: h.totp, label: "Dev hub") else { throw TransportError.disconnected }
        home = HubHomeCoordinator(custody: custody, cache: InMemoryHubCache(), verifier: HubVerifier(devMode: true), wall: clock, makeSender: make)
        session = HubSignSession(HubSignConfig(custody: custody, verifier: HubVerifier(devMode: true), wall: clock, makeSender: make,
                                               biometry: BiometricGate(makeContext: { Face() }),
                                               isMyWorkspace: { $0 == FakeHub.wsShared }, contentLink: { o, _, _ in URL(string: o + "/") },
                                               workspaceMode: mode),
                                 hubID: s.hubID)
        _ = await home.refresh()
    }

    func detail(_ item: String) async throws -> HubItemDetail {
        guard case .detail(let d) = await home.item(workspaceID: FakeHub.wsShared, itemID: item) else { throw TransportError.disconnected }
        return d
    }

    /// The action the screen would build from the item's decision (the same shape as `HubItemScreen`).
    func action(_ item: String, text: String = "Go with EU West") async throws -> HubSignAction {
        let d = try #require(try await detail(item).decision)
        let sel: HubSignAction.Selective = switch d.kind {
        case .question(let q, _): .answerQuestion(log: d.log, question: q, hash: d.hash, text: text)
        case .gate(let g): .approveGate(log: d.log, gate: g, hash: d.hash)
        case .verdict: .giveVerdict(log: d.log, outcome: "pass", hash: d.hash, text: nil)
        }
        return .shared(bound: try #require(d.shared), sel)
    }

    func prepare(_ a: HubSignAction) async throws -> HubSignPrompt { try await session.prepare(workspaceID: FakeHub.wsShared, action: a) }
}

private func rebound(_ b: HubItemDecision.Shared, _ item: String) -> HubItemDecision.Shared {
    .init(item: item, itemHash: b.itemHash, rosterV: b.rosterV, gateGen: b.gateGen, policyHash: b.policyHash, sourceSha: b.sourceSha)
}

private func failure(_ body: () async throws -> some Any) async -> HubSignFailure? {
    do { _ = try await body(); return nil } catch let f as HubSignFailure { return f } catch { return .custody }
}

@Suite(.serialized) struct HubSelectiveTests {
    // MARK: summaries

    @Test func aNeedsYouSummaryIsNeverSignable() async throws {
        let r = try await Rig()
        guard case .live(let snap) = await r.home.state else { Issue.record("not live"); return }
        #expect(snap.rows(in: FakeHub.wsShared).filter(\.summaryOnly).map(\.kind) == ["needs_you"])
        // even an answer that carries a full `f1` and a hub hint "signable" gives a summary no decision
        var o = try #require(r.hub.itemAnswers[FakeHub.wsShared + "/" + FakeHub.sharedGateItem]?.object)
        o["item_id"] = "s2"; o["kind"] = "needs_you"; o["signable"] = true
        r.hub.itemAnswers[FakeHub.wsShared + "/s2"] = .object(o)
        let d = try await r.detail("s2")
        #expect(d.row.summaryOnly && d.decision == nil)
    }

    @Test func aSharedItemWithoutF1OffersNothing() async throws {
        let r = try await Rig()
        let d = try await r.detail(FakeHub.sharedNoF1Item)
        #expect(!d.row.summaryOnly && d.decision == nil)
        #expect(try await r.detail("s1").decision == nil)          // the older item has no chain and no f1 either
    }

    // MARK: a shared question

    @Test func aSharedQuestionIsAnsweredWithTextOnly() async throws {
        let r = try await Rig()
        let d = try #require(try await r.detail(FakeHub.sharedQuestionItem).decision)
        guard case .question(let q, let options) = d.kind else { Issue.record("not a question"); return }
        #expect(q == "Q2" && options.isEmpty && d.hash == FakeHub.sharedQuestionHash && d.shared?.item == FakeHub.sharedQuestionItem)
        let a = try await r.action(FakeHub.sharedQuestionItem)
        let sent = try #require(a.json.object)
        #expect(sent["item"]?.string == FakeHub.sharedQuestionItem && sent["option"] == nil && sent["text"]?.string == "Go with EU West")
        let p = try await r.prepare(a)
        #expect(p.facts.selective && p.facts.sentence == "Answer question Q2: Go with EU West")
        #expect(p.facts.fields.contains { $0.name == "item_hash" && $0.value == FakeHub.sharedItemHash })   // shown under "Signed details"
        #expect(Face.evaluations == 0)
        let receipt = try await r.session.confirm(preparedID: p.preparedID)
        #expect(receipt.type == "question.answered" && Face.evaluations == 1)
        #expect(r.hub.signedEvents.map(\.type) == ["question.answered"])
    }

    @Test func aSharedGateAndACodeGateAreSignedWithTheirValues() async throws {
        let r = try await Rig()
        let plan = try await r.prepare(try await r.action(FakeHub.sharedGateItem))
        #expect(plan.facts.selective && plan.facts.gate == "plan" && plan.facts.gateGen == 2 && plan.facts.sources.isEmpty)
        _ = try await r.session.confirm(preparedID: plan.preparedID)
        let code = try await r.prepare(try await r.action(FakeHub.sharedCodeItem))
        #expect(code.facts.gate == "code" && code.facts.sources == [HubSign.Source(repo: "orch-core", sha: "9f2c1a7b")])
        _ = try await r.session.confirm(preparedID: code.preparedID)
        #expect(r.hub.signedEvents.map(\.type) == ["gate.approved", "gate.approved"])
    }

    @Test func requestChangesOnACodeGateAndAPlanGateIsSignedWithoutSourceSha() async throws {
        let r = try await Rig()
        for item in [FakeHub.sharedCodeItem, FakeHub.sharedGateItem] {
            let d = try #require(try await r.detail(item).decision)
            guard case .gate(let g) = d.kind else { Issue.record("not a gate"); return }
            let a = HubSignAction.shared(bound: try #require(d.shared), .requestChanges(log: d.log, gate: g, hash: d.hash, text: "Add tests"))
            let p = try await r.prepare(a)
            #expect(p.facts.selective && p.facts.type == "gate.changes_requested" && p.facts.gate == g && p.facts.sources.isEmpty)
            _ = try await r.session.confirm(preparedID: p.preparedID)
        }
        #expect(r.hub.signedEvents.map(\.type) == ["gate.changes_requested", "gate.changes_requested"])
    }

    @Test func sourceShaIsHeldToTheTypeThatCarriesIt() async throws {
        let r = try await Rig()
        let d = try #require(try await r.detail(FakeHub.sharedCodeItem).decision)
        // an approval on a code gate without `source_sha`
        r.hub.faults.dropSource = true
        #expect(await failure { try await r.prepare(try await r.action(FakeHub.sharedCodeItem)) } == .changed(code: "event_changed"))
        // a change request that carries one (a hub that does not follow 8.5)
        r.hub.faults.dropSource = false; r.hub.faults.sourceOnEveryGate = true
        let ask = HubSignAction.shared(bound: try #require(d.shared), .requestChanges(log: d.log, gate: "code", hash: d.hash, text: "x"))
        #expect(await failure { try await r.prepare(ask) } == .changed(code: "event_changed"))
        #expect(r.hub.signedEvents.isEmpty && Face.evaluations == 0)
    }

    // MARK: options are refused

    @Test func anOptionOnASelectiveAnswerIsRefused() async throws {
        let r = try await Rig()
        let a = try await r.action(FakeHub.sharedQuestionItem)
        // a hub that adds an option the person never saw
        r.hub.faults.selectiveOption = true
        #expect(await failure { try await r.prepare(a) } == .changed(code: "event_changed"))   // an option the action did not send
        #expect(await failure { try await r.session.confirm(preparedID: r.hub.lastPreparedID ?? "none") } == .notLive)
        #expect(r.hub.signedEvents.isEmpty && Face.evaluations == 0)
        // a hand-made action with an option: the hub refuses it (and the phone's own check refuses the answer)
        r.hub.faults.selectiveOption = false
        let d = try #require(try await r.detail(FakeHub.sharedQuestionItem).decision)
        let bad = HubSignAction.answerQuestion(log: d.log, question: "Q2", hash: d.hash, option: "yes", text: "x")
        var o = try #require(bad.json.object); o["item"] = .string(FakeHub.sharedQuestionItem)
        #expect(throws: Refusal.malformed) { try HubSign.checkSelectiveBuilt(action: .object(o), event: .object(["type": "question.answered", "item_hash": .string(FakeHub.sharedItemHash), "text": "x"])) }
        // and `facts` refuses a selective answer that carries an option, or has no text, however it reached the phone
        for extra: [String: JSONValue] in [["option": "yes", "text": "x"], ["option": "yes"]] {
            var e: [String: JSONValue] = ["type": "question.answered", "question": "Q2", "hash": .string(FakeHub.sharedQuestionHash), "item_hash": .string(FakeHub.sharedItemHash)]
            e.merge(extra) { $1 }
            let ctx: JSONValue = .object(["contract": 1, "suite": 2, "workspace_id": .string(FakeHub.wsShared), "log": .string(r.hub.ticketLog), "event": .object(e)])
            #expect(throws: Refusal.malformed) { try HubSign.facts(ctx: ctx) }
        }
    }

    // MARK: item_hash

    @Test func itemHashIsRequiredInSelectiveMode() async throws {
        let r = try await Rig()
        let a = try await r.action(FakeHub.sharedQuestionItem)
        r.hub.faults.dropItemHash = true
        #expect(await failure { try await r.prepare(a) } == .changed(code: "event_changed"))
        #expect(await failure { try await r.session.confirm(preparedID: r.hub.lastPreparedID ?? "none") } == .notLive)
        #expect(r.hub.signedEvents.isEmpty && Face.evaluations == 0)
    }

    @Test func itemHashIsForbiddenOutsideSelectiveMode() async throws {
        // a full-mode action (no `item`) whose event carries an `item_hash`
        let plain = JSONValue.object(["type": "gate.approved", "log": "L", "gate": "plan", "hash": "h"])
        #expect(throws: Refusal.eventChanged) { try HubSign.checkSelectiveBuilt(action: plain, event: .object(["item_hash": .string(FakeHub.sharedItemHash)])) }
        try HubSign.checkSelectiveBuilt(action: plain, event: .object(["type": "gate.approved"]))
        // a selective action whose event has none, or a malformed one, or an `item` in the event
        let sel = JSONValue.object(["type": "gate.approved", "log": "L", "gate": "plan", "hash": "h", "item": .string(FakeHub.sharedGateItem)])
        #expect(throws: Refusal.eventChanged) { try HubSign.checkSelectiveBuilt(action: sel, event: .object(["type": "gate.approved"])) }
        #expect(throws: Refusal.eventChanged) { try HubSign.checkSelectiveBuilt(action: sel, event: .object(["item_hash": "nope"])) }
        #expect(throws: Refusal.eventChanged) {
            try HubSign.checkSelectiveBuilt(action: sel, event: .object(["item_hash": .string(FakeHub.sharedItemHash), "item": .string(FakeHub.sharedGateItem)]))
        }
        // `item` must be 32 hex
        let short = JSONValue.object(["type": "gate.approved", "item": "s1"])
        #expect(throws: Refusal.malformed) { try HubSign.checkSelectiveBuilt(action: short, event: .object(["item_hash": .string(FakeHub.sharedItemHash)])) }
    }

    @Test func aPushedRequestIsHeldToTheWorkspaceMode() async throws {
        // the list says the workspace is selective: a pushed request without `item_hash` is refused (and one with it is shown)
        let r = try await Rig(mode: { $0 == FakeHub.wsShared ? .selective : nil })
        let p = try await r.prepare(try await r.action(FakeHub.sharedGateItem))
        let opened = try await r.session.open(preparedID: r.hub.lastPreparedID ?? "none")
        #expect(opened.facts.selective && p.facts.type == opened.facts.type)
        r.hub.faults.dropItemHash = true
        _ = try? await r.prepare(try await r.action(FakeHub.sharedGateItem))
        #expect(await failure { try await r.session.open(preparedID: r.hub.lastPreparedID ?? "none") } == .changed(code: "event_changed"))
        // the list says it is full: an `item_hash` has no business there
        let f = try await Rig(mode: { _ in .full })
        let q = try await f.prepare(try await f.action(FakeHub.sharedGateItem))
        #expect(await failure { try await f.session.open(preparedID: q.preparedID) } == .changed(code: "event_changed"))
    }

    // MARK: the item's values are bound

    @Test func anItemOrTargetNotInF1IsRefused() async throws {
        let r = try await Rig()
        let d = try #require(try await r.detail(FakeHub.sharedQuestionItem).decision)
        let bound = try #require(d.shared)
        // a question the item's f1 does not name
        let other = HubSignAction.shared(bound: bound, .answerQuestion(log: d.log, question: "Q9", hash: d.hash, text: "x"))
        #expect(await failure { try await r.prepare(other) } == .hub(code: "unknown_item"))
        // an item the hub does not hold, and the right item on another log
        let ghost = HubSignAction.shared(bound: rebound(bound, String(repeating: "00", count: 16)), .answerQuestion(log: d.log, question: "Q2", hash: d.hash, text: "x"))
        #expect(await failure { try await r.prepare(ghost) } == .hub(code: "unknown_item"))
        let log = HubSignAction.shared(bound: bound, .answerQuestion(log: "01J9ZP0000000000000000OTHR", question: "Q2", hash: d.hash, text: "x"))
        #expect(await failure { try await r.prepare(log) } == .hub(code: "unknown_item"))
        // a gate the f1 does not name: the plan item has no `code` entry
        let g = try #require(try await r.detail(FakeHub.sharedGateItem).decision)
        let code = HubSignAction.shared(bound: try #require(g.shared), .approveGate(log: g.log, gate: "code", hash: g.hash))
        #expect(await failure { try await r.prepare(code) } == .hub(code: "unknown_item"))
        // a reviewed hash that is not the f1's is `event_changed`
        let stale = HubSignAction.shared(bound: try #require(g.shared), .approveGate(log: g.log, gate: "plan", hash: FakeHub.contentHash))
        #expect(await failure { try await r.prepare(stale) } == .changed(code: "event_changed"))
        // the shared item without f1: the hub cannot build (`unavailable`), and the phone never offered it
        let none = HubSignAction.shared(bound: rebound(bound, FakeHub.sharedNoF1Item), .approveGate(log: d.log, gate: "plan", hash: d.hash))
        #expect(await failure { try await r.prepare(none) } == .hub(code: "unavailable"))
        #expect(r.hub.signedEvents.isEmpty && Face.evaluations == 0)
    }

    @Test func aStaleValueOrAnotherItemsHashIsRefusedOnThePhone() async throws {
        let r = try await Rig()
        let a = try await r.action(FakeHub.sharedGateItem)
        r.hub.faults.staleGateGen = true                     // the hub built on a round the item did not show
        #expect(await failure { try await r.prepare(a) } == .changed(code: "event_changed"))
        r.hub.faults.staleGateGen = false; r.hub.faults.otherItemHash = true   // the hub built on another item's version
        #expect(await failure { try await r.prepare(a) } == .changed(code: "event_changed"))
        #expect(r.hub.signedEvents.isEmpty && Face.evaluations == 0)
    }

    @Test func f1ParsingOffersExactlyOneReadableTarget() throws {
        func item(_ f1: JSONValue, kind: String = "ticket", content: JSONValue = .object([:])) -> [String: JSONValue] {
            ["item_id": .string(FakeHub.sharedGateItem), "item_hash": .string(FakeHub.sharedItemHash), "chain": .object(["log": .string("01J9ZP0000000000000000TKT1")]), "f1": f1]
        }
        let h = JSONValue.string(FakeHub.sharedGateHash)
        let gate: (JSONValue?) -> JSONValue = { src in
            var g: [String: JSONValue] = ["gen": 1, "hash": h, "policy_hash": h]; if let src { g["source_sha"] = src }
            return .object(g)
        }
        func f1(_ gates: [String: JSONValue], _ qs: [String: JSONValue] = [:]) -> JSONValue { .object(["roster_v": 1, "gates": .object(gates), "questions": .object(qs)]) }
        let src: JSONValue = .array([.object(["repo": "r", "ref": "refs/heads/main", "sha": "9f2c1a7be4d05c3a8e6f1b2c4d5e6f708192a3b4"])])
        // verify gate -> a verdict (with its source list); requirements/plan take none; code needs one
        #expect(HubViewParse.sharedDecision(item(f1(["verify": gate(src)])), content: .object([:]), kind: "ticket")?.kind == .verdict)
        #expect(HubViewParse.sharedDecision(item(f1(["plan": gate(nil)])), content: .object([:]), kind: "ticket")?.kind == .gate("plan"))
        #expect(HubViewParse.sharedDecision(item(f1(["plan": gate(src)])), content: .object([:]), kind: "ticket") == nil)
        #expect(HubViewParse.sharedDecision(item(f1(["code": gate(nil)])), content: .object([:]), kind: "ticket") == nil)
        // two targets, none, an unknown gate, or a question id that is not the item's: nothing
        #expect(HubViewParse.sharedDecision(item(f1(["plan": gate(nil), "requirements": gate(nil)])), content: .object([:]), kind: "ticket") == nil)
        #expect(HubViewParse.sharedDecision(item(f1([:])), content: .object([:]), kind: "ticket") == nil)
        #expect(HubViewParse.sharedDecision(item(f1(["deploy": gate(nil)])), content: .object([:]), kind: "ticket") == nil)
        let q = f1([:], ["Q1": .object(["hash": h])])
        #expect(HubViewParse.sharedDecision(item(q), content: .object(["id": "Q2"]), kind: "question") == nil)
        #expect(HubViewParse.sharedDecision(item(q), content: .object(["id": "Q1"]), kind: "ticket") == nil)
        #expect(HubViewParse.sharedDecision(item(q), content: .object(["id": "Q1"]), kind: "question")?.kind == .question(id: "Q1", options: []))
        // an item id that is not 32 hex cannot be named in an action
        var bad = item(f1(["plan": gate(nil)])); bad["item_id"] = "s1"
        #expect(HubViewParse.sharedDecision(bad, content: .object([:]), kind: "ticket") == nil)
    }
}
