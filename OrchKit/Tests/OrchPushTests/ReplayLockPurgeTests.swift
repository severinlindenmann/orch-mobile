import Foundation
import OrchCoordination
import OrchProtocol
import OrchPushFixtures
import OrchStore
import Testing
@testable import OrchPush

struct ReplayLockPurgeTests {
    private func waitForSignal(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }

    @Test(arguments: [false, true])
    func holdersStayExclusiveAcrossPurge(cleanupPass: Bool) async throws {
        let root = tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try StoreLayout(appRoot: root.appendingPathComponent("app"),
                                     pushGroupRoot: root.appendingPathComponent("push"),
                                     shareGroupRoot: root.appendingPathComponent("share"), realm: "live")
        let index = try await WorkspaceIndex(layout: layout)
        let ws = PushFixtures.workspaceA.id
        let store = ReplayStore(pushDir: layout.pushDir, realm: "live")
        try await index.addWorkspace(ws: ws.hex, generation: 1)
        try await LocalWipe(index: index).wipe(ws: ws.hex, generation: 1)
        try await index.addWorkspace(ws: ws.hex, generation: 2)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        // Separate opens model independent NSE processes. Barriers fix the ordering without sleeps.
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                try store.transact(workspace: ws, generation: 2, nowMs: nowMs) { _ in
                    entered.signal()
                    release.wait()
                    return ((), nil as PushProcessor.WorkspaceReplay?)
                }
            } catch { Issue.record("first holder failed: \(error)"); entered.signal() }
        }
        await waitForSignal(entered)
        var holderFinished = false
        defer { if !holderFinished { release.signal() } }
        var before = stat()
        #expect(stat(store.lockURL(workspace: ws).path, &before) == 0)
        if cleanupPass {
            await #expect(throws: CoordinationFiles.FileError.io("replay lock busy")) {
                try await LocalWipe(index: index).cleanupPass(ws: ws.hex)
            }
            #expect(FileManager.default.fileExists(atPath: store.stateDir(workspace: ws).path))
        } else {
            // The debug push harness removes this same directory.
            try FileManager.default.removeItem(at: store.stateDir(workspace: ws))
        }
        // Even after a purge and directory recreation, a second NSE must contend on the same inode.
        try FileManager.default.createDirectory(at: store.stateDir(workspace: ws), withIntermediateDirectories: true)
        let second = ReplayStore(pushDir: layout.pushDir, realm: "live")
        #expect(throws: ReplayStoreError.io("lock")) {
            try second.transact(workspace: ws, generation: 2, nowMs: nowMs, lockTimeout: 0) { _ in
                Issue.record("two exclusive holders across purge")
                return ((), nil as PushProcessor.WorkspaceReplay?)
            }
        }
        var after = stat()
        #expect(stat(store.lockURL(workspace: ws).path, &after) == 0)
        #expect(before.st_ino == after.st_ino && before.st_dev == after.st_dev)
        release.signal()
        await waitForSignal(finished)
        holderFinished = true
        if cleanupPass {
            try await LocalWipe(index: index).cleanupPass(ws: ws.hex)
            #expect(!FileManager.default.fileExists(atPath: store.stateDir(workspace: ws).path))
        }
        let next = PushProcessor.WorkspaceReplay().recordingForTest("after-purge", nowMs)
        try second.transact(workspace: ws, generation: 2, nowMs: nowMs, lockTimeout: 0) { _ in ((), next) }
        #expect(try second.load(workspace: ws, generation: 2) == next)
    }
}
