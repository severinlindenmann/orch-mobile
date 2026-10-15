import Foundation
import OrchProtocol

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
    /// Removal could not be determined. Preserve local data and retry later.
    case removalStateUnknown(ws: String, generation: Int64)
    case suspended
    /// A join tried to commit but its pairing row is gone (cancelled, erased or recovered away).
    case pairingNotOwned(ws: String, generation: Int64)
    /// A store already bound to one realm fence was asked to bind another.
    case fenceMismatch
}

/// Realm-scoped index: workspace ids, order, tombstones with generation. One file per realm,
/// so a demo realm physically cannot see live data. The index tombstones table is authoritative;
/// the coordination files are the copy extensions can read.
public final class WorkspaceIndex: Sendable {
    public let layout: StoreLayout
    /// Open workspace containers, so a wipe can close them before deleting files.
    public let containers = ContainerRegistry()
    let db: SQLiteDatabase
    /// The realm fence of the commit-type writes (`addWorkspace`, `savePairing`, `commitJoin`): bound at construction or once by the
    /// realm's pairing, then applied by those methods themselves. Wipe-type writes (tombstones, wipe phases, row removal, `deletePairing`)
    /// never use it: removal must keep working after the realm was invalidated.
    nonisolated let fenceBox: FenceBox
    public nonisolated func bind(fence f: any WriteFence) throws { try fenceBox.bind(f) }

    static let migrations = [
        Migration(version: 1, statements: [
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            "CREATE TABLE workspaces (ws TEXT PRIMARY KEY, generation INTEGER NOT NULL, position INTEGER NOT NULL)",
            "CREATE TABLE tombstones (ws TEXT NOT NULL, generation INTEGER NOT NULL, phase INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (ws, generation))",
        ]),
        // Slice 2b: pairing. `pairings` is the discovery row of one pending (or terminal-alarm) pairing; it holds no secret (the
        // pairing secret and pins live in the vault). `workspace_profiles` is what a verified join commits next to the workspace row.
        Migration(version: 2, statements: [
            """
            CREATE TABLE pairings (
              ws TEXT PRIMARY KEY, offer TEXT NOT NULL, generation INTEGER NOT NULL, origin TEXT NOT NULL,
              phase TEXT NOT NULL, terminal TEXT, detail TEXT, started_ms INTEGER NOT NULL, updated_ms INTEGER NOT NULL)
            """,
            """
            CREATE TABLE workspace_profiles (
              ws TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL, origin TEXT NOT NULL,
              client_hosted INTEGER NOT NULL, hosted_marker INTEGER NOT NULL, hosted_by TEXT,
              wsk_pub TEXT NOT NULL, pk_pub TEXT NOT NULL, owner_person TEXT NOT NULL,
              card_seq INTEGER NOT NULL, list_seq INTEGER NOT NULL, epoch INTEGER NOT NULL, scopes TEXT NOT NULL,
              card TEXT NOT NULL, joined_ms INTEGER NOT NULL)
            """,
        ]),
        // Slice 2b fix round: whether the pairing created the device keys (removed with it when nothing else uses them).
        Migration(version: 3, statements: [
            "ALTER TABLE pairings ADD COLUMN created_keys INTEGER NOT NULL DEFAULT 0",
        ]),
    ]

    public init(layout: StoreLayout, fence: (any WriteFence)? = nil) async throws {
        try layout.prepareRealm()
        self.layout = layout
        self.fenceBox = FenceBox(fence)
        db = try SQLiteDatabase(url: layout.indexURL)
        // Databases made by the first 2b build already have `created_keys` in migration 2 (SQLite cannot ALTER conditionally):
        // migration 3 is then a no-op, so both histories end at the same schema.
        var migrations = Self.migrations
        let hasColumn = try await db.query("SELECT name FROM pragma_table_info('pairings') WHERE name='created_keys'").isEmpty == false
        if hasColumn, let i = migrations.firstIndex(where: { $0.version == 3 }) { migrations[i] = Migration(version: 3, statements: ["SELECT 1"]) }
        try await db.migrate(migrations)
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
        try await requireNotRemoved(ws: ws, generation: generation)
        try await db.transaction(fence: fenceBox) { tx in
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
        try await db.transaction { tx in
            try tx.execute("DELETE FROM workspaces WHERE ws=?", [.text(ws)])
            try tx.execute("DELETE FROM workspace_profiles WHERE ws=?", [.text(ws)])
        }
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

    /// Launch-time repair: overwrite the coordination files in both App Group roots with the complete set
    /// from the index (fixes a corrupt or missing file with no wipe pending). Launch sequence:
    /// `republishTombstones()` then `LocalWipe.resumePendingWipes()`.
    public func republishTombstones() async throws {
        try layout.tombstones.republish(complete: try await tombstones().map(\.record))
    }

    /// Fail-closed admission check: unknown counts as removed. Never use this Boolean to authorize
    /// deletion; destructive callers must distinguish all three values of removalStatus.
    public func isRemoved(ws: String, generation: Int64) async throws -> Bool {
        await removalStatus(ws: ws, generation: generation) != .notRemoved
    }

    /// A write must wait for a readable removal state; uncertainty never authorizes cleanup.
    package func requireNotRemoved(ws: String, generation: Int64) async throws {
        switch await removalStatus(ws: ws, generation: generation) {
        case .notRemoved: return
        case .removed: throw StoreError.workspaceRemoved(ws: ws, generation: generation)
        case .unknown: throw StoreError.removalStateUnknown(ws: ws, generation: generation)
        }
    }

    /// Read failures preserve pending work; only confirmed tombstones authorize cleanup.
    public func removalStatus(ws: String, generation: Int64) async -> RemovalStatus {
        do {
            let rows = try await db.query("SELECT 1 FROM tombstones WHERE ws=? AND generation>=?", [.text(ws), .int(generation)])
            if !rows.isEmpty { return .removed }
        } catch { return .unknown }
        return layout.tombstones.removalStatus(realm: layout.realm, ws: ws, generation: generation)
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

/// The discovery row of one pairing in progress (slice 2b). No secret: the pairing secret, pins and the pending request live in
/// the vault. A terminal alarm keeps its row (with `terminal` and `detail`) so the alarm survives a restart.
public struct PairingRow: Sendable, Equatable {
    public var ws: String
    public var offer: String
    public var generation: Int64
    public var origin: String
    public var phase: String
    public var terminal: String?
    public var detail: String?
    public var startedMs: Int64
    public var updatedMs: Int64
    /// This pairing created the device keys (they are removed with it when nothing else uses them).
    public var createdKeys: Bool

    public init(ws: String, offer: String, generation: Int64, origin: String, phase: String, terminal: String? = nil,
                detail: String? = nil, startedMs: Int64, updatedMs: Int64, createdKeys: Bool = false) {
        self.createdKeys = createdKeys
        self.ws = ws; self.offer = offer; self.generation = generation; self.origin = origin; self.phase = phase
        self.terminal = terminal; self.detail = detail; self.startedMs = startedMs; self.updatedMs = updatedMs
    }
}

/// What a verified join commits for a workspace (display name from the signed card, pins, last accepted card and list counters).
public struct WorkspaceProfile: Sendable, Equatable {
    public var ws: String
    public var name: String
    public var description: String
    public var origin: String
    public var clientHosted: Bool
    public var hostedMarker: Bool
    public var hostedBy: String?
    public var wskPub: String
    public var pkPub: String
    public var ownerPerson: String
    public var cardSeq: Int64
    public var listSeq: Int64
    public var epoch: Int64
    public var scopes: [String]
    /// The last accepted card as canonical JSON (its head is the floor for later fetches).
    public var card: String
    public var joinedMs: Int64

    public init(ws: String, name: String, description: String, origin: String, clientHosted: Bool, hostedMarker: Bool, hostedBy: String?,
                wskPub: String, pkPub: String, ownerPerson: String, cardSeq: Int64, listSeq: Int64, epoch: Int64, scopes: [String],
                card: String, joinedMs: Int64) {
        self.ws = ws; self.name = name; self.description = description; self.origin = origin; self.clientHosted = clientHosted
        self.hostedMarker = hostedMarker; self.hostedBy = hostedBy; self.wskPub = wskPub; self.pkPub = pkPub; self.ownerPerson = ownerPerson
        self.cardSeq = cardSeq; self.listSeq = listSeq; self.epoch = epoch; self.scopes = scopes; self.card = card; self.joinedMs = joinedMs
    }
}

extension WorkspaceIndex {
    public func savePairing(_ r: PairingRow) async throws {
        try StoreLayout.validate(ws: r.ws)
        try await db.execute("""
            INSERT INTO pairings(ws, offer, generation, origin, phase, terminal, detail, started_ms, updated_ms, created_keys) VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(ws) DO UPDATE SET offer=excluded.offer, generation=excluded.generation, origin=excluded.origin, phase=excluded.phase,
              terminal=excluded.terminal, detail=excluded.detail, started_ms=excluded.started_ms, updated_ms=excluded.updated_ms,
              created_keys=excluded.created_keys
            """, [.text(r.ws), .text(r.offer), .int(r.generation), .text(r.origin), .text(r.phase),
                  r.terminal.map { .text($0) } ?? .null, r.detail.map { .text($0) } ?? .null, .int(r.startedMs), .int(r.updatedMs),
                  .int(r.createdKeys ? 1 : 0)], fence: fenceBox)
    }

    private static func pairing(_ x: SQLRow) -> PairingRow? {
        guard let ws = x.text("ws"), let offer = x.text("offer"), let g = x.int("generation"), let o = x.text("origin"),
              let p = x.text("phase"), let s = x.int("started_ms"), let u = x.int("updated_ms") else { return nil }
        return PairingRow(ws: ws, offer: offer, generation: g, origin: o, phase: p, terminal: x.text("terminal"), detail: x.text("detail"),
                          startedMs: s, updatedMs: u, createdKeys: (x.int("created_keys") ?? 0) != 0)
    }

    public func pairing(ws: String) async throws -> PairingRow? {
        try await db.query("SELECT * FROM pairings WHERE ws=?", [.text(ws)]).first.flatMap(Self.pairing)
    }

    public func pairings() async throws -> [PairingRow] {
        try await db.query("SELECT * FROM pairings ORDER BY started_ms, ws").compactMap(Self.pairing)
    }

    public func deletePairing(ws: String) async throws { try await db.execute("DELETE FROM pairings WHERE ws=?", [.text(ws)]) }

    public func profile(ws: String) async throws -> WorkspaceProfile? {
        guard let x = try await db.query("SELECT * FROM workspace_profiles WHERE ws=?", [.text(ws)]).first,
              let name = x.text("name"), let d = x.text("description"), let o = x.text("origin"), let ch = x.int("client_hosted"),
              let hm = x.int("hosted_marker"), let wsk = x.text("wsk_pub"), let pk = x.text("pk_pub"), let owner = x.text("owner_person"),
              let cs = x.int("card_seq"), let ls = x.int("list_seq"), let ep = x.int("epoch"), let sc = x.text("scopes"),
              let card = x.text("card"), let j = x.int("joined_ms") else { return nil }
        return WorkspaceProfile(ws: ws, name: name, description: d, origin: o, clientHosted: ch != 0, hostedMarker: hm != 0,
                                hostedBy: x.text("hosted_by"), wskPub: wsk, pkPub: pk, ownerPerson: owner, cardSeq: cs, listSeq: ls, epoch: ep,
                                scopes: sc.split(separator: ",").map(String.init), card: card, joinedMs: j)
    }

    /// The atomic end of a verified join and the single linearization point of a pairing: the tombstone check, the ownership check
    /// (the live pairing row of this workspace and generation must still exist: a cancel, an erase or a recovery that removed it wins),
    /// the workspace row, its profile and the removal of the pairing row happen in one transaction, so a crash leaves either a pending
    /// pairing or a complete workspace, never a half-installed one.
    public func commitJoin(generation: Int64, profile p: WorkspaceProfile) async throws {
        try StoreLayout.validate(ws: p.ws)
        try await requireNotRemoved(ws: p.ws, generation: generation)
        try await db.transaction(fence: fenceBox) { tx in
            let t = try tx.query("SELECT 1 FROM tombstones WHERE ws=? AND generation>=?", [.text(p.ws), .int(generation)])
            if !t.isEmpty { throw StoreError.workspaceRemoved(ws: p.ws, generation: generation) }
            let owned = try tx.query("SELECT 1 FROM pairings WHERE ws=? AND generation=? AND terminal IS NULL", [.text(p.ws), .int(generation)])
            if owned.isEmpty { throw StoreError.pairingNotOwned(ws: p.ws, generation: generation) }
            let next = try tx.query("SELECT COALESCE(MAX(position)+1, 0) AS n FROM workspaces").first?.int("n") ?? 0
            try tx.execute("INSERT OR REPLACE INTO workspaces(ws, generation, position) VALUES(?,?,?)", [.text(p.ws), .int(generation), .int(next)])
            try tx.execute("""
                INSERT OR REPLACE INTO workspace_profiles(ws, name, description, origin, client_hosted, hosted_marker, hosted_by, wsk_pub, pk_pub,
                  owner_person, card_seq, list_seq, epoch, scopes, card, joined_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(p.ws), .text(p.name), .text(p.description), .text(p.origin), .int(p.clientHosted ? 1 : 0), .int(p.hostedMarker ? 1 : 0),
                      p.hostedBy.map { .text($0) } ?? .null, .text(p.wskPub), .text(p.pkPub), .text(p.ownerPerson), .int(p.cardSeq), .int(p.listSeq),
                      .int(p.epoch), .text(p.scopes.joined(separator: ",")), .text(p.card), .int(p.joinedMs)])
            try tx.execute("DELETE FROM pairings WHERE ws=?", [.text(p.ws)])
        }
    }

    /// The highest tombstoned generation of `ws` (0 if none): a rejoin uses the next one.
    public func nextGeneration(ws: String) async throws -> Int64 {
        let t = try await db.query("SELECT MAX(generation) AS g FROM tombstones WHERE ws=?", [.text(ws)]).first?.int("g") ?? 0
        let w = try await db.query("SELECT generation FROM workspaces WHERE ws=?", [.text(ws)]).first?.int("generation") ?? 0
        return max(t, w) + 1
    }
}
