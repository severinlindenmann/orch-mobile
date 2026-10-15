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
        let t1 = Thread { try? g.perform { inside.signal(); release.wait(); wrote.set() } ; done.signal() }
        t1.start()
        inside.wait()
        let invalidated = LockedFlag()
        let doneInv = DispatchSemaphore(value: 0)
        let t2 = Thread { g.invalidate(); invalidated.set(); doneInv.signal() }
        t2.start()
        // invalidate is parked behind the body: the flag stays clear until the body is released (no sleep: ordering is by the lock)
        #expect(!invalidated.value)
        release.signal(); done.wait(); doneInv.wait()
        #expect(wrote.value && invalidated.value)
        #expect(throws: RealmViolation.staleGeneration) { try g.perform { Issue.record("ran after invalidate") } }
    }

    @Test func vaultPutsAndStoreWritesAreFenced() async throws {
        let c = try RealmContext.live(origin: "https://relay.example.org")
        let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend()).scoped(to: .live).fenced(by: c.generation)
        try vault.put(Data([1]), purpose: "a")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("orch-fence-" + UUID().uuidString)
        let layout = try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                                     shareGroupRoot: base.appendingPathComponent("share"), realm: "live")
        let index = try await WorkspaceIndex(layout: layout)
        try await index.addWorkspace(ws: ws.hex, generation: 1)
        let container = try await WorkspaceContainer(index: index, ws: ws.hex, generation: 1)
        try await container.bind(fence: c.generation)
        let db = try await container.database()
        try await db.execute("INSERT INTO meta(key,value) VALUES('k',1)")
        c.invalidate()
        #expect(throws: RealmViolation.staleGeneration) { try vault.put(Data([2]), purpose: "a") }
        #expect(try vault.get(purpose: "a") == Data([1]))
        await #expect(throws: RealmViolation.staleGeneration) { try await db.execute("INSERT INTO meta(key,value) VALUES('k2',1)") }
        await #expect(throws: RealmViolation.staleGeneration) { try await db.transaction { tx in try tx.execute("INSERT INTO meta(key,value) VALUES('k3',1)") } }
        let keys = try await db.query("SELECT key FROM meta WHERE key IN ('k','k2','k3')").compactMap { $0.text("key") }
        #expect(keys == ["k"])
        try vault.delete(purpose: "a")                          // removal is never refused
        await #expect(throws: StoreError.fenceMismatch) { try await container.bind(fence: RealmGeneration()) }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let l = NSLock(); private var v = false
    func set() { l.withLock { v = true } }
    var value: Bool { l.withLock { v } }
}
