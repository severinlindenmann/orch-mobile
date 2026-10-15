import Foundation
import Testing
import OrchStore
@testable import OrchClient
@testable import OrchFakeHost

/// Migration 15's triggers and index, each asserted by its OWN refusal message (never "some error").
@Suite struct PersonEventTriggerTests {
    let t = PersonEventWriteTests()

    /// `body` is refused by the trigger whose RAISE text is `message`.
    func refused(_ message: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("not refused (\(message))", sourceLocation: sourceLocation)
        } catch SQLiteError.constraint(_, let m) {
            #expect(m == message, sourceLocation: sourceLocation)
        } catch {
            Issue.record("\(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func aLandingIsFinal() async throws {
        let r = try await t.rig()
        guard case .landed = try await t.answer(r) else { Issue.record("not landed"); return }
        let db = try await r.p.container.database()
        await refused("pe_attempts: landed is final") { try await db.execute("UPDATE pe_attempts SET state='d'") }
        await refused("pe_attempts: landed is final") { try await db.execute("DELETE FROM pe_attempts") }
        await refused("pe_reviews: a landing is final") { try await db.execute("UPDATE pe_reviews SET state='refused'") }
        await refused("pe_reviews: a landing is final") { try await db.execute("UPDATE pe_reviews SET landed_idem='x'") }
        await refused("pe_attempts: signed fields are immutable") { try await db.execute("UPDATE pe_attempts SET event=x'00'") }
        await refused("pe_attempts: evidence is append-only") { try await db.execute("UPDATE pe_attempts SET evidence='[]'") }
        #expect(try await t.attemptStates(r.p) == ["landed"])
    }

    /// A possibly sent attempt: never deleted before it is settled, never signed or discarded again, its marker never falls.
    @Test func aDispatchedAttemptIsKept() async throws {
        let r = try await t.rig()
        await r.w.host.demoHoldNextWrite()
        #expect(try await t.answer(r) == .checking)
        let db = try await r.p.container.database()
        #expect(try await t.rows(r.p, "SELECT dispatched, state FROM pe_attempts").first?.int("dispatched") == 1)
        await refused("pe_attempts: a dispatched attempt is kept until settled") { try await db.execute("DELETE FROM pe_attempts") }
        await refused("pe_attempts: a dispatched attempt is never signed or discarded again") { try await db.execute("UPDATE pe_attempts SET state='signed'") }
        await refused("pe_attempts: a dispatched attempt is never signed or discarded again") { try await db.execute("UPDATE pe_attempts SET state='discarded'") }
        await refused("pe_attempts: dispatched never falls") { try await db.execute("UPDATE pe_attempts SET dispatched=0") }
        // superseded is not settled either: a superseded attempt that was sent may still land late
        try await db.execute("UPDATE pe_attempts SET state='superseded'")
        await refused("pe_attempts: a dispatched attempt is kept until settled") { try await db.execute("DELETE FROM pe_attempts") }
    }

    /// An attempt never sent may be discarded; marking it dispatched in the same breath is refused.
    @Test func anUndispatchedAttemptMayBeDiscarded() async throws {
        let r = try await t.rig()
        r.hooks.fail("post.precharge")
        #expect(try await t.answer(r) == .checking)
        let db = try await r.p.container.database()
        await refused("pe_attempts: a dispatched attempt is never signed or discarded again") {
            try await db.execute("UPDATE pe_attempts SET state='discarded', dispatched=1")
        }
        #expect(try await db.execute("UPDATE pe_attempts SET state='discarded' WHERE dispatched=0") == 1)
    }

    @Test func evidenceIsTrulyAppendOnly() async throws {
        let r = try await t.rig()
        r.hooks.fail("post.precharge")
        #expect(try await t.answer(r) == .checking)
        let db = try await r.p.container.database()
        func set(_ e: String) async throws { try await db.execute("UPDATE pe_attempts SET evidence=?", [.text(e)]) }
        // from the empty array: the first element must start right after `[`
        await refused("pe_attempts: evidence is append-only") { try await set("[,{\"a\":1}]") }
        await refused("pe_attempts: evidence is append-only") { try await set("[]]") }
        try await set("[{\"a\":1}]")
        // a rewrite of the same length, a truncation, a non-comma continuation, a non-array ending, invalid JSON: all refused
        await refused("pe_attempts: evidence is append-only") { try await set("[{\"a\":2}]") }
        await refused("pe_attempts: evidence is append-only") { try await set("[]") }
        await refused("pe_attempts: evidence is append-only") { try await set("[{\"a\":1}{\"b\":2}]") }
        await refused("pe_attempts: evidence is append-only") { try await set("[{\"a\":1},{\"b\":2}]x") }
        await refused("pe_attempts: evidence is append-only") { try await set("[{\"a\":1},]") }
        await refused("pe_attempts: evidence is append-only") { try await set("[{\"a\":1},{\"b\":2}") }
        try await set("[{\"a\":1},{\"b\":2}]")
        #expect(try await t.rows(r.p, "SELECT evidence FROM pe_attempts").first?.text("evidence") == "[{\"a\":1},{\"b\":2}]")
    }

    @Test func oneActiveReviewPerQuestion() async throws {
        let r = try await t.rig()
        r.hooks.fail("post.precharge")
        #expect(try await t.answer(r) == .checking)
        let db = try await r.p.container.database()
        await refused("UNIQUE constraint failed: pe_reviews.question") {
            try await db.execute("INSERT INTO pe_reviews(review, kind, log, question, snapshot, current_idem, ver, state, created_ms) SELECT 'second', kind, log, question, snapshot, current_idem, 1, 'active', created_ms FROM pe_reviews")
        }
        // a finished review of the same question does not count
        try await db.execute("INSERT INTO pe_reviews(review, kind, log, question, snapshot, current_idem, ver, state, created_ms) SELECT 'old', kind, log, question, snapshot, current_idem, 1, 'needs_review', created_ms FROM pe_reviews")
    }

    /// A REPLACE deletes the old row without firing the delete triggers: it is never used on the write tables.
    @Test func noReplaceOnTheWriteTables() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 20)
        let pattern = try NSRegularExpression(pattern: #"(OR\s+REPLACE\s+INTO|REPLACE\s+INTO|UPSERT\s+INTO)\s+pe_"#, options: [.caseInsensitive])
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            #expect(pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil, "\(f.lastPathComponent)")
        }
    }
}
