import Foundation
import Testing
@testable import OrchStore

/// Security-review cases; confirmed bugs assert the fixed behaviour.
@Suite struct AdversarialStore {
    @Test func nulDoesNotCollide() async throws {
        let l = try makeLayout(tempDir())
        let c = try await WorkspaceContainer(index: try await WorkspaceIndex(layout: l), ws: A, generation: 1)
        _ = try await c.recordRequestId("req\u{0}A")
        #expect(try await c.hasRequestId("req\u{0}B") == false)
        #expect(try await c.hasRequestId("req\u{0}A"))
        #expect(try await c.hasRequestId("req") == false)
        let n = try await c.database().query("SELECT id, length(CAST(id AS BLOB)) AS n FROM request_ids")
        #expect(n.first?.int("n") == 5)
    }

    @Test func multiStatementIsRejectedAndNotRecorded() async throws {
        let db = try SQLiteDatabase(url: tempDir().appendingPathComponent("m.sqlite"))
        await #expect(throws: SQLiteError.self) {
            try await db.migrate([Migration(version: 1, statements: ["CREATE TABLE a(x); CREATE TABLE b(x)"])])
        }
        #expect(try await db.appliedMigrations().isEmpty)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE name IN ('a','b')").isEmpty)
        await #expect(throws: SQLiteError.misuse("multiple statements in one call are not allowed")) { try await db.execute("SELECT 1; SELECT 2") }
        _ = try await db.query("SELECT 1;  \n")  // trailing whitespace/semicolon is fine
    }

    @Test func schemaNewerThanBinaryIsRefused() async throws {
        let db = try SQLiteDatabase(url: tempDir().appendingPathComponent("n.sqlite"))
        try await db.migrate([Migration(version: 1, statements: ["CREATE TABLE a(x)"]), Migration(version: 2, statements: ["CREATE TABLE b(x)"])])
        await #expect(throws: SQLiteError.schemaTooNew(found: 2, known: 1)) {
            try await db.migrate([Migration(version: 1, statements: ["CREATE TABLE a(x)"])])
        }
    }

    @Test func injectionViaValues() async throws {
        let base = tempDir(); let l = try makeLayout(base)
        let idx = try await WorkspaceIndex(layout: l)
        try await idx.setOrder(["x' OR 1=1 --"])
        await #expect(throws: (any Error).self) { try await idx.addWorkspace(ws: "a'--", generation: 1) }
        #expect(throws: (any Error).self) { _ = try StoreLayout(appRoot: base, pushGroupRoot: base, shareGroupRoot: base, realm: "../live") }
        #expect(throws: (any Error).self) { try StoreLayout.validate(ws: "../ab") }
        #expect(throws: (any Error).self) { try StoreLayout.validate(ws: "AB") }
        #expect(throws: (any Error).self) { try StoreLayout.validate(ws: "ab") }  // not 32 hex
        #expect(throws: (any Error).self) { try StoreLayout.validate(ws: String(repeating: "A", count: 32)) }
        try StoreLayout.validate(ws: String(repeating: "0f", count: 16))
    }

    @Test func corruptCoordinationIsFailClosedAndPartialWriteLeavesItUntouched() async throws {
        let l = try makeLayout(tempDir())
        try l.prepareRealm()
        let t = l.tombstones
        try t.write(TombstoneRecord(realm: "live", ws: A, generation: 5))
        let bad = l.pushDir.appendingPathComponent("tombstones.json")
        try Data("{garbage".utf8).write(to: bad)
        try FileManager.default.removeItem(at: l.shareDir.appendingPathComponent("tombstones.json"))
        #expect(t.isRemovedFailClosed(realm: "live", ws: A, generation: 5))
        #expect(l.pushCoordination.isRemovedFailClosed(realm: "live", ws: B, generation: 1))  // unreadable => removed
        #expect(throws: TombstoneError.corrupt(file: bad.path)) { try t.write(TombstoneRecord(realm: "live", ws: B, generation: 1)) }
        #expect(try Data(contentsOf: bad) == Data("{garbage".utf8))  // untouched, still failing closed
        #expect(l.pushCoordination.isRemovedFailClosed(realm: "live", ws: B, generation: 1))
    }

    @Test func corruptFileNeverLeavesAWindowDuringWipe() async throws {
        let l = try makeLayout(tempDir())
        let idx = try await WorkspaceIndex(layout: l)
        try await idx.addWorkspace(ws: A, generation: 5)
        try await idx.addWorkspace(ws: B, generation: 1)
        try await LocalWipe(index: idx).wipe(ws: A, generation: 5)
        let share = l.shareDir.appendingPathComponent("tombstones.json")
        try Data("{bad".utf8).write(to: share)
        #expect(l.shareCoordination.isRemovedFailClosed(realm: "live", ws: A, generation: 5))
        try await LocalWipe(index: idx).wipe(ws: B, generation: 1)
        // Repaired in one atomic replace: earlier and new tombstones both present, bad copy kept for diagnosis.
        for dir in l.tombstoneDirectories {
            let ext = TombstoneCoordination(directories: [dir])
            #expect(ext.isRemovedFailClosed(realm: "live", ws: A, generation: 5))
            #expect(ext.isRemovedFailClosed(realm: "live", ws: B, generation: 1))
            #expect(ext.records().count == 2)
        }
        let siblings = try FileManager.default.contentsOfDirectory(atPath: l.shareDir.path)
        #expect(siblings.contains { $0.hasPrefix("tombstones.json.corrupt-") })
        #expect(try l.shareCoordination.ifNotRemoved(realm: "live", ws: A, generation: 5) { true } == nil)
    }

    @Test func republishAtLaunchRepairsCorruptFileWithNoPendingWipe() async throws {
        let l = try makeLayout(tempDir())
        let idx = try await WorkspaceIndex(layout: l)
        try await idx.addWorkspace(ws: A, generation: 1)
        try await idx.addWorkspace(ws: B, generation: 1)
        try await LocalWipe(index: idx).wipe(ws: B, generation: 1)
        try Data("{bad".utf8).write(to: l.shareDir.appendingPathComponent("tombstones.json"))
        await #expect(throws: StoreError.self) { _ = try await WorkspaceContainer(index: idx, ws: A, generation: 1) }  // blocked, fail-closed
        try await idx.republishTombstones()
        let c = try await WorkspaceContainer(index: idx, ws: A, generation: 1)
        _ = try await c.recordRequestId("ok")
        await #expect(throws: StoreError.self) { _ = try await WorkspaceContainer(index: idx, ws: B, generation: 1) }
        #expect(l.shareCoordination.isRemovedFailClosed(realm: "live", ws: B, generation: 1))
    }

    @Test func layoutKeepsAppGroupsDisjointFromSQLiteRoot() throws {
        let base = tempDir()
        let app = base.appendingPathComponent("app")
        #expect(throws: LayoutError.overlappingRoots) {
            _ = try StoreLayout(appRoot: app, pushGroupRoot: app.appendingPathComponent("grp"), shareGroupRoot: base.appendingPathComponent("s"), realm: "live")
        }
        #expect(throws: LayoutError.overlappingRoots) {
            _ = try StoreLayout(appRoot: app, pushGroupRoot: base.appendingPathComponent("p"), shareGroupRoot: base.appendingPathComponent("p"), realm: "live")
        }
        let l = try makeLayout(base)
        for db in [l.indexURL, try l.wsDatabaseURL(A)] {
            #expect(!db.path.hasPrefix(l.pushGroupRoot.path) && !db.path.hasPrefix(l.shareGroupRoot.path))
        }
    }

    @Test func missingParentAndSymlinkedDbRefused() throws {
        let base = tempDir()
        let real = base.appendingPathComponent("real"); try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("x.sqlite"), withDestinationURL: real.appendingPathComponent("t.sqlite"))
        #expect(throws: SQLiteError.self) { _ = try SQLiteDatabase(url: base.appendingPathComponent("x.sqlite")) }
        #expect(!FileManager.default.fileExists(atPath: real.appendingPathComponent("t.sqlite").path))
        #expect(throws: SQLiteError.self) { _ = try SQLiteDatabase(url: base.appendingPathComponent("nope/y.sqlite")) }
        _ = try SQLiteDatabase(url: base.appendingPathComponent("ok.sqlite"))
    }

    @Test func containerHonoursIndexOnlyTombstone() async throws {
        let l = try makeLayout(tempDir())
        let idx = try await WorkspaceIndex(layout: l)
        try await idx.addWorkspace(ws: C, generation: 2)
        try await LocalWipe(index: idx).wipe(ws: C, generation: 2)
        for d in l.tombstoneDirectories { try? FileManager.default.removeItem(at: d.appendingPathComponent("tombstones.json")) }
        await #expect(throws: StoreError.workspaceRemoved(ws: C, generation: 2)) { _ = try await WorkspaceContainer(index: idx, ws: C, generation: 2) }
        #expect(!FileManager.default.fileExists(atPath: try l.wsDir(C).path))
    }

    @Test func containerHonoursCorruptCoordinationFailClosed() async throws {
        let l = try makeLayout(tempDir())
        let idx = try await WorkspaceIndex(layout: l)
        try l.prepareRealm()
        try Data("{garbage".utf8).write(to: l.pushDir.appendingPathComponent("tombstones.json"))
        await #expect(throws: StoreError.self) { _ = try await WorkspaceContainer(index: idx, ws: D, generation: 1) }
    }

    @Test func staleGenerationWipeCoversCurrent() async throws {
        let l = try makeLayout(tempDir())
        let idx = try await WorkspaceIndex(layout: l)
        try await idx.addWorkspace(ws: D, generation: 7)
        try await LocalWipe(index: idx).wipe(ws: D, generation: 3)
        #expect(try await idx.tombstones().map(\.record.generation) == [7])
        #expect(l.tombstones.isRemovedFailClosed(realm: "live", ws: D, generation: 7))
        await #expect(throws: StoreError.self) { _ = try await WorkspaceContainer(index: idx, ws: D, generation: 7) }
    }

    @Test func lockSymlinkNotFollowed() async throws {
        let base = tempDir(); let l = try makeLayout(base)
        try l.prepareRealm()
        let victim = base.appendingPathComponent("victim-created")
        try FileManager.default.createSymbolicLink(at: l.shareDir.appendingPathComponent("tombstones.lock"), withDestinationURL: victim)
        #expect(l.shareCoordination.isRemovedFailClosed(realm: "live", ws: A, generation: 1))  // lock failure => closed
        #expect(!FileManager.default.fileExists(atPath: victim.path))
        #expect(throws: TombstoneError.self) { try l.shareCoordination.write(TombstoneRecord(realm: "live", ws: A, generation: 1)) }
        #expect(!FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func databaseSymlinkNotFollowed() async throws {
        let base = tempDir()
        let real = base.appendingPathComponent("real.sqlite")
        _ = try SQLiteDatabase(url: real)
        let link = base.appendingPathComponent("link.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: SQLiteError.self) { _ = try SQLiteDatabase(url: link) }
    }

    @Test func readersDoNotCreateDirectories() {
        let dir = tempDir().appendingPathComponent("missing", isDirectory: true)
        let c = TombstoneCoordination(directories: [dir])
        #expect(!c.isRemovedFailClosed(realm: "live", ws: A, generation: 1))
        #expect(c.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func stagingSymlinkNotFollowedOnWipe() async throws {
        let base = tempDir(); let l = try makeLayout(base)
        let idx = try await WorkspaceIndex(layout: l)
        let outside = base.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([1]).write(to: outside.appendingPathComponent("keep"))
        let st = try l.stagedJobsDir(E)
        try FileManager.default.createDirectory(at: st.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: st, withDestinationURL: outside)
        try await LocalWipe(index: idx).wipe(ws: E, generation: 1)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: st.path)) == nil)
    }

    @Test func concurrentAddAndWipeNeverLeavesRow() async throws {
        for _ in 0..<10 {
            let l = try makeLayout(tempDir())
            let idx = try await WorkspaceIndex(layout: l)
            await withTaskGroup(of: Void.self) { g in
                g.addTask { try? await idx.addWorkspace(ws: F, generation: 1) }
                g.addTask { try? await LocalWipe(index: idx).wipe(ws: F, generation: 1) }
            }
            #expect(try await idx.workspaces().isEmpty)
            #expect(try await idx.isRemoved(ws: F, generation: 1))
        }
    }

    @Test func wipeWhileContainerOpen() async throws {
        let l = try makeLayout(tempDir())
        let idx = try await WorkspaceIndex(layout: l)
        try await idx.addWorkspace(ws: A, generation: 1)
        let c = try await WorkspaceContainer(index: idx, ws: A, generation: 1)
        _ = try await c.recordRequestId("r")
        try await LocalWipe(index: idx).wipe(ws: A, generation: 1)
        await #expect(throws: StoreError.suspended) { try await c.hasRequestId("r") }
        await #expect(throws: StoreError.self) { try await c.resume() }
        for f in StoreLayout.sqliteFiles(try l.wsDatabaseURL(A)) { #expect(!FileManager.default.fileExists(atPath: f.path)) }
        #expect(!FileManager.default.fileExists(atPath: try l.wsDir(A).path))
    }

    @Test func suspendDuringResumeDoesNotResurrect() async throws {
        let l = try makeLayout(tempDir())
        let c = try await WorkspaceContainer(index: try await WorkspaceIndex(layout: l), ws: A, generation: 1)
        await c.suspend()
        async let r: Void = c.resume()
        await c.suspend()
        _ = try? await r
        // Whatever the interleaving, state is consistent: suspended => no handle.
        if await c.isSuspended { await #expect(throws: StoreError.suspended) { try await c.database() } }
        try await c.resume()
        #expect(try await c.hasRequestId("x") == false)
    }

    @Test func wipePurgesPushState() async throws {
        let l = try makeLayout(tempDir())
        let idx = try await WorkspaceIndex(layout: l)
        let s = try l.pushStateDir(A)
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: s.appendingPathComponent("replay"))
        try await LocalWipe(index: idx).wipe(ws: A, generation: 1)
        #expect(!FileManager.default.fileExists(atPath: s.path))
    }

    @Test func resumeContinuesPastFailingWorkspace() async throws {
        struct Boom: Error {}
        struct Hooks: WipeHooks {
            func purgeSecrets(realm: String, ws: String) async throws { if ws == A { throw Boom() } }
        }
        let l = try makeLayout(tempDir())
        let idx = try await WorkspaceIndex(layout: l)
        _ = try? await LocalWipe(index: idx, hooks: Hooks()).wipe(ws: A, generation: 1)
        try await idx.recordTombstone(ws: B, generation: 1)
        await #expect(throws: WipeError.self) { try await LocalWipe(index: idx, hooks: Hooks()).resumePendingWipes() }
        let phases = Dictionary(uniqueKeysWithValues: try await idx.tombstones().map { ($0.record.ws, $0.phase) })
        #expect(phases[B] == 4)
        #expect(phases[A] == 2)
    }

    @Test func ifNotRemovedHoldsLockAgainstWriter() throws {
        let l = try makeLayout(tempDir())
        try l.prepareRealm()
        let ext = l.shareCoordination
        let app = l.tombstones
        let started = DispatchSemaphore(value: 0)
        let events = Locked<[String]>([])
        let writer = Thread {
            started.wait()
            try? app.write(TombstoneRecord(realm: "live", ws: A, generation: 1))
            events.mutate { $0.append("write-done") }
        }
        writer.start()
        let result = try ext.ifNotRemoved(realm: "live", ws: A, generation: 1) { () -> Int in
            started.signal()
            Thread.sleep(forTimeInterval: 0.4)
            events.mutate { $0.append("body-done") }
            return 42
        }
        #expect(result == 42)
        for _ in 0..<100 where events.value.count < 2 { usleep(50_000) }
        #expect(events.value == ["body-done", "write-done"])
        #expect(try ext.ifNotRemoved(realm: "live", ws: A, generation: 1) { 1 } == nil)
    }

    @Test func republishBlocksUnderSharedLockAndLockInodeIsStable() throws {
        let l = try makeLayout(tempDir())
        try l.prepareRealm()
        let ext = l.shareCoordination
        let lockPath = l.shareDir.appendingPathComponent("tombstones.lock").path
        _ = try ext.ifNotRemoved(realm: "live", ws: B, generation: 1) { 0 }
        let inode1 = (try FileManager.default.attributesOfItem(atPath: lockPath)[.systemFileNumber] as! NSNumber).intValue
        let started = DispatchSemaphore(value: 0)
        let events = Locked<[String]>([])
        let app = l.tombstones
        let t = Thread {
            started.wait()
            try? app.republish(complete: [TombstoneRecord(realm: "live", ws: A, generation: 1)])
            events.mutate { $0.append("republish-done") }
        }
        t.start()
        _ = try ext.ifNotRemoved(realm: "live", ws: A, generation: 1) { () -> Int in
            started.signal(); usleep(300_000); events.mutate { $0.append("body-done") }; return 1
        }
        for _ in 0..<100 where events.value.count < 2 { usleep(50_000) }
        #expect(events.value == ["body-done", "republish-done"])
        let inode2 = (try FileManager.default.attributesOfItem(atPath: lockPath)[.systemFileNumber] as! NSNumber).intValue
        #expect(inode1 == inode2)  // the lock file is never replaced; only the data file is renamed over
    }

    @Test func readersNeverSeeATornOrMissingFileDuringRepublish() async throws {
        let l = try makeLayout(tempDir())
        try l.prepareRealm()
        let app = l.tombstones
        let ext = l.shareCoordination
        let stop = Locked(false)
        let misses = Locked(0)
        let writer = Thread {
            var i: Int64 = 0
            while !stop.value {
                i += 1
                try? app.republish(complete: [TombstoneRecord(realm: "live", ws: A, generation: i)])
            }
        }
        writer.start()
        for _ in 0..<300 {
            // B is never removed: a nil here would mean the reader saw a missing/unreadable file.
            if (try? ext.ifNotRemoved(realm: "live", ws: B, generation: 1) { true }) != true { misses.mutate { $0 += 1 } }
        }
        stop.mutate { $0 = true }
        #expect(misses.value == 0)
    }

    @Test func concurrentOpenAndWipeLeavesNoFiles() async throws {
        for _ in 0..<15 {
            let l = try makeLayout(tempDir())
            let idx = try await WorkspaceIndex(layout: l)
            try await idx.addWorkspace(ws: A, generation: 1)
            await withTaskGroup(of: Void.self) { g in
                g.addTask { _ = try? await WorkspaceContainer(index: idx, ws: A, generation: 1) }
                g.addTask { try? await LocalWipe(index: idx).wipe(ws: A, generation: 1) }
            }
            #expect(!FileManager.default.fileExists(atPath: try l.wsDir(A).path))
            #expect(try await idx.isRemoved(ws: A, generation: 1))
        }
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; f(&v) }
}
