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
        Migration(version: 8, statements: [
            "ALTER TABLE drop_heads ADD COLUMN file_version INTEGER",
            "ALTER TABLE drop_heads ADD COLUMN file_expires_ms INTEGER",
        ]),
        Migration(version: 9, statements: [
            "CREATE TABLE drop_completed_jobs (job TEXT PRIMARY KEY)",
        ]),
        Migration(version: 10, statements: [
            "ALTER TABLE drop_heads ADD COLUMN downloaded_at INTEGER",
        ]),
        // PR3 (P3-D6): the last verified member list this device accepted, so a relay cannot roll it back.
        Migration(version: 11, statements: [
            "CREATE TABLE member_list_head (id INTEGER PRIMARY KEY CHECK (id = 1), list_seq INTEGER NOT NULL, epoch INTEGER NOT NULL, digest BLOB NOT NULL)",
        ]),
        // Q10 (one WK per epoch, ever): the `wk_commit` of every epoch this device accepted a verified list at. It decides which
        // WK the epoch has: the device seals only under a key the head list commits, and reads check a held commitment.
        Migration(version: 12, statements: [
            "CREATE TABLE wk_commits (epoch INTEGER PRIMARY KEY, wk_commit BLOB NOT NULL)",
            // The head list's member devices (sorted lower-case hex, comma-separated), so a later list at the same epoch that drops
            // one is refused on the phone too (`rotation_required`). NULL for a head recorded before this migration.
            "ALTER TABLE member_list_head ADD COLUMN members TEXT",
            // The pre-Q10 head has no wk_commit and its digest is over a list without one: the host's re-issued list under the same
            // list_seq would be a permanent `conflicting_snapshot`. Drop it; the next verified list is accepted as a first list (its
            // epoch still may not fall below the confirmed epoch), and the send path fetches it at once (`sealingKeyRecovering`).
            "DELETE FROM member_list_head",
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

    /// Records a verified member list's head (`list_seq`, epoch, `H(cj(o))`) if it does not roll back the last one (P3-D6): an
    /// older `list_seq` is `rollback`, other content under the same `list_seq` is `conflict`, a falling epoch is `epochFell`. The
    /// identical list again is accepted. First of all (Q10), a list whose `wk_commit` differs from one already held for its epoch
    /// is `wkCommitConflict`, whatever its sequence: the alarm is recorded durably (the first epoch it was seen at) and nothing
    /// else is written. An accepted list's commitment is kept for its epoch. Check and write are one transaction.
    /// `members` are the list's device ids (hex): a later `list_seq` at the head's epoch that drops one of the head's devices is
    /// `rotationRequired` (a removal needs a new epoch, section 7.2).
    public func acceptMemberListHead(listSeq: Int64, epoch: Int64, digest: Data, wkCommit: Data, members: [String]) async throws {
        let memberText = members.sorted().joined(separator: ",")
        let conflict: Bool = try await database().transaction { tx in
            if let held = try tx.query("SELECT wk_commit FROM wk_commits WHERE epoch=?", [.int(epoch)]).first?.blob("wk_commit"), held != wkCommit {
                try tx.execute("INSERT OR IGNORE INTO meta(key,value) VALUES('wk_commit_conflict', ?)", [.int(epoch)])
                return true
            }
            if let row = try tx.query("SELECT list_seq, epoch, digest, members FROM member_list_head WHERE id=1").first,
               let seq = row.int("list_seq"), let e = row.int("epoch"), let d = row.blob("digest") {
                if listSeq < seq { throw MemberListHeadError.rollback }
                if listSeq == seq, d != digest { throw MemberListHeadError.conflict }
                if listSeq > seq, epoch < e { throw MemberListHeadError.epochFell }
                if listSeq > seq, epoch == e, let held = row.text("members"), !held.isEmpty,
                   !Set(held.split(separator: ",").map(String.init)).isSubset(of: Set(members)) { throw MemberListHeadError.rotationRequired }
            }
            try tx.execute("INSERT OR IGNORE INTO wk_commits(epoch, wk_commit) VALUES(?,?)", [.int(epoch), .blob(wkCommit)])
            try tx.execute("INSERT INTO member_list_head(id, list_seq, epoch, digest, members) VALUES(1,?,?,?,?) ON CONFLICT(id) DO UPDATE SET list_seq=excluded.list_seq, epoch=excluded.epoch, digest=excluded.digest, members=excluded.members",
                           [.int(listSeq), .int(epoch), .blob(digest), .text(memberText)])
            return false
        }
        if conflict { throw MemberListHeadError.wkCommitConflict }
    }

    /// The `wk_commit` of a verified list this device accepted at `epoch`, if any.
    public func wkCommit(epoch: Int64) async throws -> Data? {
        try await database().query("SELECT wk_commit FROM wk_commits WHERE epoch=?", [.int(epoch)]).first?.blob("wk_commit")
    }

    /// The local alarm `wk_commit_conflict` (Q10): the first epoch at which two verified lists committed to different keys. Durable;
    /// while it is set the device seals nothing.
    public func wkCommitConflictEpoch() async throws -> Int64? {
        try await database().query("SELECT value FROM meta WHERE key='wk_commit_conflict'").first?.int("value")
    }

    public func memberListHead() async throws -> (listSeq: Int64, epoch: Int64)? {
        guard let row = try await database().query("SELECT list_seq, epoch FROM member_list_head WHERE id=1").first,
              let seq = row.int("list_seq"), let e = row.int("epoch") else { return nil }
        return (seq, e)
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
        try StoreLayout.validate(ws: object)
        guard !chain.isEmpty, chain.count <= 1024 else { throw DropStoreError.rollback }
        let layout = self.layout, ws = self.ws, generation = self.generation
        try await database().transaction { tx in
            try Self.withDropFiles(layout: layout, ws: ws, generation: generation) { directory in
                if let previous = try tx.query("SELECT version,hash FROM drop_heads WHERE object=?", [.text(object)]).first {
                    guard let n = previous.int("version"), n > 0, n <= chain.count,
                          previous.blob("hash") == chain[Int(n) - 1] else { throw DropStoreError.rollback }
                }
                try tx.execute("INSERT INTO drop_heads(object,version,hash) VALUES(?,?,?) ON CONFLICT(object) DO UPDATE SET version=excluded.version,hash=excluded.hash",
                               [.text(object), .int(Int64(chain.count)), .blob(chain.last!)])
                try Self.purgeDownloads(tx, directory: directory, nowMs: nil)
            }
        }
    }

    /// Also removes untracked files from older schemas or interrupted publication.
    public func purgeExpiredDownloads(nowMs: Int64) async throws {
        let layout = self.layout, ws = self.ws, generation = self.generation
        try await database().transaction { tx in
            try Self.withDropFiles(layout: layout, ws: ws, generation: generation) { directory in
                try Self.purgeDownloads(tx, directory: directory, nowMs: nowMs)
            }
        }
    }

    public func writeDrop(_ data: Data, object: String, version: UInt32, expiresMs: Int64?,
                          now: @Sendable @escaping () -> Int64) async throws -> URL {
        try await writeDropVerified(data, object: object, version: version, expiresMs: expiresMs, now: now).url
    }

    public func writeDropVerified(_ data: Data, object: String, version: UInt32, expiresMs: Int64?,
                                  now: @Sendable @escaping () -> Int64) async throws -> (url: URL, deadlineMs: Int64) {
        try StoreLayout.validate(ws: object)
        try await index.requireNotRemoved(ws: ws, generation: generation)
        let layout = self.layout, ws = self.ws, generation = self.generation
        return try await database().transaction { tx in
            try Self.withDropFiles(layout: layout, ws: ws, generation: generation) { directory in
                guard let head = try tx.query("SELECT version FROM drop_heads WHERE object=?", [.text(object)]).first,
                      head.int("version") == Int64(version) else { throw DropStoreError.rollback }
                let downloadedAt = now()
                guard expiresMs.map({ $0 > downloadedAt }) ?? true else { throw DropStoreError.expired }
                // The database transaction serializes publication with head updates and purges, even
                // across containers. The tombstone lock excludes wipe; atomic replace hides partial bytes.
                try tx.execute("UPDATE drop_heads SET file_version=?,file_expires_ms=?,downloaded_at=? WHERE object=?",
                               [.int(Int64(version)), expiresMs.map(SQLValue.int) ?? .null, .int(downloadedAt), .text(object)])
                let url = directory.appendingPathComponent("\(object)-\(version)")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                let (cap, overflow) = downloadedAt.addingReportingOverflow(604800000)
                return (url, min(expiresMs ?? .max, overflow ? .max : cap))
            }
        }
    }

    private nonisolated static func withDropFiles<T>(layout: StoreLayout, ws: String, generation: Int64,
                                                     _ body: (URL) throws -> T) throws -> T {
        // Never wait for a cross-process lock on the cooperative pool.
        guard let result = try layout.tombstones.ifNotRemoved(realm: layout.realm, ws: ws, generation: generation, timeout: 0, {
            try body(layout.filesDir(ws))
        }) else {
            if layout.tombstones.removalStatus(realm: layout.realm, ws: ws, generation: generation) == .removed {
                throw StoreError.workspaceRemoved(ws: ws, generation: generation)
            }
            throw StoreError.removalStateUnknown(ws: ws, generation: generation)
        }
        return result
    }

    private nonisolated static func purgeDownloads(_ tx: SQLiteTransaction, directory: URL, nowMs: Int64?) throws {
        let rows = try tx.query("SELECT object,version,file_version,file_expires_ms,downloaded_at FROM drop_heads")
        var keep = Set<String>()
        for row in rows {
            guard let object = row.text("object"), let version = row.int("file_version") else { continue }
            // Unknown download times from older schemas cannot safely extend local retention.
            let localExpiry = row.int("downloaded_at").map { downloadedAt in
                let (expiry, overflow) = downloadedAt.addingReportingOverflow(604800000)
                return overflow ? Int64.max : expiry
            }
            let effectiveExpiry = localExpiry.map { min($0, row.int("file_expires_ms") ?? Int64.max) }
            if version == row.int("version"), let effectiveExpiry,
               nowMs.map({ effectiveExpiry > $0 }) ?? true {
                keep.insert("\(object)-\(version)")
            } else {
                try tx.execute("UPDATE drop_heads SET file_version=NULL,file_expires_ms=NULL,downloaded_at=NULL WHERE object=?", [.text(object)])
            }
        }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where !keep.contains(file.lastPathComponent) { try FileManager.default.removeItem(at: file) }
    }
}
public enum DropStoreError: Error, Sendable { case rollback, expired }

/// A member list that would roll back the one this device last accepted (P3-D6).
public enum MemberListHeadError: Error, Equatable, Sendable { case rollback, conflict, epochFell, rotationRequired, wkCommitConflict }
