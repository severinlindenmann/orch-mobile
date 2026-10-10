import Foundation

public struct WorkspaceEntry: Sendable, Equatable {
    public let ws: String
    public let generation: Int64
    public let position: Int64
}

public struct TombstoneEntry: Sendable, Equatable {
    public let record: TombstoneRecord
    /// Wipe progress: 0 recorded, 1..4 = A11 phases completed (4 = finished).
    public let phase: Int
}

public enum StoreError: Error, Equatable, Sendable {
    case realmMismatch(expected: String, found: String)
    case workspaceRemoved(ws: String, generation: Int64)
    case suspended
}

/// Realm-scoped index: workspace ids, order, tombstones with generation. One file per realm,
/// so a demo realm physically cannot see live data. The index tombstones table is authoritative;
/// the coordination files are the copy extensions can read.
public final class WorkspaceIndex: Sendable {
    public let layout: StoreLayout
    /// Open workspace containers, so a wipe can close them before deleting files.
    public let containers = ContainerRegistry()
    let db: SQLiteDatabase

    static let migrations = [
        Migration(version: 1, statements: [
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            "CREATE TABLE workspaces (ws TEXT PRIMARY KEY, generation INTEGER NOT NULL, position INTEGER NOT NULL)",
            "CREATE TABLE tombstones (ws TEXT NOT NULL, generation INTEGER NOT NULL, phase INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (ws, generation))",
        ]),
    ]

    public init(layout: StoreLayout) async throws {
        try layout.prepareRealm()
        self.layout = layout
        db = try SQLiteDatabase(url: layout.indexURL)
        try await db.migrate(Self.migrations)
        let found = try await db.query("SELECT value FROM meta WHERE key='realm'").first?.text("value")
        if let found {
            guard found == layout.realm else { throw StoreError.realmMismatch(expected: layout.realm, found: found) }
        } else {
            try await db.execute("INSERT INTO meta(key,value) VALUES('realm', ?)", [.text(layout.realm)])
        }
    }

    public func close() async { await db.close() }

    public func workspaces() async throws -> [WorkspaceEntry] {
        try await db.query("SELECT ws, generation, position FROM workspaces ORDER BY position, ws").map {
            WorkspaceEntry(ws: $0.text("ws")!, generation: $0.int("generation")!, position: $0.int("position")!)
        }
    }

    /// Adds at the end of the order. The tombstone check and the insert run in one transaction, so a
    /// concurrent wipe cannot interleave. Rejects a generation a tombstone already covers (stale rejoin).
    public func addWorkspace(ws: String, generation: Int64) async throws {
        try StoreLayout.validate(ws: ws)
        if layout.tombstones.isRemovedFailClosed(realm: layout.realm, ws: ws, generation: generation) {
            throw StoreError.workspaceRemoved(ws: ws, generation: generation)
        }
        try await db.transaction { tx in
            let t = try tx.query("SELECT 1 FROM tombstones WHERE ws=? AND generation>=?", [.text(ws), .int(generation)])
            if !t.isEmpty { throw StoreError.workspaceRemoved(ws: ws, generation: generation) }
            let next = try tx.query("SELECT COALESCE(MAX(position)+1, 0) AS n FROM workspaces").first?.int("n") ?? 0
            try tx.execute("INSERT OR REPLACE INTO workspaces(ws, generation, position) VALUES(?,?,?)", [.text(ws), .int(generation), .int(next)])
        }
    }

    public func setOrder(_ order: [String]) async throws {
        try await db.transaction { tx in
            for (i, ws) in order.enumerated() { try tx.execute("UPDATE workspaces SET position=? WHERE ws=?", [.int(Int64(i)), .text(ws)]) }
        }
    }

    public func removeWorkspaceRow(ws: String) async throws {
        try await db.execute("DELETE FROM workspaces WHERE ws=?", [.text(ws)])
    }

    /// Index half of A11 (1): idempotent. The recorded generation is the max of the supplied one, the
    /// indexed workspace's current one and any earlier tombstone, so a stale caller cannot leave a newer
    /// generation unprotected. Returns the effective generation.
    @discardableResult
    public func recordTombstone(ws: String, generation: Int64) async throws -> Int64 {
        try await db.transaction { tx in
            var g = generation
            if let w = try tx.query("SELECT generation FROM workspaces WHERE ws=?", [.text(ws)]).first?.int("generation") { g = max(g, w) }
            if let t = try tx.query("SELECT MAX(generation) AS g FROM tombstones WHERE ws=?", [.text(ws)]).first?.int("g") { g = max(g, t) }
            try tx.execute("INSERT OR IGNORE INTO tombstones(ws, generation, phase) VALUES(?,?,0)", [.text(ws), .int(g)])
            return g
        }
    }

    public func tombstones() async throws -> [TombstoneEntry] {
        try await db.query("SELECT ws, generation, phase FROM tombstones ORDER BY ws, generation").map {
            TombstoneEntry(record: TombstoneRecord(realm: layout.realm, ws: $0.text("ws")!, generation: $0.int("generation")!),
                           phase: Int($0.int("phase")!))
        }
    }

    public func setWipePhase(ws: String, generation: Int64, phase: Int) async throws {
        try await db.execute("UPDATE tombstones SET phase=MAX(phase, ?) WHERE ws=? AND generation=?", [.int(Int64(phase)), .text(ws), .int(generation)])
    }

    /// Index first (authoritative), then the coordination files fail-closed.
    public func isRemoved(ws: String, generation: Int64) async throws -> Bool {
        let rows = try await db.query("SELECT 1 FROM tombstones WHERE ws=? AND generation>=?", [.text(ws), .int(generation)])
        if !rows.isEmpty { return true }
        return layout.tombstones.isRemovedFailClosed(realm: layout.realm, ws: ws, generation: generation)
    }
}

/// Weak registry of open containers, so a wipe can quiesce them.
public final class ContainerRegistry: @unchecked Sendable {
    private final class Box { weak var container: WorkspaceContainer?; init(_ c: WorkspaceContainer) { container = c } }
    private let lock = NSLock()
    private var boxes: [Box] = []

    func register(_ c: WorkspaceContainer) {
        lock.lock(); defer { lock.unlock() }
        boxes.removeAll { $0.container == nil }
        boxes.append(Box(c))
    }

    /// Suspends (closes the handle of) every live container for `ws`.
    public func suspendAll(ws: String) async {
        let live: [WorkspaceContainer] = { lock.lock(); defer { lock.unlock() }; return boxes.compactMap(\.container) }()
        for c in live where c.ws == ws { await c.suspend() }
    }
}
