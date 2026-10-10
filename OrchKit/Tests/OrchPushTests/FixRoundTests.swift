import Foundation
import OrchCoordination
import OrchProtocol
import OrchPushFixtures
import Testing
@testable import OrchPush

/// Fix round for PR #22: removal across the handoff, ordering, expiry interleavings, floor seeding.
final class BlockingSource: PushMaterialSource, @unchecked Sendable {
    let items: [ID16: PushMaterial]
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let block: Bool
    init(_ items: [ID16: PushMaterial], block: Bool) { self.items = items; self.block = block }
    func loadAll(realm: String) throws -> [ID16: PushMaterial] {
        if block { entered.signal(); release.wait() }
        return items
    }
}

final class Delivered: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PushPresentation] = []
    let first = DispatchSemaphore(value: 0)
    func add(_ p: PushPresentation) { lock.withLock { items.append(p) }; first.signal() }
    var all: [PushPresentation] { lock.withLock { items } }
}

struct FixRoundTests {
    let a = PushFixtures.workspaceA
    func q(_ id: String, _ ts: Int64, kind: String = "question", label: String = "x") -> String {
        PushFixtures.seal(a, PushFixtures.payload(kind: kind, id: id, label: label, tsMs: ts))
    }
    func h(_ dir: URL, gen: Int64 = 1) -> PushHandler { handler(dir: dir, [a.id: material(a, generation: gen)]) }

    // MARK: floor seeding (Opus 1 and 3)

    @Test func rejoinSeedsTheNewGenerationAboveWhatWasShown() throws {
        let dir = tmp(), p = q("q1", nowMs - 1000)
        #expect(h(dir).handle(o: p).outcome == .shown)
        // wipe: tombstone, state directory removed (LocalWipe phase 3), then a genuine rejoin at generation 2
        try TombstoneCoordination(directories: [dir]).write(TombstoneRecord(realm: "live", ws: a.id.hex, generation: 1))
        try FileManager.default.removeItem(at: ReplayStore(pushDir: dir, realm: "live").stateDir(workspace: a.id))
        let rejoin = h(dir, gen: 2)
        #expect(rejoin.handle(o: p).outcome == .droppedReplay, "the relay replays a push shown under generation 1")
        #expect(rejoin.handle(o: q("q2", nowMs - 500)).outcome == .shown, "a genuinely newer push is accepted")
        #expect(ReplayStore(pushDir: dir, realm: "live").floor(workspace: a.id) == nowMs - 500)
    }

    @Test func floorOnlyAppliesToNewStateNotWithinAGeneration() {
        // an older id arriving out of order within one generation is still shown (section 9 is per (ws, id))
        let dir = tmp()
        let x = h(dir)
        #expect(x.handle(o: q("late", nowMs)).outcome == .shown)
        #expect(x.handle(o: q("early", nowMs - 5000)).outcome == .shown)
    }

    @Test func wipeTimeFloorCanBeRaisedByTheApp() throws {
        let dir = tmp(), store = ReplayStore(pushDir: dir, realm: "live")
        try store.raiseFloor(workspace: a.id, to: nowMs)
        #expect(h(dir).handle(o: q("q", nowMs - 10)).outcome == .droppedReplay)
        try store.raiseFloor(workspace: a.id, to: nowMs - 100_000)
        #expect(store.floor(workspace: a.id) == nowMs, "monotonic")
    }

    // MARK: removal across the handoff (Codex 2)

    @Test func tombstoneBetweenProcessingAndCompletionDeliversGeneric() throws {
        let dir = tmp()
        let handler = h(dir)
        let r = handler.handle(o: q("q1", nowMs))
        #expect(r.outcome == .shown)
        #expect(handler.finalize(r) == r.presentation, "nothing changed: handed off")
        try TombstoneCoordination(directories: [dir]).write(TombstoneRecord(realm: "live", ws: a.id.hex, generation: 1))
        #expect(handler.finalize(r) == .generic, "wiped between processing and completion")
    }

    @Test func wipeDuringTheDeliveredRemovalStepIsCaught() throws {
        let dir = tmp(), handler = h(dir)
        let out = Delivered()
        let d = PushDelivery(handler: handler, queue: DispatchQueue(label: "t1")) { _, done in
            try? TombstoneCoordination(directories: [dir]).write(TombstoneRecord(realm: "live", ws: PushFixtures.workspaceA.id.hex, generation: 1))
            done()
        }
        _ = handler.handle(o: q("qq", nowMs - 10))   // the question the closure will replace
        d.start(o: q("qq", nowMs, kind: "question.closed", label: "Answered on laptop"), complete: out.add)
        #expect(out.first.wait(timeout: .now() + 5) == .success)
        #expect(out.all == [.generic], "the workspace was wiped while the delivered question was being removed")
    }

    // MARK: ordering (Codex 4)

    @Test func olderQuestionNeverAppearsAfterItsNewerClosureCommitted() {
        let dir = tmp(), x = h(dir)
        let question = x.handle(o: q("qq", nowMs - 20))
        let closure = x.handle(o: q("qq", nowMs - 10, kind: "question.closed", label: "Answered on laptop"))
        #expect(question.outcome == .shown && closure.outcome == .closed)
        // the closure's callback finishes first, the question's (slow) one second
        #expect(x.finalize(closure).style == .closed)
        #expect(x.finalize(question) == .generic, "superseded: a stale question must not show after its closure")
        // the other order is fine
        let y = h(tmp())
        let q2 = y.handle(o: q("qq", nowMs - 20))
        #expect(y.finalize(q2) == q2.presentation)
        let c2 = y.handle(o: q("qq", nowMs - 10, kind: "question.closed"))
        #expect(y.finalize(c2).style == .closed)
    }

    // MARK: expiry (Codex 3, Opus 6)

    @Test func expiryBeatsSlowProcessingAndLaterPresentationIsRejected() {
        let dir = tmp(), src = BlockingSource([a.id: material(a)], block: true)
        let handler = PushHandler(material: src, pushDir: dir, now: { Date(timeIntervalSince1970: Double(nowMs) / 1000) })
        let q = DispatchQueue(label: "t2")
        let out = Delivered()
        let d = PushDelivery(handler: handler, queue: q) { _, done in done() }
        d.start(o: self.q("q1", nowMs), complete: out.add)
        #expect(src.entered.wait(timeout: .now() + 5) == .success)   // processing is stuck inside the keychain read
        d.expire()
        #expect(out.all == [.generic], "the deadline completes at once with generic text, without waiting for processing")
        src.release.signal()
        q.sync {}
        #expect(out.all == [.generic], "completion consumed exactly once; the late presentation is rejected")
        #expect(NSEMarker.read(pushDir: dir)?.outcome != nil)
    }

    @Test func expiryAfterNormalCompletionIsANoOp() {
        let dir = tmp(), q = DispatchQueue(label: "t3")
        let out = Delivered()
        let d = PushDelivery(handler: h(dir), queue: q) { _, done in done() }
        d.start(o: self.q("q1", nowMs), complete: out.add)
        #expect(out.first.wait(timeout: .now() + 5) == .success)
        let before = NSEMarker.read(pushDir: dir)
        d.expire()
        #expect(out.all.count == 1 && out.all[0].style == .event)
        #expect(NSEMarker.read(pushDir: dir) == before, "no expired marker when the time limit did not win")
    }

    @Test func expiryBeforeInstallStillCompletesOnceWithGeneric() {
        let gate = CompletionGate<String> { $0 ? "generic" : "content" }
        gate.finish(expiring: true)
        var got: [String] = []
        gate.install { got.append($0) }
        gate.finish()
        #expect(got == ["generic"])
    }

    @Test func expiryMarkerNeverWaitsForTheLock() throws {
        let dir = tmp()
        try CoordinationFiles.makeDir(dir)
        let start = Date()
        let r = try CoordinationFiles.withFlock(dir.appendingPathComponent(NSEMarker.lockName).path) {
            NSEMarker.record(.expired, pushDir: dir, nowMs: nowMs, bestEffort: true)
        }
        #expect(r == .some(nil) && Date().timeIntervalSince(start) < 1, "lock held elsewhere: skipped, not waited for")
    }

    @Test func handlerAccessIsSafeUnderConcurrentUse() async {
        let dir = tmp(), x = h(dir)
        let outs = await withTaskGroup(of: NSEMarker.Outcome.self) { g in
            for i in 0..<16 { g.addTask { x.handle(o: q("id\(i)", nowMs - Int64(i))).outcome } }
            var o: [NSEMarker.Outcome] = []
            for await r in g { o.append(r) }
            return o
        }
        #expect(outs.allSatisfy { $0 == .shown })
    }

    // MARK: round 2 (Codex P1 x2, P2)

    @Test func finalizationBlockedOnAHeldLockIsBoundedAndExpiryStillDelivers() throws {
        let dir = tmp(), x = h(dir)
        let r = x.handle(o: q("q1", nowMs))
        let lockPath = dir.appendingPathComponent("tombstones.lock").path
        // 1) the bounded handoff gives up on a held lock and delivers generic
        var got: [PushPresentation] = []
        let start = Date()
        _ = try CoordinationFiles.withFlock(lockPath, exclusive: true) { x.handoff(r, timeout: 0.2) { got.append($0) } }
        #expect(got == [.generic] && Date().timeIntervalSince(start) < 2)
        // 2) full state machine: finalization stuck on the lock, the deadline delivers generic at once, exactly once
        let out = Delivered(), qq = DispatchQueue(label: "t-blocked")
        let d = PushDelivery(handler: x, queue: qq, handoffTimeout: 30) { _, done in done() }
        let release = DispatchSemaphore(value: 0), held = DispatchSemaphore(value: 0)
        let holder = Thread {
            _ = try? CoordinationFiles.withFlock(lockPath, exclusive: true) { held.signal(); release.wait() }
        }
        holder.start()
        held.wait()
        d.start(o: q("q2", nowMs + 1), complete: out.add)   // processing now blocks on the exclusive lock
        Thread.sleep(forTimeInterval: 0.3)
        d.expire()
        #expect(out.all == [.generic], "expiry always delivers: it needs no lock")
        release.signal()
        qq.sync {}
        #expect(out.all == [.generic], "the unblocked normal path finds the completion already consumed")
    }

    @Test func removalCannotCommitBetweenTheCheckAndTheHandoff() throws {
        let dir = tmp(), x = h(dir)
        let r = x.handle(o: q("q1", nowMs))
        let order = OrderLog()
        let writer = Thread {
            Thread.sleep(forTimeInterval: 0.1)   // the wipe tries to commit while the handoff is inside its critical section
            try? TombstoneCoordination(directories: [dir]).write(TombstoneRecord(realm: "live", ws: PushFixtures.workspaceA.id.hex, generation: 1))
            order.add("tombstone committed")
        }
        writer.start()
        x.handoff(r) { p in
            #expect(p == r.presentation)
            Thread.sleep(forTimeInterval: 0.4)
            order.add("handed off")
        }
        while order.all.count < 2 { Thread.sleep(forTimeInterval: 0.05) }
        #expect(order.all == ["handed off", "tombstone committed"], "the wipe waits for the handoff, it cannot slip in between")
    }

    @Test func newerClosureCannotCommitBetweenTheCheckAndTheHandoff() throws {
        let dir = tmp(), x = h(dir)
        let question = x.handle(o: q("qq", nowMs - 20))
        let order = OrderLog()
        let closer = Thread {
            Thread.sleep(forTimeInterval: 0.1)
            _ = x.handle(o: q("qq", nowMs - 10, kind: "question.closed", label: "Answered on laptop"))
            order.add("closure committed")
        }
        closer.start()
        x.handoff(question) { p in
            #expect(p == question.presentation)
            Thread.sleep(forTimeInterval: 0.4)
            order.add("question handed off")
        }
        while order.all.count < 2 { Thread.sleep(forTimeInterval: 0.05) }
        #expect(order.all == ["question handed off", "closure committed"])
    }

    @Test func fullTableRecoversOnceTheWindowMovesOn() {
        var r = PushProcessor.ReplayState()
        let keys: PushProcessor.Keyring = [a.id: material(a).keys]
        for i in 0..<PushProcessor.maxEntriesPerWorkspace {
            let out = PushProcessor.process(outer: Data(q("id\(i)", nowMs + Int64(i)).utf8), keys: keys, replay: r, nowMs: nowMs + 300_000)
            guard case .show = out.result else { Issue.record("id\(i) \(out.result)"); return }
            r = out.replay
        }
        let full = PushProcessor.process(outer: Data(q("overflow", nowMs + 600).utf8), keys: keys, replay: r, nowMs: nowMs + 300_000)
        #expect(full.result == .drop(.capacity))
        // 25 h later every entry is outside the window: a fresh push must show (pruned against the candidate's ts first)
        let later = nowMs + 25 * 3600_000
        let fresh = PushProcessor.process(outer: Data(q("fresh", later).utf8), keys: keys, replay: r, nowMs: later)
        guard case .show = fresh.result else { Issue.record("table stayed full: \(fresh.result)"); return }
        #expect(fresh.replay.replay(for: a.id).lastShown.count == 1)
    }
}

final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}
