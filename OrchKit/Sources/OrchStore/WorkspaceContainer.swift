import Foundation
import OrchCoordination
import OrchProtocol

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
    /// The realm fence every write of this container's database runs inside (see `WriteFence`). The database shares this box and reads it
    /// at each write, so a bind during an open, or after it, applies to every later write. Bound once; never re-bound to another fence.
    nonisolated let fenceBox: FenceBox
    public nonisolated var fence: (any WriteFence)? { fenceBox.current }

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
        // G2b D2 (orch-relay 491b500): `wk_commit_conflict` stops sealing at THAT epoch only, until a verified list at a higher epoch
        // arrives. The single durable flag of migration 12 becomes a set of blocked epochs.
        Migration(version: 13, statements: [
            "CREATE TABLE sealing_blocked (epoch INTEGER PRIMARY KEY)",
            "INSERT OR IGNORE INTO sealing_blocked(epoch) SELECT value FROM meta WHERE key='wk_commit_conflict'",
            "DELETE FROM meta WHERE key='wk_commit_conflict'",
        ]),
        // P3-D40 (protocol 19.10): the relay push registration of this workspace, one per APNs environment. The id is the device's
        // (16 random bytes, hex) and is persisted BEFORE the request so a lost reply retries the same body (idempotent 200).
        // `confirmed_ms` is NULL until the relay answered 200 for exactly this id and token.
        Migration(version: 14, statements: [
            "CREATE TABLE push_registrations (env TEXT PRIMARY KEY, registration_id TEXT NOT NULL, token TEXT NOT NULL, confirmed_ms INTEGER)",
        ]),
        // C2b (orch-mobile c2b-plan-rev2 3.1): person-event writes. One `pe_reviews` row per signed review (an answer, later a creation)
        // pointing at its current attempt by compare-and-swap (`current_idem`, `ver`); `pe_attempts` holds every attempt immutably: the
        // exact signed event bytes (the only bytes ever framed for that idem), the clock facts of the window check, the dispatch marker and
        // the append-only settlement evidence. Every write row of `bridge_requests` names its attempt. The v0 `decisions` table and its
        // bridge rows (Demo only) are retired in the same migration.
        Migration(version: 15, statements: [
            """
            CREATE TABLE pe_reviews (review TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('answer','new_ticket')), log TEXT NOT NULL,
              question TEXT, snapshot BLOB NOT NULL, key_disclosed TEXT, current_idem TEXT NOT NULL, ver INTEGER NOT NULL,
              resigns INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL CHECK (state IN ('active','landed','landed_unconfirmed','needs_review','refused','discarded')),
              landed_idem TEXT, outcome TEXT, created_ms INTEGER NOT NULL)
            """,
            """
            CREATE TABLE pe_attempts (idem TEXT PRIMARY KEY, review TEXT NOT NULL REFERENCES pe_reviews(review), n INTEGER NOT NULL,
              origin TEXT NOT NULL CHECK (origin IN ('tap','auto')), event BLOB NOT NULL, digest TEXT NOT NULL, key TEXT, auth TEXT NOT NULL,
              ulid_ms INTEGER NOT NULL, signed_wall_ms INTEGER NOT NULL, signed_offset_ms INTEGER NOT NULL,
              dispatched INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL CHECK (state IN ('signed','sent','landed','c_auto','c_review','d','superseded','discarded')),
              evidence TEXT NOT NULL DEFAULT '[]', UNIQUE (review, n))
            """,
            "ALTER TABLE bridge_requests ADD COLUMN attempt TEXT REFERENCES pe_attempts(idem)",
            "CREATE INDEX bridge_requests_attempt ON bridge_requests(attempt)",
            // one active review per question, in SQL: a double tap or a second sheet can never hold two signed reviews of one question
            "CREATE UNIQUE INDEX pe_reviews_one_active ON pe_reviews(question) WHERE state = 'active'",
            // NOTE: `INSERT OR REPLACE` / `REPLACE INTO` is never used on pe_reviews or pe_attempts (a REPLACE deletes the old row WITHOUT
            // firing the delete triggers below, recursive_triggers being off). Pinned by `PersonEventTriggerTests.noReplaceOnTheWriteTables`.
            // immutability: what was signed, and when, never changes
            """
            CREATE TRIGGER pe_attempts_immutable BEFORE UPDATE ON pe_attempts
            WHEN NEW.idem IS NOT OLD.idem OR NEW.review IS NOT OLD.review OR NEW.n IS NOT OLD.n OR NEW.origin IS NOT OLD.origin
              OR NEW.event IS NOT OLD.event OR NEW.digest IS NOT OLD.digest OR NEW.key IS NOT OLD.key OR NEW.auth IS NOT OLD.auth
              OR NEW.ulid_ms IS NOT OLD.ulid_ms OR NEW.signed_wall_ms IS NOT OLD.signed_wall_ms OR NEW.signed_offset_ms IS NOT OLD.signed_offset_ms
            BEGIN SELECT RAISE(ABORT, 'pe_attempts: signed fields are immutable'); END
            """,
            // the dispatch marker is monotonic: a possibly sent attempt is never declared unsent
            """
            CREATE TRIGGER pe_attempts_dispatched BEFORE UPDATE OF dispatched ON pe_attempts WHEN OLD.dispatched = 1 AND NEW.dispatched <> 1
            BEGIN SELECT RAISE(ABORT, 'pe_attempts: dispatched never falls'); END
            """,
            // landed is final
            """
            CREATE TRIGGER pe_attempts_landed BEFORE UPDATE OF state ON pe_attempts WHEN OLD.state = 'landed' AND NEW.state <> 'landed'
            BEGIN SELECT RAISE(ABORT, 'pe_attempts: landed is final'); END
            """,
            "CREATE TRIGGER pe_attempts_keep_landed BEFORE DELETE ON pe_attempts WHEN OLD.state = 'landed' BEGIN SELECT RAISE(ABORT, 'pe_attempts: landed is final'); END",
            // a possibly sent attempt is kept until it is settled: only a definite refusal (c_review, d) may go
            """
            CREATE TRIGGER pe_attempts_keep_dispatched BEFORE DELETE ON pe_attempts WHEN OLD.dispatched = 1 AND OLD.state NOT IN ('landed','c_review','d')
            BEGIN SELECT RAISE(ABORT, 'pe_attempts: a dispatched attempt is kept until settled'); END
            """,
            // a possibly sent attempt is never declared unsigned or unsent again
            """
            CREATE TRIGGER pe_attempts_sent_stays_sent BEFORE UPDATE ON pe_attempts
            WHEN NEW.state IN ('signed','discarded') AND NEW.state IS NOT OLD.state AND (OLD.dispatched = 1 OR NEW.dispatched = 1)
            BEGIN SELECT RAISE(ABORT, 'pe_attempts: a dispatched attempt is never signed or discarded again'); END
            """,
            // evidence is truly append-only: longer, the old array minus its `]` is a prefix, the first appended character is `,` (or the
            // first element's `{` after an empty `[]`), and the result is still a valid JSON array
            """
            CREATE TRIGGER pe_attempts_evidence BEFORE UPDATE OF evidence ON pe_attempts
            WHEN NEW.evidence IS NOT OLD.evidence AND NOT (
              json_valid(NEW.evidence) AND length(NEW.evidence) > length(OLD.evidence) AND substr(OLD.evidence, -1) = ']' AND substr(NEW.evidence, -1) = ']'
              AND substr(NEW.evidence, 1, length(OLD.evidence) - 1) = substr(OLD.evidence, 1, length(OLD.evidence) - 1)
              AND substr(NEW.evidence, length(OLD.evidence), 1) = CASE WHEN OLD.evidence = '[]' THEN '{' ELSE ',' END)
            BEGIN SELECT RAISE(ABORT, 'pe_attempts: evidence is append-only'); END
            """,
            // a review that landed stays landed (confirmed or not), with the same landed attempt
            """
            CREATE TRIGGER pe_reviews_landed BEFORE UPDATE ON pe_reviews
            WHEN OLD.state IN ('landed','landed_unconfirmed') AND (NEW.state NOT IN ('landed','landed_unconfirmed') OR NEW.landed_idem IS NOT OLD.landed_idem)
            BEGIN SELECT RAISE(ABORT, 'pe_reviews: a landing is final'); END
            """,
            // retire the Demo v0 decision rows together with their table
            "DELETE FROM bridge_requests WHERE logical IN (SELECT id FROM decisions)",
            "DELETE FROM meta WHERE key LIKE 'exhausted:%' AND substr(key, 11) IN (SELECT id FROM decisions)",
            "DROP TABLE decisions",
        ]),
    ]

    public init(index: WorkspaceIndex, ws: String, generation: Int64, fence: (any WriteFence)? = nil) async throws {
        try StoreLayout.validate(ws: ws)
        self.index = index; self.ws = ws; self.generation = generation; self.fenceBox = FenceBox(fence)
        index.containers.register(self)
        try await resume()
    }

    /// Binds the realm fence to this container and its open database: from now on every write is check-and-act under it.
    public nonisolated func bind(fence f: any WriteFence) throws { try fenceBox.bind(f) }

    public var layout: StoreLayout { index.layout }
    public var isSuspended: Bool { suspended }

    private func performOpen(_ start: Int) async throws {
        try await index.requireNotRemoved(ws: ws, generation: generation)
        let layout = index.layout
        // A stale realm creates no workspace directory or database: the check and the creation are one step against invalidation.
        let d = try fenceBox.perform {
            try layout.prepareWorkspace(ws)
            return try SQLiteDatabase(url: layout.wsDatabaseURL(ws), fence: fenceBox)
        }
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

    /// What `acceptMemberListHead` did with a verified list.
    public enum MemberListHeadResult: Equatable, Sendable { case advanced, noop }

    /// G2b D1/D2 (orch-relay 491b500, vectors `member_list_snapshots`), in this order, in one transaction:
    /// the same `list_seq` with the same `H(cj(o))` is a no-op (signature bytes are never compared); the same `list_seq` with other
    /// content is `conflict` (`conflicting_snapshot`, which does not block sealing, even if its `wk_commit` differs); another
    /// `wk_commit` than the one held for the list's epoch is `wkCommitConflict` and blocks sealing at that epoch (checked BEFORE the
    /// stale check: a lower `list_seq` with another commitment is WSK-signed proof of two keys at one epoch); then an older `list_seq`
    /// is `rollback`, a falling epoch `epochFell`, a removal at the same epoch `rotationRequired`. An accepted list becomes the head,
    /// its epoch's commitment is kept, and a higher epoch lifts every sealing block below it.
    @discardableResult
    public func acceptMemberListHead(listSeq: Int64, epoch: Int64, digest: Data, wkCommit: Data, members: [String]) async throws -> MemberListHeadResult {
        let memberText = members.sorted().joined(separator: ",")
        let outcome: Result<MemberListHeadResult, MemberListHeadError> = try await database().transaction { tx in
            let head = try tx.query("SELECT list_seq, epoch, digest, members FROM member_list_head WHERE id=1").first
            if let head, let seq = head.int("list_seq"), let d = head.blob("digest"), listSeq == seq {
                return d == digest ? .success(.noop) : .failure(.conflict)
            }
            if let held = try tx.query("SELECT wk_commit FROM wk_commits WHERE epoch=?", [.int(epoch)]).first?.blob("wk_commit"), held != wkCommit {
                try tx.execute("INSERT OR IGNORE INTO sealing_blocked(epoch) VALUES(?)", [.int(epoch)])
                return .failure(.wkCommitConflict)
            }
            if let head, let seq = head.int("list_seq"), let e = head.int("epoch") {
                if listSeq < seq { return .failure(.rollback) }
                if epoch < e { return .failure(.epochFell) }
                if epoch == e, let held = head.text("members"), !held.isEmpty,
                   !Set(held.split(separator: ",").map(String.init)).isSubset(of: Set(members)) { return .failure(.rotationRequired) }
            }
            try tx.execute("INSERT OR IGNORE INTO wk_commits(epoch, wk_commit) VALUES(?,?)", [.int(epoch), .blob(wkCommit)])
            try tx.execute("DELETE FROM sealing_blocked WHERE epoch < ?", [.int(epoch)])
            try tx.execute("INSERT INTO member_list_head(id, list_seq, epoch, digest, members) VALUES(1,?,?,?,?) ON CONFLICT(id) DO UPDATE SET list_seq=excluded.list_seq, epoch=excluded.epoch, digest=excluded.digest, members=excluded.members",
                           [.int(listSeq), .int(epoch), .blob(digest), .text(memberText)])
            return .success(.advanced)
        }
        return try outcome.get()
    }

    /// The `wk_commit` of a verified list this device accepted at `epoch`, if any.
    public func wkCommit(epoch: Int64) async throws -> Data? {
        try await database().query("SELECT wk_commit FROM wk_commits WHERE epoch=?", [.int(epoch)]).first?.blob("wk_commit")
    }

    /// Every held commitment, by epoch (tests and diagnostics).
    public func wkCommits() async throws -> [Int64: Data] {
        var out: [Int64: Data] = [:]
        for r in try await database().query("SELECT epoch, wk_commit FROM wk_commits") { if let e = r.int("epoch"), let c = r.blob("wk_commit") { out[e] = c } }
        return out
    }

    /// Epochs at which `wk_commit_conflict` stopped sealing (G2b D2), ascending.
    public func sealingBlocked() async throws -> [Int64] {
        try await database().query("SELECT epoch FROM sealing_blocked ORDER BY epoch").compactMap { $0.int("epoch") }
    }

    /// The full head (G2b D1): `list_seq`, epoch, `H(cj(o))` and the member devices (hex, sorted).
    public func memberListHeadRecord() async throws -> (listSeq: Int64, epoch: Int64, digest: Data, members: [String])? {
        guard let row = try await database().query("SELECT list_seq, epoch, digest, members FROM member_list_head WHERE id=1").first,
              let seq = row.int("list_seq"), let e = row.int("epoch"), let d = row.blob("digest") else { return nil }
        let m = row.text("members").map { $0.isEmpty ? [] : $0.split(separator: ",").map(String.init) } ?? []
        return (seq, e, d, m)
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
    /// The persisted head version of a Drop object, nil when none was accepted yet. A chain walk starts there, not at version 1.
    public func dropHeadVersion(object: String) async throws -> UInt32? {
        try StoreLayout.validate(ws: object)
        guard let n = try await database().query("SELECT version FROM drop_heads WHERE object=?", [.text(object)]).first?.int("version"),
              n > 0, n <= Int64(UInt32.max) else { return nil }
        return UInt32(n)
    }

    public func acceptDropChain(object: String, chain: [Data]) async throws {
        try await acceptDropChain(object: object, firstVersion: 1, chain: chain)
    }

    /// `chain[i]` is the hash of version `firstVersion + i`. A suffix must still contain the persisted head and agree with it.
    public func acceptDropChain(object: String, firstVersion: UInt32, chain: [Data]) async throws {
        try StoreLayout.validate(ws: object)
        guard !chain.isEmpty, chain.count <= 1024, firstVersion >= 1, Int64(firstVersion) + Int64(chain.count) - 1 <= 1024 else { throw DropStoreError.rollback }
        let first = Int(firstVersion), last = first + chain.count - 1
        let layout = self.layout, ws = self.ws, generation = self.generation
        try await database().transaction { tx in
            try Self.withDropFiles(layout: layout, ws: ws, generation: generation) { directory in
                if let previous = try tx.query("SELECT version,hash FROM drop_heads WHERE object=?", [.text(object)]).first {
                    guard let n = previous.int("version"), Int(n) >= first, Int(n) <= last,
                          previous.blob("hash") == chain[Int(n) - first] else { throw DropStoreError.rollback }
                } else if first > 1 { throw DropStoreError.rollback }
                try tx.execute("INSERT INTO drop_heads(object,version,hash) VALUES(?,?,?) ON CONFLICT(object) DO UPDATE SET version=excluded.version,hash=excluded.hash",
                               [.text(object), .int(Int64(last)), .blob(chain.last!)])
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

    /// Removes the local plaintext download of exactly these objects (every version) and clears their retention columns. Every other
    /// object's file, retention and chain head are untouched; unknown objects are a no-op. Heads stay: a purge never rewinds the chain.
    public func purgeDownloads(objects: Set<String>) async throws {
        guard !objects.isEmpty else { return }
        for object in objects { try StoreLayout.validate(ws: object) }
        let layout = self.layout, ws = self.ws, generation = self.generation
        try await database().transaction { tx in
            try Self.withDropFiles(layout: layout, ws: ws, generation: generation) { directory in
                for object in objects {
                    try tx.execute("UPDATE drop_heads SET file_version=NULL,file_expires_ms=NULL,downloaded_at=NULL WHERE object=?", [.text(object)])
                }
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where objects.contains(where: { file.lastPathComponent.hasPrefix($0 + "-") }) { try FileManager.default.removeItem(at: file) }
            }
        }
    }

    /// Removes the local plaintext download of every object NOT in `keep` (the objects a complete verified list walk showed live). Heads
    /// and signed descriptors stay: a purge never rewinds the chain. Files of objects in `keep` and their retention are untouched.
    public func purgeDownloads(keeping keep: Set<String>) async throws {
        for object in keep { try StoreLayout.validate(ws: object) }
        let layout = self.layout, ws = self.ws, generation = self.generation
        try await database().transaction { tx in
            try Self.withDropFiles(layout: layout, ws: ws, generation: generation) { directory in
                for row in try tx.query("SELECT object FROM drop_heads") {
                    guard let object = row.text("object"), !keep.contains(object) else { continue }
                    try tx.execute("UPDATE drop_heads SET file_version=NULL,file_expires_ms=NULL,downloaded_at=NULL WHERE object=?", [.text(object)])
                }
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where !keep.contains(where: { file.lastPathComponent.hasPrefix($0 + "-") }) { try FileManager.default.removeItem(at: file) }
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


/// The relay push registration of one workspace (P3-D40). Not a secret (the token is an APNs address, not a credential), but it lives in
/// the workspace store so the realm fence guards its writes and the workspace wipe removes it.
public struct PushRegistrationRow: Equatable, Sendable {
    public let env: String
    public let registrationID: String
    public let token: String
    public let confirmedMs: Int64?
    public init(env: String, registrationID: String, token: String, confirmedMs: Int64?) {
        self.env = env; self.registrationID = registrationID; self.token = token; self.confirmedMs = confirmedMs
    }
}

extension WorkspaceContainer {
    public func pushRegistration(env: String) async throws -> PushRegistrationRow? {
        try await database().query("SELECT env, registration_id, token, confirmed_ms FROM push_registrations WHERE env=?", [.text(env)]).first.flatMap {
            guard let e = $0.text("env"), let id = $0.text("registration_id"), let t = $0.text("token") else { return nil }
            return PushRegistrationRow(env: e, registrationID: id, token: t, confirmedMs: $0.int("confirmed_ms"))
        }
    }

    /// Records the id and token about to be sent (unconfirmed). Replaces the row of this environment.
    public func savePushRegistration(env: String, registrationID: String, token: String) async throws {
        try await database().execute("INSERT INTO push_registrations(env, registration_id, token, confirmed_ms) VALUES(?,?,?,NULL) ON CONFLICT(env) DO UPDATE SET registration_id=excluded.registration_id, token=excluded.token, confirmed_ms=NULL",
                                     [.text(env), .text(registrationID), .text(token)])
    }

    /// The relay answered 200 for exactly this id: only then is it confirmed.
    public func confirmPushRegistration(env: String, registrationID: String, nowMs: Int64) async throws {
        try await database().execute("UPDATE push_registrations SET confirmed_ms=? WHERE env=? AND registration_id=?", [.int(nowMs), .text(env), .text(registrationID)])
    }

    public func clearPushRegistrations() async throws {
        try await database().execute("DELETE FROM push_registrations", [])
    }
}
