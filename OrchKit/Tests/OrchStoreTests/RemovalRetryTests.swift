import Foundation
@testable import OrchCoordination
import Testing
import SQLite3
@testable import OrchStore

@Suite struct RemovalRetryTests {
    @Test(arguments: [false, true])
    func busyLockPreservesContainer(resume: Bool) async throws {
        let layout = try makeLayout(tempDir())
        let index = try await WorkspaceIndex(layout: layout)
        let existing = try await WorkspaceContainer(index: index, ws: A, generation: 1)
        _ = try await existing.recordRequestId("keep")
        await existing.close()
        let sentinel = try layout.wsDir(A).appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        let dir = layout.tombstones.directories[0]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = openCoordinationLock(dir.appendingPathComponent("tombstones.lock").path)
        defer { flock(fd, LOCK_UN); close(fd) }
        #expect(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
        do {
            if resume { try await existing.resume() }
            else { _ = try await WorkspaceContainer(index: index, ws: A, generation: 1) }
            Issue.record("busy removal state must refuse open")
        } catch {
            // String assertion also compiles against the pre-fix StoreError enum.
            #expect(String(describing: error).hasPrefix("removalStateUnknown"))
        }
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        #expect(FileManager.default.fileExists(atPath: try layout.wsDatabaseURL(A).path))
        #expect(await existing.isSuspended)
        do {
            try await index.addWorkspace(ws: A, generation: 1)
            Issue.record("busy removal state must refuse add")
        } catch { #expect(String(describing: error).hasPrefix("removalStateUnknown")) }
        flock(fd, LOCK_UN)
        try await existing.resume()
        #expect(try await existing.hasRequestId("keep"))
        await existing.close()
        // Confirmed removal still authorizes the wipe.
        try await LocalWipe(index: index).wipe(ws: A, generation: 1)
        #expect(!FileManager.default.fileExists(atPath: try layout.wsDir(A).path))
        await #expect(throws: StoreError.workspaceRemoved(ws: A, generation: 1)) {
            try await existing.resume()
        }
    }

    @Test func databaseFailurePreservesContainer() async throws {
        let layout = try makeLayout(tempDir())
        let index = try await WorkspaceIndex(layout: layout)
        let c = try await WorkspaceContainer(index: index, ws: A, generation: 1)
        _ = try await c.recordRequestId("keep")
        await c.close()
        await index.close()
        do {
            try await c.resume()
            Issue.record("closed index must refuse open")
        } catch { #expect(String(describing: error).hasPrefix("removalStateUnknown")) }
        let reopened = try await WorkspaceIndex(layout: layout)
        let retry = try await WorkspaceContainer(index: reopened, ws: A, generation: 1)
        #expect(try await retry.hasRequestId("keep"))
        await retry.close()
    }

    /// SQLite's statement trace lets the test change coordination immediately before the second
    /// index read, after container migration, without adding a production-only test hook.
    private final class SecondRead: @unchecked Sendable {
        let fd: Int32
        let layout: StoreLayout
        let removed: Bool
        var reads = 0
        init(fd: Int32, layout: StoreLayout, removed: Bool) {
            self.fd = fd; self.layout = layout; self.removed = removed
        }
        func hit(_ sql: String) {
            guard sql.hasPrefix("SELECT 1 FROM tombstones WHERE") else { return }
            reads += 1
            guard reads == 2 else { return }
            if removed {
                do { try layout.tombstones.write(TombstoneRecord(realm: layout.realm, ws: A, generation: 1)) }
                catch { Issue.record("could not publish tombstone: \(error)") }
            } else { #expect(flock(fd, LOCK_EX | LOCK_NB) == 0) }
        }
    }

    @Test(arguments: [false, true])
    func secondOpenCheckDeletesOnlyConfirmedRemoval(removed: Bool) async throws {
        let layout = try makeLayout(tempDir())
        let index = try await WorkspaceIndex(layout: layout)
        let old = try await WorkspaceContainer(index: index, ws: A, generation: 1)
        _ = try await old.recordRequestId("keep")
        await old.close()
        let sentinel = try layout.wsDir(A).appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        let dir = layout.tombstones.directories[0]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = openCoordinationLock(dir.appendingPathComponent("tombstones.lock").path)
        defer { flock(fd, LOCK_UN); close(fd) }
        let probe = SecondRead(fd: fd, layout: layout, removed: removed)
        try await index.db.transaction { tx in
            sqlite3_trace_v2(tx.handle.db, UInt32(SQLITE_TRACE_STMT), { _, context, _, sql in
                guard let context, let sql else { return 0 }
                let probe = Unmanaged<SecondRead>.fromOpaque(context).takeUnretainedValue()
                probe.hit(String(cString: sql.assumingMemoryBound(to: CChar.self)))
                return 0
            }, Unmanaged.passUnretained(probe).toOpaque())
        }
        do {
            _ = try await WorkspaceContainer(index: index, ws: A, generation: 1)
            Issue.record("second check must refuse open")
        } catch {
            #expect(String(describing: error).hasPrefix(removed ? "workspaceRemoved" : "removalStateUnknown"))
        }
        try await index.db.transaction { tx in sqlite3_trace_v2(tx.handle.db, 0, nil, nil) }
        #expect(probe.reads == 2)
        #expect(FileManager.default.fileExists(atPath: sentinel.path) == !removed)
        #expect(FileManager.default.fileExists(atPath: try layout.wsDatabaseURL(A).path) == !removed)
        flock(fd, LOCK_UN)
        if !removed {
            let retry = try await WorkspaceContainer(index: index, ws: A, generation: 1)
            #expect(try await retry.hasRequestId("keep"))
            await retry.close()
        }
    }
}
