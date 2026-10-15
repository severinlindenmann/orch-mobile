import Foundation
import Testing
@testable import OrchStore

// Slice 2b: the index's pairing tables (migration 2). A pairing row holds no secret; a verified join commits the workspace row, its
// profile and the removal of the pairing row in one transaction.

struct PairingTablesTests {
    func profile(_ ws: String, name: String = "Laptop") -> WorkspaceProfile {
        WorkspaceProfile(ws: ws, name: name, description: "d", origin: "https://relay.demo.invalid", clientHosted: true, hostedMarker: true, hostedBy: "(unknown)",
                         wskPub: "w", pkPub: "p", ownerPerson: "o", cardSeq: 1, listSeq: 2, epoch: 1, scopes: ["look", "decide"], card: "{}", joinedMs: 5)
    }

    @Test func migrationAddsPairingTablesAndKeepsTheOldOnes() async throws {
        let dir = tempDir()
        let index = try await WorkspaceIndex(layout: makeLayout(dir, realm: "demo"))
        #expect(try await index.db.appliedMigrations() == [1, 2, 3])
        for t in ["pairings", "workspace_profiles", "workspaces", "tombstones"] {
            #expect(try await index.db.query("SELECT name FROM sqlite_master WHERE name=?", [.text(t)]).count == 1, "\(t)")
        }
        // reopening is idempotent
        await index.close()
        let again = try await WorkspaceIndex(layout: makeLayout(dir, realm: "demo"))
        #expect(try await again.db.appliedMigrations() == [1, 2, 3])
    }

    @Test func upgradeFromAVersion2DatabaseAddsCreatedKeys() async throws {
        let dir = tempDir()
        let layout = try makeLayout(dir, realm: "demo")
        try layout.prepareRealm()
        // a database exactly as migration 2 (the original text) left it, with a pairing row in it
        let old = try SQLiteDatabase(url: layout.indexURL)
        try await old.migrate(Array(WorkspaceIndex.migrations.prefix(2)))
        try await old.execute("INSERT INTO meta(key,value) VALUES('realm','demo')")
        try await old.execute("INSERT INTO pairings(ws, offer, generation, origin, phase, started_ms, updated_ms) VALUES(?,?,?,?,?,?,?)",
                              [.text(A), .text(B), .int(2), .text("o"), .text("connecting"), .int(1), .int(2)])
        #expect(try await old.query("SELECT name FROM pragma_table_info('pairings') WHERE name='created_keys'").isEmpty)
        await old.close()
        let index = try await WorkspaceIndex(layout: layout)
        #expect(try await index.db.appliedMigrations() == [1, 2, 3])
        let row = try #require(try await index.pairing(ws: A))
        #expect(row.generation == 2 && row.createdKeys == false)           // existing rows default to "not ours"
        var r = row; r.createdKeys = true
        try await index.savePairing(r)
        #expect(try await index.pairing(ws: A)?.createdKeys == true)
    }

    @Test func upgradeFromTheFirstBuildsVersion2WithCreatedKeys() async throws {
        let dir = tempDir()
        let layout = try makeLayout(dir, realm: "demo")
        try layout.prepareRealm()
        let old = try SQLiteDatabase(url: layout.indexURL)
        var m = Array(WorkspaceIndex.migrations.prefix(2))
        m[1] = Migration(version: 2, statements: m[1].statements.map {
            $0.contains("CREATE TABLE pairings") ? $0.replacingOccurrences(of: "updated_ms INTEGER NOT NULL)", with: "updated_ms INTEGER NOT NULL, created_keys INTEGER NOT NULL DEFAULT 0)") : $0 })
        try await old.migrate(m)
        try await old.execute("INSERT INTO meta(key,value) VALUES('realm','demo')")
        try await old.execute("INSERT INTO pairings(ws, offer, generation, origin, phase, started_ms, updated_ms, created_keys) VALUES(?,?,?,?,?,?,?,1)",
                              [.text(A), .text(B), .int(2), .text("o"), .text("connecting"), .int(1), .int(2)])
        await old.close()
        let index = try await WorkspaceIndex(layout: layout)
        #expect(try await index.db.appliedMigrations() == [1, 2, 3])
        #expect(try await index.pairing(ws: A)?.createdKeys == true)
    }

    @Test func pairingRowRoundTripAndTerminalAlarm() async throws {
        let index = try await WorkspaceIndex(layout: makeLayout(tempDir(), realm: "demo"))
        let r = PairingRow(ws: A, offer: B, generation: 3, origin: "https://relay.demo.invalid", phase: "comparing_host", startedMs: 10, updatedMs: 11)
        try await index.savePairing(r)
        #expect(try await index.pairing(ws: A) == r)
        var alarm = r; alarm.phase = "alarm"; alarm.terminal = "alarm:r1_challenge"; alarm.detail = "Demo Mac"; alarm.updatedMs = 12
        try await index.savePairing(alarm)                                   // replaces the row: one pairing per workspace
        #expect(try await index.pairings() == [alarm])
        try await index.deletePairing(ws: A)
        #expect(try await index.pairings().isEmpty)
        await #expect(throws: LayoutError.self) { try await index.savePairing(PairingRow(ws: "x", offer: B, generation: 1, origin: "o", phase: "p", startedMs: 0, updatedMs: 0)) }
    }

    @Test func commitJoinIsAtomic() async throws {
        let index = try await WorkspaceIndex(layout: makeLayout(tempDir(), realm: "demo"))
        try await index.savePairing(PairingRow(ws: A, offer: B, generation: 1, origin: "o", phase: "joining", startedMs: 0, updatedMs: 0))
        try await index.commitJoin(generation: 1, profile: profile(A))
        #expect(try await index.workspaces().map(\.ws) == [A])
        #expect(try await index.pairing(ws: A) == nil)                        // the pending row went in the same transaction
        let p = try #require(try await index.profile(ws: A))
        #expect(p == profile(A))
        // a workspace removed at this generation cannot be joined again (stale rejoin); the pairing row stays for the caller to erase
        let g = try await index.recordTombstone(ws: A, generation: 1)
        try await index.removeWorkspaceRow(ws: A)
        #expect(try await index.profile(ws: A) == nil)                        // the profile goes with the workspace row
        try await index.savePairing(PairingRow(ws: A, offer: B, generation: 1, origin: "o", phase: "joining", startedMs: 0, updatedMs: 0))
        await #expect(throws: StoreError.workspaceRemoved(ws: A, generation: 1)) { try await index.commitJoin(generation: g, profile: profile(A)) }
        let left = try await index.workspaces(), prof = try await index.profile(ws: A), row = try await index.pairing(ws: A)
        #expect(left.isEmpty && prof == nil && row != nil)
        // a rejoin uses a later generation
        #expect(try await index.nextGeneration(ws: A) == g + 1)
        // ownership: without the live pairing row of that generation nothing commits (a cancelled or erased pairing cannot be revived)
        await #expect(throws: StoreError.pairingNotOwned(ws: A, generation: g + 1)) { try await index.commitJoin(generation: g + 1, profile: profile(A)) }
        try await index.savePairing(PairingRow(ws: A, offer: B, generation: g + 1, origin: "o", phase: "joining", startedMs: 0, updatedMs: 0))
        var alarmRow = PairingRow(ws: A, offer: B, generation: g + 1, origin: "o", phase: "alarm", terminal: "alarm:x", startedMs: 0, updatedMs: 0)
        try await index.savePairing(alarmRow)
        await #expect(throws: StoreError.pairingNotOwned(ws: A, generation: g + 1)) { try await index.commitJoin(generation: g + 1, profile: profile(A)) }
        alarmRow.terminal = nil
        try await index.savePairing(alarmRow)
        try await index.commitJoin(generation: g + 1, profile: profile(A, name: "Laptop 2"))
        let name = try await index.profile(ws: A)?.name, gen = try await index.workspaces().first?.generation
        #expect(name == "Laptop 2" && gen == g + 1)
    }
}
