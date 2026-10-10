import Foundation
import Testing
@testable import OrchStore

let A = String(repeating: "a", count: 32)
let B = String(repeating: "b", count: 32)
let C = String(repeating: "c", count: 32)
let D = String(repeating: "d", count: 32)
let E = String(repeating: "e", count: 32)
let F = String(repeating: "f", count: 32)

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("orchstore-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func makeLayout(_ base: URL, realm: String = "live") throws -> StoreLayout {
    try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                    shareGroupRoot: base.appendingPathComponent("share"), realm: realm)
}

struct SQLiteTests {
    @Test func migrationsAreAtomic() async throws {
        let dir = tempDir()
        let db = try SQLiteDatabase(url: dir.appendingPathComponent("a.sqlite"))
        try await db.migrate([Migration(version: 1, statements: ["CREATE TABLE a (x INTEGER)"])])
        await #expect(throws: SQLiteError.self) {
            try await db.migrate([
                Migration(version: 1, statements: ["CREATE TABLE a (x INTEGER)"]),
                Migration(version: 2, statements: ["CREATE TABLE b (x INTEGER)", "ALTER TABLE nope ADD COLUMN y"]),
            ])
        }
        #expect(try await db.appliedMigrations() == [1])
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE name='b'").isEmpty)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE name='a'").count == 1)
        // A fixed migration then applies.
        try await db.migrate([Migration(version: 1, statements: []), Migration(version: 2, statements: ["CREATE TABLE b (x INTEGER)"])])
        #expect(try await db.appliedMigrations() == [1, 2])
    }

    @Test func transactionRollsBackOnFailure() async throws {
        let db = try SQLiteDatabase(url: tempDir().appendingPathComponent("t.sqlite"))
        try await db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)")
        await #expect(throws: SQLiteError.self) {
            try await db.transaction { tx in
                try tx.execute("INSERT INTO t(id, v) VALUES (1, 'a')")
                try tx.execute("INSERT INTO t(id, v) VALUES (1, 'dup')")
            }
        }
        #expect(try await db.query("SELECT * FROM t").isEmpty)
        // Connection is still usable afterwards.
        try await db.execute("INSERT INTO t(id, v) VALUES (2, 'ok')")
        #expect(try await db.query("SELECT v FROM t").count == 1)
    }

    @Test func bindingLifetimeAndColumnCopy() async throws {
        let db = try SQLiteDatabase(url: tempDir().appendingPathComponent("b.sqlite"))
        try await db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, s TEXT, b BLOB)")
        for i in 0..<50 {
            // Temporaries die right after the call; TRANSIENT must have copied them.
            try await db.execute("INSERT INTO t(id, s, b) VALUES (?,?,?)",
                                 [.int(Int64(i)), .text(String(repeating: "é\(i)", count: 100)), .blob(Data((0..<300).map { UInt8(($0 + i) % 256) }))])
        }
        let rows = try await db.query("SELECT id, s, b FROM t ORDER BY id")
        #expect(rows.count == 50)
        // Rows are read after the statement was finalized; all must be intact and distinct.
        for (i, r) in rows.enumerated() {
            #expect(r.text("s") == String(repeating: "é\(i)", count: 100))
            #expect(r.blob("b") == Data((0..<300).map { UInt8(($0 + i) % 256) }))
        }
        try await db.execute("INSERT INTO t(id, s, b) VALUES (100, NULL, ?)", [.blob(Data())])
        let r = try await db.query("SELECT s, b FROM t WHERE id=100")[0]
        #expect(r["s"] == .null)
        #expect(r["b"] == .blob(Data()))
    }

    @Test func constraintErrorMapping() async throws {
        let db = try SQLiteDatabase(url: tempDir().appendingPathComponent("c.sqlite"))
        try await db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        try await db.execute("INSERT INTO t VALUES (1)")
        do { try await db.execute("INSERT INTO t VALUES (1)"); Issue.record("expected throw") }
        catch let SQLiteError.constraint(code, _) { #expect(code & 0xFF == 19) }
        await #expect(throws: SQLiteError.self) { try await db.query("SELECT * FROM missing") }
        await #expect(throws: SQLiteError.misuse("expected 1 parameters, got 0")) { try await db.execute("INSERT INTO t VALUES (?)") }
    }

    @Test func diskFullMapsAndRollsBack() async throws {
        let db = try SQLiteDatabase(url: tempDir().appendingPathComponent("d.sqlite"))
        try await db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, b BLOB)")
        let pages = try await db.query("PRAGMA page_count")[0][0]
        guard case .int(let n) = pages else { Issue.record("page_count"); return }
        try await db.execute("PRAGMA max_page_count=\(n + 4)")
        do {
            try await db.transaction { tx in
                for i in 0..<100 { try tx.execute("INSERT INTO t(id, b) VALUES (?,?)", [.int(Int64(i)), .blob(Data(count: 4000))]) }
            }
            Issue.record("expected disk full")
        } catch SQLiteError.diskFull {} 
        #expect(try await db.query("SELECT count(*) FROM t")[0][0] == .int(0))
    }

    @Test func closedDatabaseThrows() async throws {
        let db = try SQLiteDatabase(url: tempDir().appendingPathComponent("x.sqlite"))
        await db.close()
        await #expect(throws: SQLiteError.closed) { try await db.query("SELECT 1") }
    }

    @Test func walModeOn() async throws {
        let db = try SQLiteDatabase(url: tempDir().appendingPathComponent("w.sqlite"))
        #expect(try await db.query("PRAGMA journal_mode")[0][0] == .text("wal"))
    }
}

struct LayoutAndContainerTests {
    @Test func layoutPaths() throws {
        let base = tempDir()
        let l = try makeLayout(base)
        #expect(l.indexURL.path.hasSuffix("app/orch/live/index.sqlite"))
        #expect(try l.wsDatabaseURL(C).path.hasSuffix("orch/live/ws/\(C)/ws.sqlite"))
        #expect(l.pushDir.path.hasSuffix("push/push"))
        #expect(l.shareDir.path.hasSuffix("share/share"))
        #expect(throws: LayoutError.self) { try l.wsDir("../x") }
        #expect(throws: LayoutError.self) { try StoreLayout(appRoot: base, pushGroupRoot: base, shareGroupRoot: base, realm: "../x") }
        try l.prepareWorkspace(C)
        var excluded = try l.wsDir(C).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
        excluded = try l.realmDir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
    }

    @Test func durabilityAcrossReopen() async throws {
        let l = try makeLayout(tempDir())
        let i1 = try await WorkspaceIndex(layout: l)
        let c = try await WorkspaceContainer(index: i1, ws: A, generation: 1)
        #expect(try await c.recordRequestId("req-1") == true)
        #expect(try await c.recordRequestId("req-1") == false)
        try await c.raiseEpochHighWater(7)
        // "Crash": drop the container without close(); reopen from disk.
        let c2 = try await WorkspaceContainer(index: try await WorkspaceIndex(layout: l), ws: A, generation: 1)
        #expect(try await c2.hasRequestId("req-1"))
        #expect(try await c2.epochHighWater() == 7)
        #expect(try await c2.raiseEpochHighWater(3) == 7)  // never lowers
        #expect(try await c2.raiseEpochHighWater(9) == 9)
    }

    @Test func suspendAndResume() async throws {
        let l = try makeLayout(tempDir())
        let c = try await WorkspaceContainer(index: try await WorkspaceIndex(layout: l), ws: A, generation: 1)
        _ = try await c.recordRequestId("r")
        await c.suspend()
        await #expect(throws: StoreError.suspended) { try await c.hasRequestId("r") }
        try await c.resume()
        #expect(try await c.hasRequestId("r"))
    }

    @Test func realmIsolation() async throws {
        let base = tempDir()
        let live = try makeLayout(base, realm: "live")
        let demo = try makeLayout(base, realm: "demo")
        let li = try await WorkspaceIndex(layout: live)
        try await li.addWorkspace(ws: A, generation: 1)
        let di = try await WorkspaceIndex(layout: demo)
        #expect(try await di.workspaces().isEmpty)
        #expect(live.indexURL != demo.indexURL)
        // Wiping in demo leaves live untouched.
        try await LocalWipe(index: di).wipe(ws: A, generation: 1)
        #expect(try await li.workspaces().count == 1)
        // Tombstones are keyed by realm: the live realm is not affected by the demo tombstone.
        #expect(live.tombstones.isRemovedFailClosed(realm: "live", ws: A, generation: 1) == false)
        #expect(live.tombstones.isRemovedFailClosed(realm: "demo", ws: A, generation: 1))
        // An index file of another realm is refused.
        try? FileManager.default.removeItem(at: demo.indexURL)
        let wrong = try makeLayout(base, realm: "other")
        try FileManager.default.createDirectory(at: wrong.realmDir, withIntermediateDirectories: true)
        await li.close()  // checkpoints the WAL so the copied main file carries the realm row
        try FileManager.default.copyItem(at: live.indexURL, to: wrong.indexURL)
        await #expect(throws: StoreError.self) { _ = try await WorkspaceIndex(layout: wrong) }
    }

    @Test func orderAndStaleRejoin() async throws {
        let l = try makeLayout(tempDir())
        let i = try await WorkspaceIndex(layout: l)
        try await i.addWorkspace(ws: A, generation: 1)
        try await i.addWorkspace(ws: B, generation: 1)
        try await i.setOrder([B, A])
        #expect(try await i.workspaces().map(\.ws) == [B, A])
        try await LocalWipe(index: i).wipe(ws: A, generation: 1)
        await #expect(throws: StoreError.workspaceRemoved(ws: A, generation: 1)) { try await i.addWorkspace(ws: A, generation: 1) }
        try await i.addWorkspace(ws: A, generation: 2)  // genuine rejoin with a newer generation
        await #expect(throws: StoreError.self) { _ = try await WorkspaceContainer(index: i, ws: A, generation: 1) }
    }
}

struct WipeTests {
    struct Crash: Error {}

    func populate(_ l: StoreLayout, _ ws: String) async throws -> WorkspaceIndex {
        let idx = try await WorkspaceIndex(layout: l)
        try await idx.addWorkspace(ws: ws, generation: 1)
        let c = try await WorkspaceContainer(index: idx, ws: ws, generation: 1)
        _ = try await c.recordRequestId("r")  // leaves -wal/-shm while open
        try Data("plain".utf8).write(to: l.filesDir(ws).appendingPathComponent("p.txt"))
        let staged = try l.stagedJobsDir(ws)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("job".utf8).write(to: staged.appendingPathComponent("job1"))
        return idx
    }

    func assertWiped(_ l: StoreLayout, _ ws: String) throws {
        let fm = FileManager.default
        for f in StoreLayout.sqliteFiles(try l.wsDatabaseURL(ws)) { #expect(!fm.fileExists(atPath: f.path)) }
        #expect(!fm.fileExists(atPath: try l.wsDir(ws).path))
        #expect(!fm.fileExists(atPath: try l.stagedJobsDir(ws).path))
    }

    @Test func wipeDeletesEverythingIncludingSidecars() async throws {
        let l = try makeLayout(tempDir())
        let idx = try await populate(l, A)
        let db = try l.wsDatabaseURL(A)
        #expect(FileManager.default.fileExists(atPath: db.path + "-wal"))
        try await LocalWipe(index: idx).wipe(ws: A, generation: 1)
        try assertWiped(l, A)
        #expect(try await idx.workspaces().isEmpty)
        #expect(try await idx.tombstones().first?.phase == 4)
    }

    @Test func tombstoneVisibleFromCoordinationFiles() async throws {
        let l = try makeLayout(tempDir())
        let idx = try await populate(l, A)
        try await LocalWipe(index: idx).wipe(ws: A, generation: 1)
        // Extension view: only one group root, no sqlite.
        for dir in l.tombstoneDirectories {
            let ext = TombstoneCoordination(directories: [dir])
            #expect(ext.isRemovedFailClosed(realm: "live", ws: A, generation: 1))
            #expect(ext.isRemovedFailClosed(realm: "live", ws: A, generation: 0))
            #expect(!ext.isRemovedFailClosed(realm: "live", ws: A, generation: 2))
            #expect(!ext.isRemovedFailClosed(realm: "demo", ws: A, generation: 1))
            #expect(!ext.isRemovedFailClosed(realm: "live", ws: B, generation: 1))
        }
    }

    @Test func wipeIsIdempotent() async throws {
        let l = try makeLayout(tempDir())
        let idx = try await populate(l, A)
        let w = LocalWipe(index: idx)
        try await w.wipe(ws: A, generation: 1)
        try await w.wipe(ws: A, generation: 1)
        try await w.cleanupPass(ws: A)
        try assertWiped(l, A)
        #expect(l.tombstones.records().count == 1)
        #expect(try await idx.tombstones().count == 1)
        #expect(try await w.resumePendingWipes().isEmpty)
    }

    @Test(arguments: [1, 2, 3, 4])
    func crashAfterEachPhaseThenResume(phase: Int) async throws {
        let l = try makeLayout(tempDir())
        let idx = try await populate(l, A)
        let crashing = LocalWipe(index: idx, afterPhase: { if $0 == phase { throw Crash() } })
        await #expect(throws: Crash.self) { try await crashing.wipe(ws: A, generation: 1) }
        // The tombstone is already durable in both coordination files once phase 1 completed.
        #expect(l.tombstones.isRemovedFailClosed(realm: "live", ws: A, generation: 1))
        // "Relaunch": new index handle on the same files, then resume.
        await idx.close()
        let idx2 = try await WorkspaceIndex(layout: l)
        let resumed = try await LocalWipe(index: idx2).resumePendingWipes()
        #expect(resumed == (phase == 4 ? [] : [A]))
        try assertWiped(l, A)
        #expect(try await idx2.tombstones().allSatisfy { $0.phase == 4 })
    }

    @Test func failingHookKeepsWipeResumable() async throws {
        struct Hooks: WipeHooks {
            let fail: Bool
            func purgeSecrets(realm: String, ws: String) async throws { if fail { throw Crash() } }
        }
        let l = try makeLayout(tempDir())
        let idx = try await populate(l, A)
        await #expect(throws: WipeError.self) { try await LocalWipe(index: idx, hooks: Hooks(fail: true)).wipe(ws: A, generation: 1) }
        #expect(try await idx.tombstones().first?.phase == 2)
        // Files were still deleted in that pass; the secrets step retries on resume.
        try await LocalWipe(index: idx, hooks: Hooks(fail: false)).resumePendingWipes()
        #expect(try await idx.tombstones().first?.phase == 4)
        try assertWiped(l, A)
    }

    @Test func concurrentReadersAndWriterOfCoordinationFile() async throws {
        let l = try makeLayout(tempDir())
        let t = l.tombstones
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<20 {
                g.addTask { try? t.write(TombstoneRecord(realm: "live", ws: A, generation: Int64(i))) }
                g.addTask { _ = t.isRemovedFailClosed(realm: "live", ws: A, generation: 5) }
            }
        }
        #expect(t.isRemovedFailClosed(realm: "live", ws: A, generation: 19))
        #expect(t.records().count == 20)
    }
}
