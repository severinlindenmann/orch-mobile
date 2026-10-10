import Foundation

/// Opens and closes one workspace's `ws.sqlite`. On protected-data loss the app calls `suspend()`
/// (handles closed, operations throw `.suspended`) and `resume()` when data is available again.
public actor WorkspaceContainer {
    public let layout: StoreLayout
    public let ws: String
    public let generation: Int64
    private var db: SQLiteDatabase?
    private var suspended = false

    static let migrations = [
        Migration(version: 1, statements: [
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)",
            "CREATE TABLE request_ids (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL)",
        ]),
    ]

    public init(layout: StoreLayout, ws: String, generation: Int64) async throws {
        self.layout = layout; self.ws = ws; self.generation = generation
        try await openDatabase()
    }

    private func openDatabase() async throws {
        if layout.tombstones.isRemoved(realm: layout.realm, ws: ws, generation: generation) {
            throw StoreError.workspaceRemoved(ws: ws, generation: generation)
        }
        try layout.prepareWorkspace(ws)
        let d = try SQLiteDatabase(url: layout.wsDatabaseURL(ws))
        try await d.migrate(Self.migrations)
        db = d
    }

    public var isSuspended: Bool { suspended }

    public func suspend() async {
        suspended = true
        await db?.close()
        db = nil
    }

    public func resume() async throws {
        guard suspended || db == nil else { return }
        try await openDatabase()
        suspended = false
    }

    public func close() async {
        await db?.close()
        db = nil
        suspended = true
    }

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
