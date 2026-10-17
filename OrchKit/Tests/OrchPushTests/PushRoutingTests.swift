import Foundation
import OrchProtocol
import OrchPushFixtures
import Testing
@testable import OrchPush

/// B10 phase 1: the hint push (core #628 contract (d)) is a `ticket.update` with id `ph_<ULID>` and the label "Needs your approval" padded to
/// 80 code points. It is shown with that label and opens the approvals list; nothing else routes.
struct PushRoutingTests {
    let a = PushFixtures.workspaceA
    let hint = "ph_01M4JM4RKG79RG3QTWCP60NNNG"
    var label: String { "Needs your approval" + String(repeating: " ", count: 80 - "Needs your approval".count) }

    func seal(_ kind: String, _ id: String, _ ts: Int64 = nowMs - 1000, label: String? = nil) -> String {
        PushFixtures.seal(a, PushFixtures.payload(kind: kind, id: id, label: label ?? self.label, tsMs: ts))
    }

    @Test func theHintIsShownWithItsLabelAndRoutesToTheApprovalsList() {
        let dir = tmp()
        let h = handler(dir: dir, [a.id: material(a)])
        let r = h.handle(o: seal("ticket.update", hint))
        #expect(r.outcome == .shown)
        #expect(r.presentation.body == "Needs your approval" && r.presentation.style == .event)
        // no ticket text, no key: only the label and the opaque id
        #expect(r.presentation.entityKey == "\(a.id.hex)/\(hint)")
        #expect(PushRouting.route(entityKey: r.presentation.entityKey) == .approvals(workspaceHex: a.id.hex))
        let p = PushProcessor.Payload(workspace: a.id, epoch: 1, kind: "ticket.update", id: hint, label: label, tsMs: 1)
        #expect(PushRouting.route(p) == .approvals(workspaceHex: a.id.hex))
    }

    @Test func nothingElseRoutes() {
        let ws = a.id.hex
        #expect(PushRouting.route(entityKey: "\(ws)/q1") == .none)
        #expect(PushRouting.route(entityKey: "\(ws)/ph_notaulid") == .none)
        #expect(PushRouting.route(entityKey: "\(ws)/ph_") == .none)
        #expect(PushRouting.route(entityKey: "zz/\(hint)") == .none)
        #expect(PushRouting.route(entityKey: "\(ws)/\(hint)/x") == .none)
        #expect(PushRouting.route(entityKey: nil) == .none)
        for kind in ["question", "question.closed", "drop.new", "peer.ticket", "join"] {
            let p = PushProcessor.Payload(workspace: a.id, epoch: 1, kind: kind, id: hint, label: "x", tsMs: 1)
            #expect(PushRouting.route(p) == .none, Comment(rawValue: kind))
        }
        #expect(PushRouting.route(PushProcessor.Payload(workspace: a.id, epoch: 1, kind: "ticket.update", id: "t_other", label: "x", tsMs: 1)) == .none)
    }
}
