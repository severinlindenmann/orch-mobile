import Foundation
import Testing
import OrchCoordination
import UniformTypeIdentifiers
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

    @Test func indexLoadUsesOneDeadlineForAllTargets() throws {
        let base = tmp(); let area = ShareArea(shareGroupRoot: base, lockTimeout: 0.4)
        try ShareTargetIndex.publish([target(), target(WS2), target(String(repeating: "c", count: 32)), target(String(repeating: "d", count: 32))], to: area)
        let start = Date()
        try heldLock(area) { _ = try? ShareTargetIndex.load(from: area) }
        #expect(Date().timeIntervalSince(start) < 1.2)   // four per-target waits would take 1.6 s
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

/// A provider that never calls back must not hold the "saving" state forever; Cancel ends it at once.
struct StuckProviderTests {
    private func stuck() -> NSItemProvider {
        let p = NSItemProvider()
        p.registerItem(forTypeIdentifier: UTType.plainText.identifier) { _, _, _ in /* never calls back */ }
        return p
    }

    @Test @MainActor func deadlineEndsAStuckLoad() async throws {
        let session = try StagingSession(area: ShareArea(shareGroupRoot: tmp()), target: target())
        let provider = stuck()
        do {
            try await ProviderStager.$loadDeadline.withValue(0.3) { try await ProviderStager.stage(provider, into: session) }
            Issue.record("expected a timeout")
        } catch let e as ShareError {
            #expect(e == .io("provider timeout"))
        }
        #expect(session.itemCount == 0)
    }

    @Test @MainActor func cancellationEndsAStuckLoadQuickly() async throws {
        let session = try StagingSession(area: ShareArea(shareGroupRoot: tmp()), target: target())
        let provider = stuck()
        let task = Task { @MainActor in
            try await ProviderStager.$loadDeadline.withValue(30) { try await ProviderStager.stage(provider, into: session) }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        task.cancel()
        do { try await task.value; Issue.record("expected cancellation") } catch is CancellationError {}
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test @MainActor func alreadyCancelledTaskDoesNotStart() async throws {
        let session = try StagingSession(area: ShareArea(shareGroupRoot: tmp()), target: target())
        let provider = stuck()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await ProviderStager.stage(provider, into: session)
        }
        do { try await task.value; Issue.record("expected cancellation") } catch is CancellationError {}
    }
}
