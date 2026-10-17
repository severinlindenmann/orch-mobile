import Foundation
import Testing
import OrchProtocol
@testable import OrchClient
@testable import OrchFakeHost

/// Increment 4: the session keeps the host's `whoami.relay` in memory only, reads it at `startViews` and on foreground, clears it on
/// background and on any failed read (fail closed), and the Live write rule is `ops[kind] == 1 && r6_ready`.
@Suite struct HostWriteSupportFlowTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        var value: Bool { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    private func setup(failWhoami: Flag = Flag()) async throws -> (World, Phone, OpCounter) {
        let w = try await World.make()
        let p = try await w.makePhone()
        let ops = OpCounter()
        let host = w.host
        await w.host.setHandler { req in
            let op = req.meta.object?["op"]?.string ?? "?"
            ops.bump(op)
            if failWhoami.value, op == "whoami" { return .refuse(.host(code: "store.busy", retryable: true, seqs: nil, nextKey: nil)) }
            return await host.handleView(req)
        }
        return (w, p, ops)
    }

    /// Serves the host until the session has asked `whoami` `n` times in all and has had time to apply the answer.
    private func settle(_ w: World, _ p: Phone, _ ops: OpCounter, whoamis n: Int) async throws {
        let s = p.session
        try await w.serve(p, steps: 400) {
            for _ in 0..<20_000 where ops.value("whoami") < n { await Task.yield() }
            for _ in 0..<500 { await Task.yield() }
        }
        _ = s
    }

    @Test func startViewsReadsTheHostSignalIntoMemory() async throws {
        let (w, p, ops) = try await setup()
        #expect(await p.session.currentHostSupport == nil)          // nothing before the first read
        await p.session.startViews()
        try await settle(w, p, ops, whoamis: 1)
        #expect(await p.session.currentHostSupport == HostWriteSupport(ops: ["answer": 1, "approve": 1, "changes": 1, "new_ticket": 1], r6Ready: true))
    }

    @Test(arguments: [FakeRelayCaps.absent, .r6NotReady])
    func noFieldOrR6NotReadyAdmitsNothingLive(_ caps: FakeRelayCaps) async throws {
        let (w, p, ops) = try await setup()
        await w.host.setRelayCaps(caps)
        await p.session.startViews()
        try await settle(w, p, ops, whoamis: 1)
        let got = await p.session.currentHostSupport
        #expect(got?.allows("answer") != true && got?.allows("new_ticket") != true)
        #expect(caps == .absent ? got == nil : got?.r6Ready == false)
    }

    @Test func aFailedReadLeavesNothing() async throws {
        let fail = Flag()
        let (w, p, ops) = try await setup(failWhoami: fail)
        await p.session.startViews()
        try await settle(w, p, ops, whoamis: 1)
        #expect(await p.session.currentHostSupport?.allows("answer") == true)
        fail.value = true                                             // the next refresh fails: the old signal must not survive it
        await p.session.setForeground(false)
        await p.session.setForeground(true)
        try await settle(w, p, ops, whoamis: 2)
        #expect(await p.session.currentHostSupport == nil)
    }

    @Test func backgroundClearsAndForegroundReadsAgain() async throws {
        let (w, p, ops) = try await setup()
        await p.session.startViews()
        try await settle(w, p, ops, whoamis: 1)
        #expect(await p.session.currentHostSupport?.allows("answer") == true)
        await p.session.setForeground(false)
        #expect(await p.session.currentHostSupport == nil)           // cleared at once, not at the next read
        await w.host.setRelayCaps(.r6NotReady)
        await p.session.setForeground(true)
        try await settle(w, p, ops, whoamis: 2)
        #expect(await p.session.currentHostSupport == HostWriteSupport(ops: ["answer": 1, "approve": 1, "changes": 1, "new_ticket": 1], r6Ready: false))
    }

    @Test func theLiveRuleNeedsTheOpAtVersionOneAndR6() {
        let ready = HostWriteSupport(ops: ["answer": 1, "approve": 1, "changes": 1, "new_ticket": 1], r6Ready: true)
        func live(_ s: HostWriteSupport?, _ k: String) -> Bool { WorkspaceSession.hostAdmits(realm: .live, support: s, kind: k) }
        #expect(live(ready, "answer") && live(ready, "new_ticket") && !live(ready, "other"))
        #expect(!live(nil, "answer"))                                                     // fail closed without a signal
        #expect(!live(HostWriteSupport(ops: ["answer": 1], r6Ready: false), "answer"))
        #expect(!live(HostWriteSupport(ops: ["answer": 2], r6Ready: true), "answer"))
        // Demo is unchanged by the signal
        #expect(WorkspaceSession.hostAdmits(realm: .demo, support: nil, kind: "answer"))
        #expect(WorkspaceSession.hostAdmits(realm: .demo, support: nil, kind: "new_ticket"))
        #expect(!WorkspaceSession.hostAdmits(realm: .demo, support: nil, kind: "other"))
    }
}
