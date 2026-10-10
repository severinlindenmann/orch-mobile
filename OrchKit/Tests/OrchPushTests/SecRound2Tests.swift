import Foundation
import OrchProtocol
import OrchPushFixtures
import OrchCoordination
import Testing
@testable import OrchPush

struct SecRound2Tests {
    let a = PushFixtures.workspaceA
    func q(_ id: String, _ ts: Int64, kind: String = "question") -> String {
        PushFixtures.seal(a, PushFixtures.payload(kind: kind, id: id, label: "x", tsMs: ts))
    }
    @Test func corruptFloorThenRejoin() throws {
        let dir = tmp()
        let p = q("q1", nowMs - 1000)
        #expect(handler(dir: dir, [a.id: material(a, generation: 1)]).handle(o: p).outcome == .shown)
        let st = ReplayStore(pushDir: dir, realm: "live")
        try Data("{".utf8).write(to: st.floorURL(workspace: a.id))
        try TombstoneCoordination(directories: [dir]).write(TombstoneRecord(realm: "live", ws: a.id.hex, generation: 1))
        try FileManager.default.removeItem(at: st.stateDir(workspace: a.id))
        let r = handler(dir: dir, [a.id: material(a, generation: 2)]).handle(o: p).outcome
        print("SEC R2a corrupt floor + rejoin replay: \(r)")
        #expect(r == .droppedReplay, "a corrupt floor file fails closed (now), it must not mean no history")
        #expect(st.floor(workspace: a.id) == nowMs, "and is rewritten")
    }
    @Test func corruptStateAfterFutureTs() throws {
        let dir = tmp()
        let p = q("q1", nowMs + 250_000)
        #expect(handler(dir: dir, [a.id: material(a)]).handle(o: p).outcome == .shown)
        try Data("x".utf8).write(to: ReplayStore(pushDir: dir, realm: "live").fileURL(workspace: a.id, generation: 1))
        let h = handler(dir: dir, [a.id: material(a)], at: nowMs + 10_000)
        let r1 = h.handle(o: p).outcome, r2 = h.handle(o: p).outcome
        print("SEC R2b corrupt then replay future-ts: \(r1) \(r2)")
        #expect(r1 == .droppedReplay && r2 == .droppedReplay)
    }
    @Test func finalizeAfterClosure() {
        let dir = tmp()
        let h = handler(dir: dir, [a.id: material(a)])
        let r = h.handle(o: q("q9", nowMs - 5000))
        _ = h.handle(o: q("q9", nowMs - 1000, kind: "question.closed"))
        #expect(h.finalize(r) == .generic)
    }
}
