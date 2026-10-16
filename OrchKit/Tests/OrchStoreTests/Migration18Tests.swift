import Foundation
import Testing
@testable import OrchStore

/// Migration 18 (B10): `pe_reviews` is rebuilt so its CHECK takes the 'gate' kind. The rows, the foreign keys from `pe_attempts`, the unique
/// active index and the landing trigger must all survive it.
struct Migration18Tests {
    @Test func rebuildKeepsRowsKeysIndexAndTrigger() async throws {
        let db = try SQLiteDatabase(url: tempDir().appendingPathComponent("m18.sqlite"))
        try await db.migrate(WorkspaceContainer.migrations.filter { $0.version <= 17 })
        try await db.execute("INSERT INTO pe_reviews(review, kind, log, question, snapshot, current_idem, ver, state, created_ms) VALUES('r1','answer','u1','q1',x'01','i1',1,'active',1)")
        try await db.execute("INSERT INTO pe_reviews(review, kind, log, question, snapshot, current_idem, ver, state, landed_idem, outcome, created_ms) VALUES('r2','new_ticket','u2',NULL,x'02','i2',1,'landed','i2','{}',2)")
        for (idem, review) in [("i1", "r1"), ("i2", "r2")] {
            try await db.execute("INSERT INTO pe_attempts(idem, review, n, origin, event, digest, auth, ulid_ms, signed_wall_ms, signed_offset_ms, state) VALUES(?,?,1,'tap',x'00','d','x',1,1,1,'signed')",
                                 [.text(idem), .text(review)])
        }
        try await db.migrate(WorkspaceContainer.migrations)
        #expect(try await db.appliedMigrations().last == 18)
        #expect(try await db.query("SELECT review, kind FROM pe_reviews ORDER BY review").map { [$0.text("review")!, $0.text("kind")!] } == [["r1", "answer"], ["r2", "new_ticket"]])
        #expect(try await db.query("SELECT idem FROM pe_attempts ORDER BY idem").compactMap { $0.text("idem") } == ["i1", "i2"])
        #expect(try await db.query("SELECT * FROM pragma_foreign_key_check").isEmpty)
        // the child still points at the rebuilt table (a missing parent is refused), and an attempt can be added under the old review
        await #expect(throws: (any Error).self) {
            try await db.execute("INSERT INTO pe_attempts(idem, review, n, origin, event, digest, auth, ulid_ms, signed_wall_ms, signed_offset_ms, state) VALUES('i9','nope',1,'tap',x'00','d','x',1,1,1,'signed')")
        }
        try await db.execute("INSERT INTO pe_attempts(idem, review, n, origin, event, digest, auth, ulid_ms, signed_wall_ms, signed_offset_ms, state) VALUES('i3','r1',2,'tap',x'00','d','x',1,1,1,'signed')")
        // the unique active index (one active review per question) and the landing trigger are back
        await #expect(throws: (any Error).self) {
            try await db.execute("INSERT INTO pe_reviews(review, kind, log, question, snapshot, current_idem, ver, state, created_ms) VALUES('r3','answer','u1','q1',x'01','i3',1,'active',3)")
        }
        await #expect(throws: (any Error).self) { try await db.execute("UPDATE pe_reviews SET state='active' WHERE review='r2'") }
        // the gate kind is taken now, once per active question
        try await db.execute("INSERT INTO pe_reviews(review, kind, log, question, snapshot, current_idem, ver, state, created_ms) VALUES('g1','gate','u3','gate:u3:plan',x'03','i4',1,'active',4)")
        #expect(try await db.query("SELECT count(*) AS n FROM sqlite_master WHERE name IN ('pe_reviews_one_active','pe_reviews_landed')").first?.int("n") == 2)
    }
}
