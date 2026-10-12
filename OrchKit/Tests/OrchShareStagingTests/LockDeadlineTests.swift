import Foundation
import Testing
import OrchCoordination
@testable import OrchShareStaging

/// The share extension must never wait forever behind a held tombstone lock (an app-side wipe): it ends in "busy".
struct LockDeadlineTests {
    private func heldLock<T>(_ area: ShareArea, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: area.shareDir, withIntermediateDirectories: true)
        let path = area.shareDir.appendingPathComponent("tombstones.lock").path
        let out = try CoordinationFiles.withFlock(path, exclusive: true, blocking: true) { try body() }
        return try #require(out)
    }

    @Test func stagingAddIsBusyWhenLockHeldAndLeavesNoPartial() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base, lockTimeout: 0.2)
        let s = try StagingSession(area: area, target: target())
        let start = Date()
        try heldLock(area) {
            #expect(throws: ShareError.busy) { try s.add(.text("hi")) }
        }
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(ShareInbox(area: area).peekReady().isEmpty)
        // After the lock is released the same session is finished (cancelled), a fresh one works.
        let s2 = try StagingSession(area: area, target: target())
        try s2.add(.text("ok"))
        _ = try s2.commit(note: nil)
    }

    @Test func commitIsBusyWhenLockHeld() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base, lockTimeout: 0.2)
        let s = try StagingSession(area: area, target: target())
        try s.add(.text("hi"))
        try heldLock(area) {
            #expect(throws: ShareError.busy) { try s.commit(note: nil) }
        }
        #expect(ShareInbox(area: area).peekReady().isEmpty)
    }

    @Test func redirectIsBusyWhenLockHeldAndKeepsOriginal() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base, lockTimeout: 0.2); let inbox = ShareInbox(area: area)
        let s = try StagingSession(area: ShareArea(shareGroupRoot: base), target: target(WS2))
        try s.add(.text("x")); _ = try s.commit(note: nil)
        let q = inbox.claim(live: []).quarantined[0]
        try heldLock(area) {
            #expect(throws: ShareError.busy) { try inbox.redirect(q, to: LiveDestination(realm: "live", ws: WS, generation: 1)) }
        }
        #expect(inbox.quarantined().count == 1)
    }

    @Test func indexLoadFailsWithLockCodeInsteadOfHanging() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base, lockTimeout: 0.2)
        try ShareTargetIndex.publish([target()], to: area)
        try heldLock(area) {
            do { _ = try ShareTargetIndex.load(from: area); Issue.record("expected failure") }
            catch let e as ShareError {
                guard case .index(.tombstones(let code)) = e else { Issue.record("wrong error"); return }
                #expect(code.hasPrefix("lock"))
            }
        }
    }
}
