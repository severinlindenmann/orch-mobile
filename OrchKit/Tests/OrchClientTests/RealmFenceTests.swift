import Foundation
import Testing
import OrchCustody
import OrchProtocol
import OrchStore
@testable import OrchClient

/// The realm generation fence (docs/live-mode.md, PR B blockers 1-2), on a LIVE context: every context has a generation.
@Suite struct RealmFenceTests {
    @Test func aLiveContextHasAGenerationAndInvalidateIsSynchronous() throws {
        let c = try RealmContext.live(origin: "https://relay.example.org")
        #expect(c.isCurrent)
        c.invalidate()
        #expect(!c.isCurrent)
        #expect(throws: RealmViolation.staleGeneration) { try c.generation.check() }
    }

    @Test func aTransportSendAfterInvalidateThrowsWithoutIO() async throws {
        let c = try RealmContext.live(origin: "https://relay.example.org")
        let (t, sender) = try routed(c)
        _ = try await t.challenge()
        #expect(sender.requests.count == 1)
        c.invalidate()
        await #expect(throws: TransportError.realm(.staleGeneration)) { _ = try await t.challenge() }
        await #expect(throws: TransportError.realm(.staleGeneration)) { _ = try await t.memberList(workspaceID: ws, session: session) }
        #expect(sender.requests.count == 1)
    }

    @Test func leasesCannotSignOrAgreeAfterInvalidateEvenIfHeld() throws {
        let c = try RealmContext.live(origin: "https://relay.example.org")
        let custody = DefaultCustody.make(vault: SecretVault(group: .keys, backend: InMemoryVaultBackend()))
        let id = try c.deviceIdentity(custody: custody, createIfMissing: true)
        let sig = id.sig, kx = id.kx                            // references held across the invalidation
        _ = try sig.rawSignature(over: Data([1]))
        _ = try kx.sharedSecret(with: id.kx.publicKey)
        c.invalidate()
        #expect(throws: RealmViolation.staleGeneration) { _ = try sig.rawSignature(over: Data([1])) }
        #expect(throws: RealmViolation.staleGeneration) { _ = try kx.sharedSecret(with: id.kx.publicKey) }
        // an identity re-leased from the raw custody keys is dead as well; custody itself is not reachable through the context
        let raw = try custody.load(realm: .live)
        let again = c.leased(raw)
        #expect(throws: RealmViolation.staleGeneration) { _ = try again.sig.rawSignature(over: Data([1])) }
        #expect(throws: RealmViolation.staleGeneration) { _ = try c.deviceIdentity(custody: custody, createIfMissing: false) }
    }

    @Test func invalidateWaitsForACheckAndActInFlight() throws {
        let g = RealmGeneration()
        let inside = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let wrote = LockedFlag()
        Thread { try? g.perform { inside.signal(); release.wait(); wrote.set() }; done.signal() }.start()
        inside.wait()
        let started = DispatchSemaphore(value: 0), doneInv = DispatchSemaphore(value: 0)
        let finished = LockedFlag()
        Thread { started.signal(); g.invalidate(); finished.set(); doneInv.signal() }.start()
        started.wait()
        // the flag is already clear (check() sees it without waiting) while the body still holds the gate; invalidate() has not returned
        let deadline = Date().addingTimeInterval(2)
        while g.isCurrent && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        #expect(!g.isCurrent)
        for _ in 0..<50 { Thread.sleep(forTimeInterval: 0.002) }          // bounded observation window: it must stay parked
        #expect(!finished.value)
        #expect(!wrote.value)
        release.signal(); done.wait(); doneInv.wait()
        #expect(wrote.value && finished.value)
        #expect(throws: RealmViolation.staleGeneration) { try g.perform { Issue.record("ran after invalidate") } }
    }

    @Test func registerRefusesOnceInvalid() {
        let g = RealmGeneration()
        let p = StuckParticipant()
        #expect(g.register(p))
        g.invalidate()
        #expect(!g.register(StuckParticipant()))
        #expect(g.participantCount == 1)
    }

    /// M1: a participant that never finishes does not hold shutdown past the deadline.
    @Test func shutdownIsBoundedByTheDeadlineWhenAParticipantIsStuck() async {
        let g = RealmGeneration()
        let stuck = StuckParticipant(), fine = StuckParticipant(hangs: false)
        g.register(stuck); g.register(fine)
        g.invalidate()
        let t0 = ContinuousClock.now
        await g.shutdownParticipants(timeout: .milliseconds(300))
        let took = ContinuousClock.now - t0
        #expect(took >= .milliseconds(250) && took < .seconds(3))
        #expect(fine.didShutDown.value)
        stuck.free()
    }

    @Test func shutdownReturnsEarlyWhenEveryoneFinishes() async {
        let g = RealmGeneration()
        let a = StuckParticipant(hangs: false), b = StuckParticipant(hangs: false)
        g.register(a); g.register(b)
        g.invalidate()
        let t0 = ContinuousClock.now
        await g.shutdownParticipants(timeout: .seconds(30))
        #expect(ContinuousClock.now - t0 < .seconds(5))
        #expect(a.didShutDown.value && b.didShutDown.value)
    }

    /// M2: a session whose transport belongs to another context's generation is refused.
    @Test func aStoreBoundToAnotherFenceIsRefused() async throws {
        let c = try RealmContext.live(origin: "https://relay.example.org"), other = try RealmContext.live(origin: "https://relay.example.org")
        let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend()).scoped(to: .live, fence: c.generation)
        #expect(throws: VaultError.fenceMismatch) { _ = try vault.fenced(by: other.generation) }
        let (t, _) = try routed(other)
        #expect(t.context.generation !== c.generation)
    }

    /// M4: a bind that happens while the database is being (re)opened applies to the database that open produces.
    @Test func aBindDuringAnOpenAppliesToTheOpenedDatabase() async throws {
        let c = try RealmContext.live(origin: "https://relay.example.org")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("orch-fence-" + UUID().uuidString)
        let layout = try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                                     shareGroupRoot: base.appendingPathComponent("share"), realm: "live")
        let index = try await WorkspaceIndex(layout: layout)
        try await index.addWorkspace(ws: ws.hex, generation: 1)
        let container = try await WorkspaceContainer(index: index, ws: ws.hex, generation: 1)
        let early = try await container.database()                 // handle taken before any bind
        await container.suspend()
        async let reopened: Void = container.resume()
        try container.bind(fence: c.generation)                   // races the open: either order must end fenced
        try await reopened
        let late = try await container.database()
        c.invalidate()
        await #expect(throws: RealmViolation.staleGeneration) { try await late.execute("INSERT INTO meta(key,value) VALUES('x',1)") }
        _ = early
        // a handle taken before the bind is fenced too (the box is read at each write)
        let again = try await WorkspaceContainer(index: index, ws: ws.hex, generation: 1)
        let pre = try await again.database()
        try again.bind(fence: c.generation)
        await #expect(throws: RealmViolation.staleGeneration) { try await pre.execute("INSERT INTO meta(key,value) VALUES('y',1)") }
    }

    @Test func aStaleRealmCreatesNoWorkspaceFiles() async throws {
        let c = try RealmContext.live(origin: "https://relay.example.org")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("orch-fence-" + UUID().uuidString)
        let layout = try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                                     shareGroupRoot: base.appendingPathComponent("share"), realm: "live")
        let index = try await WorkspaceIndex(layout: layout, fence: c.generation)
        c.invalidate()
        await #expect(throws: RealmViolation.staleGeneration) { try await index.addWorkspace(ws: ws.hex, generation: 1) }
        await #expect(throws: RealmViolation.staleGeneration) {
            _ = try await WorkspaceContainer(index: index, ws: ws.hex, generation: 1, fence: c.generation)
        }
        let wsDirURL = try layout.wsDir(ws.hex)
        #expect(!FileManager.default.fileExists(atPath: wsDirURL.path))
        #expect(try await index.workspaces().isEmpty)
        // wipe-type writes still work on a stale realm
        _ = try await index.recordTombstone(ws: ws.hex, generation: 1)
    }

    @Test func queryRefusesWrites() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("orch-fence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(url: base.appendingPathComponent("q.sqlite"), fileProtection: false)
        try await db.execute("CREATE TABLE t(a INTEGER)")
        await #expect(throws: (any Error).self) { _ = try await db.query("INSERT INTO t(a) VALUES(1)") }
        #expect(try await db.query("SELECT a FROM t").isEmpty)
        for bad in ["BEGIN", "PRAGMA user_version=1", "PRAGMA user_version", "ATTACH DATABASE ':memory:' AS x", "SAVEPOINT s", "DELETE FROM t",
                    "WITH x AS (SELECT 1) INSERT INTO t(a) SELECT * FROM x"] {
            await #expect(throws: (any Error).self, "\(bad)") { _ = try await db.query(bad) }
        }
        #expect(try await db.query("WITH x(a) AS (SELECT 1) SELECT a FROM x").count == 1)
        #expect(try await db.query("SELECT * FROM pragma_journal_mode").count == 1)
        try await db.execute("INSERT INTO t(a) VALUES(2)")          // the connection is not left in a denied state
        #expect(try await db.query("SELECT a FROM t").count == 1)
    }

    @Test func vaultPutsAndStoreWritesAreFenced() async throws {
        let c = try RealmContext.live(origin: "https://relay.example.org")
        let raw = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let vault = raw.scoped(to: .live, fence: c.generation)
        try vault.put(Data([1]), purpose: "a")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("orch-fence-" + UUID().uuidString)
        let layout = try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                                     shareGroupRoot: base.appendingPathComponent("share"), realm: "live")
        let index = try await WorkspaceIndex(layout: layout)
        try await index.addWorkspace(ws: ws.hex, generation: 1)
        let container = try await WorkspaceContainer(index: index, ws: ws.hex, generation: 1)
        try container.bind(fence: c.generation)
        let db = try await container.database()
        try await db.execute("INSERT INTO meta(key,value) VALUES('k',1)")
        c.invalidate()
        #expect(throws: RealmViolation.staleGeneration) { try vault.put(Data([2]), purpose: "a") }
        #expect(try vault.get(purpose: "a") == Data([1]))
        await #expect(throws: RealmViolation.staleGeneration) { try await db.execute("INSERT INTO meta(key,value) VALUES('k2',1)") }
        await #expect(throws: RealmViolation.staleGeneration) { try await db.transaction { tx in try tx.execute("INSERT INTO meta(key,value) VALUES('k3',1)") } }
        let keys = try await db.query("SELECT key FROM meta WHERE key IN ('k','k2','k3')").compactMap { $0.text("key") }
        #expect(keys == ["k"])
        // deletes and wipes of a participant's view are fenced too (a successor realm's items share these ids) ...
        #expect(throws: RealmViolation.staleGeneration) { try vault.delete(purpose: "a") }
        #expect(throws: RealmViolation.staleGeneration) { try vault.wipe() }
        #expect(try vault.get(purpose: "a") == Data([1]))
        // ... while the reset/teardown path's unfenced view still removes
        try raw.scoped(to: .live).delete(purpose: "a")
        #expect((try? raw.scoped(to: .live).get(purpose: "a")) == nil)
        #expect(throws: StoreError.fenceMismatch) { try container.bind(fence: RealmGeneration()) }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let l = NSLock(); private var v = false
    func set() { l.withLock { v = true } }
    var value: Bool { l.withLock { v } }
}

/// A participant whose shutdown never returns (until `free`) or returns at once.
final class StuckParticipant: RealmParticipant, @unchecked Sendable {
    let didShutDown = LockedFlag()
    private let hangs: Bool
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?
    private var freed = false
    init(hangs: Bool = true) { self.hangs = hangs }
    func realmShutdown() async {
        if hangs {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let go = lock.withLock { () -> Bool in if freed { return true }; cont = c; return false }
                if go { c.resume() }
            }
        }
        didShutDown.set()
    }
    func free() { let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in freed = true; defer { cont = nil }; return cont }; c?.resume() }
}
