import Foundation
import OrchCoordination

/// Opens and closes one workspace's `ws.sqlite`. On protected-data loss the app calls `suspend()`
/// (handles closed, operations throw `.suspended`) and `resume()` when data is available again.
/// The index tombstones are consulted on every open, so a wiped generation can never reopen.
public actor WorkspaceContainer {
    public let index: WorkspaceIndex
    public let ws: String
    public let generation: Int64
    private var db: SQLiteDatabase?
    private var suspended = true
    private var lifecycle = 0
    private var opening: Task<Void, Error>?

    static let migrations = [
        Migration(version: 1, statements: [
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)",
            "CREATE TABLE request_ids (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL)",
        ]),
        // Slice 2a: durable bridge requests. A request row (with its exact envelope bytes) is written in the same
        // transaction that allocates its seq, before anything is sent; `meta` also holds next_seq, clock_offset_ms and
        // pin_failures (consecutive: reset by a verified response). `logical` links the attempts of one logical request.
        // `state` is `pending` (can be sent again, byte for byte) or `uncertain` (the outcome is unknowable from the bridge;
        // the row keeps the logical id and the exact signed plaintext until reconciliation resolves it, protocol 8.6/U8).
        Migration(version: 2, statements: [
            """
            CREATE TABLE bridge_requests (
              rid TEXT PRIMARY KEY, logical TEXT NOT NULL, seq INTEGER NOT NULL, epoch INTEGER NOT NULL,
              envelope BLOB NOT NULL, plaintext BLOB NOT NULL, next_idx INTEGER NOT NULL DEFAULT 0,
              stream INTEGER NOT NULL DEFAULT 0, offset_adopted INTEGER NOT NULL DEFAULT 0,
              sent_ms INTEGER NOT NULL, created_ms INTEGER NOT NULL,
              state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','uncertain')))
            """,
            "CREATE INDEX bridge_requests_logical ON bridge_requests(logical)",
        ]),
        Migration(version: 3, statements: [
            "CREATE TABLE bridge_charges (rid TEXT PRIMARY KEY, created_ms INTEGER NOT NULL)",
            "CREATE TABLE decisions (id TEXT PRIMARY KEY, question TEXT NOT NULL, option_id TEXT NOT NULL, review BLOB NOT NULL, operation BLOB NOT NULL, state TEXT NOT NULL DEFAULT 'pending', outcome BLOB)",
        ]),
        Migration(version: 4, statements: [
            // Existing slice-3 envelopes may have been dispatched. Missing envelopes are still refused by reconciliation.
            "ALTER TABLE decisions ADD COLUMN dispatched INTEGER NOT NULL DEFAULT 1",
        ]),
        Migration(version: 5, statements: [
            "CREATE TABLE drop_heads (object TEXT PRIMARY KEY, version INTEGER NOT NULL, hash BLOB NOT NULL)",
            "CREATE TABLE drop_uploads (object TEXT NOT NULL, version INTEGER NOT NULL, body BLOB NOT NULL, done INTEGER NOT NULL, PRIMARY KEY(object,version))",
            "CREATE TABLE drop_imports (job TEXT NOT NULL, item INTEGER NOT NULL, object TEXT NOT NULL, PRIMARY KEY(job,item))",
        ]),
        Migration(version: 6, statements: [
            "ALTER TABLE drop_uploads ADD COLUMN failure TEXT",
        ]),
        Migration(version: 7, statements: [
            "ALTER TABLE drop_uploads ADD COLUMN revision INTEGER NOT NULL DEFAULT 0",
            "CREATE TABLE drop_abandoned (key TEXT PRIMARY KEY)",
        ]),
    ]

    public init(index: WorkspaceIndex, ws: String, generation: Int64) async throws {
        try StoreLayout.validate(ws: ws)
        self.index = index; self.ws = ws; self.generation = generation
        index.containers.register(self)
        try await resume()
    }

    public var layout: StoreLayout { index.layout }
    public var isSuspended: Bool { suspended }

    private func performOpen(_ start: Int) async throws {
        try await index.requireNotRemoved(ws: ws, generation: generation)
        let layout = index.layout
        try layout.prepareWorkspace(ws)
        let d = try SQLiteDatabase(url: layout.wsDatabaseURL(ws))
        do { try await d.migrate(Self.migrations) } catch { await d.close(); throw error }
        // A wipe may have recorded its tombstone after the first check and before our files were created:
        // re-check now that they exist and clean up ourselves (the wipe's purge may already have run).
        switch await index.removalStatus(ws: ws, generation: generation) {
        case .notRemoved: break
        case .unknown:
            await d.close()
            throw StoreError.removalStateUnknown(ws: ws, generation: generation)
        case .removed:
            await d.close()
            for f in StoreLayout.sqliteFiles(try layout.wsDatabaseURL(ws)) { try? FileManager.default.removeItem(at: f) }
            try? FileManager.default.removeItem(at: try layout.wsDir(ws))
            throw StoreError.workspaceRemoved(ws: ws, generation: generation)
        }
        // suspend()/close() may have run while we awaited: do not resurrect a handle. No await between this
        // check and the assignment, so a later wipe's suspendAll() always sees and closes the handle.
        guard start == lifecycle else { await d.close(); throw StoreError.suspended }
        db = d
        suspended = false
    }

    public func suspend() async {
        lifecycle += 1
        suspended = true
        let d = db
        db = nil
        await d?.close()
    }

    public func resume() async throws {
        if !suspended { return }
        if let t = opening { return try await t.value }
        let start = lifecycle
        let t = Task { try await self.performOpen(start) }
        opening = t
        defer { opening = nil }
        try await t.value
    }

    public func close() async { await suspend() }

    /// The raw database for later milestones; throws while suspended.
    public func database() throws -> SQLiteDatabase {
        guard let db, !suspended else { throw StoreError.suspended }
        return db
    }

    /// Durable dedupe of request ids. Returns false when the id was already recorded.
    public func recordRequestId(_ id: String) async throws -> Bool {
        try await database().execute("INSERT OR IGNORE INTO request_ids(id, created_at) VALUES(?,?)",
                                     [.text(id), .int(Int64(Date().timeIntervalSince1970))]) == 1
    }

    public func hasRequestId(_ id: String) async throws -> Bool {
        !(try await database().query("SELECT 1 FROM request_ids WHERE id=?", [.text(id)])).isEmpty
    }

    public func epochHighWater() async throws -> Int64 {
        try await database().query("SELECT value FROM meta WHERE key='epoch_hwm'").first?.int("value") ?? 0
    }

    /// Monotonic: never lowers. Returns the resulting high-water mark.
    @discardableResult
    public func raiseEpochHighWater(_ epoch: Int64) async throws -> Int64 {
        let d = try database()
        try await d.execute("INSERT INTO meta(key,value) VALUES('epoch_hwm', ?) ON CONFLICT(key) DO UPDATE SET value=MAX(value, excluded.value)", [.int(epoch)])
        return try await epochHighWater()
    }
}


extension WorkspaceContainer {
    public func acceptDropChain(object: String, chain: [Data]) async throws {
        guard !chain.isEmpty, chain.count <= 1024 else { throw DropStoreError.rollback }
        try await database().transaction { tx in
            if let previous = try tx.query("SELECT version,hash FROM drop_heads WHERE object=?", [.text(object)]).first {
                guard let n = previous.int("version"), n > 0, n <= chain.count,
                      previous.blob("hash") == chain[Int(n) - 1] else { throw DropStoreError.rollback }
            }
            try tx.execute("INSERT INTO drop_heads(object,version,hash) VALUES(?,?,?) ON CONFLICT(object) DO UPDATE SET version=excluded.version,hash=excluded.hash",
                           [.text(object), .int(Int64(chain.count)), .blob(chain.last!)])
        }
    }
    public func writeDrop(_ data: Data, object: String, version: UInt32) async throws -> URL {
        try StoreLayout.validate(ws: object)
        try await index.requireNotRemoved(ws: ws, generation: generation)
        _ = try database()
        let directory = try layout.filesDir(ws)
        let url = directory.appendingPathComponent("\(object)-\(version)")
        // Never wait for a cross-process lock on the cooperative pool. A busy lock refuses this
        // attempt; holding it through the write prevents publication after a removal tombstone.
        guard try layout.tombstones.ifNotRemoved(realm: layout.realm, ws: ws, generation: generation, timeout: 0, {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        }) == true else { throw StoreError.workspaceRemoved(ws: ws, generation: generation) }
        do { try await index.requireNotRemoved(ws: ws, generation: generation) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        return url
    }
}
public enum DropStoreError: Error, Sendable { case rollback }
