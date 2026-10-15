import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchStore

/// The OrchKit side of the app's `LiveRuntime`: restoring sessions from a committed join, the realm-wide wipe, and the transport factory.
@Suite struct LiveRuntimeSupportTests {
    /// A Demo environment with one workspace joined through the real pairing flow (the same data a Live join commits).
    private func joined() async throws -> PairHarness {
        let h = try await PairHarness.make(.firstTime)
        try await h.driveToJoining()
        #expect(isReady(try await h.drive(until: { $0.isTerminal })))
        return h
    }

    private func restoreConfig(_ h: PairHarness) -> RestoreConfig {
        RestoreConfig(context: h.env.context, transport: h.env.transport, index: h.env.index, vault: h.vault, custody: h.custody, clock: h.clock, wall: h.clock)
    }

    @Test func restoreRebuildsTheCommittedWorkspaceOnTheSingleContext() async throws {
        let h = try await joined()
        let ws = h.host.workspace
        guard case .ready(let first) = await h.coordinator.state else { Issue.record("not ready"); return }
        // A relaunch: everything of the first run is gone, the durable state remains.
        await h.env.context.shutdownParticipants()
        let out = try await WorkspaceRestoration.restore(restoreConfig(h))
        #expect(out.skipped.isEmpty)
        let restored = try #require(out.handles.first)
        #expect(out.handles.count == 1)
        #expect(restored.joined.workspace == ws && restored.joined.generation == first.joined.generation)
        #expect(restored.joined.name == first.joined.name && restored.joined.scopes == first.joined.scopes && restored.joined.epoch == first.joined.epoch)
        #expect(restored.joined.session !== first.joined.session)
        // The restored session is a participant of the one context: its shutdown is covered by the realm's.
        #expect(h.env.context.isCurrent)
        await h.env.context.shutdownParticipants()
    }

    @Test func restoreSkipsARecordItCannotVerifyAndNeverInventsKeys() async throws {
        let h = try await joined()
        await h.env.context.shutdownParticipants()
        // A different origin in the profile: the install has exactly one origin, so this workspace is not rebuilt (and not erased).
        let ws = h.host.workspace.hex
        var p = try #require(try await h.env.index.profile(ws: ws))
        p.origin = "https://other.example.org"
        let gen = try #require(try await h.env.index.workspaces().first).generation
        try await h.env.index.savePairing(PairingRow(ws: ws, offer: String(repeating: "0", count: 32), generation: gen, origin: p.origin, phase: "x", startedMs: 0, updatedMs: 0))
        try await h.env.index.commitJoin(generation: gen, profile: p)
        let out = try await WorkspaceRestoration.restore(restoreConfig(h))
        #expect(out.handles.isEmpty && out.skipped.map(\.reason) == ["origin"])
        #expect(try await h.env.index.workspaces().count == 1)
        // Missing device keys fail the restore as a whole; nothing is created.
        try h.custody.delete(realm: .demo)
        await #expect(throws: (any Error).self) { _ = try await WorkspaceRestoration.restore(restoreConfig(h)) }
        #expect(h.custody.status(realm: .demo) == .missing)
    }

    @Test func restoreRefusesAStaleRealm() async throws {
        let h = try await joined()
        h.env.context.invalidate()
        await #expect(throws: RealmViolation.staleGeneration) { _ = try await WorkspaceRestoration.restore(restoreConfig(h)) }
    }

    @Test func realmWipeRemovesStagedItemsOfAnInvalidatedJoinThatNoIndexRowNames() async throws {
        let w = try await World.make()
        let layout = w.env.layout
        let keys = w.vault
        let push = SecretVault(group: .push, backend: InMemoryVaultBackend())
        let staged = ID16.random().hex                                  // staged by a join that never committed: in the vault, in no index row
        try keys.put(Data("k".utf8), for: SecretID(realm: .demo, ws: staged, purpose: "pairing"))
        try push.put(Data("p".utf8), for: SecretID(realm: .demo, ws: staged, purpose: "push"))
        let other = try SecretID(realm: .live, ws: staged, purpose: "pairing")
        try keys.put(Data("live".utf8), for: other)                    // another realm's item is never addressed
        let stagedDir = try layout.stagedJobsDir(staged), stateDir = try layout.pushStateDir(staged)
        try FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try await w.env.index.addWorkspace(ws: staged, generation: 1)
        w.env.generation.invalidate()
        let config = RealmWipe.Config(realm: .demo, layout: layout, custody: w.custody, vaults: [keys, push])
        try await RealmWipe(config).run(index: w.env.index)
        let keyIDs = try keys.ids(), pushIDs = try push.ids()
        #expect(keyIDs.allSatisfy { $0.realm == .live } && pushIDs.isEmpty)
        #expect(w.custody.status(realm: .demo) == .missing)
        #expect(!FileManager.default.fileExists(atPath: layout.realmDir.path))
        #expect(!FileManager.default.fileExists(atPath: stagedDir.path))
        #expect(!FileManager.default.fileExists(atPath: stateDir.path))
        _ = other
        // Run again with no index (the next launch): nothing left to do, nothing fails.
        try await RealmWipe(config).run(index: nil)
    }

    @Test func realmWipeWithoutARunningRuntimeFinishesAHalfDoneWipe() async throws {
        let w = try await World.make()
        let layout = w.env.layout
        let ws = ID16.random().hex
        try await w.env.index.addWorkspace(ws: ws, generation: 1)
        let flaky = CountingHooks(failures: 1)
        let config = RealmWipe.Config(realm: .demo, layout: layout, custody: w.custody, vaults: [w.vault], hooks: flaky)
        await #expect(throws: (any Error).self) { try await RealmWipe(config).run(index: w.env.index) }
        #expect(FileManager.default.fileExists(atPath: layout.realmDir.path))          // the directory stays until the workspaces are wiped
        await w.env.index.close()
        // The next launch has no index object: the wipe opens the persisted one and resumes the tombstoned workspace.
        try await RealmWipe(config).run(index: nil)
        #expect(!FileManager.default.fileExists(atPath: layout.realmDir.path))
    }

    @Test func aRejoinAfterLeaveStartsAboveTheBurntGeneration() async throws {
        let w = try await World.make()
        let ws = ID16.random().hex
        try await w.env.index.addWorkspace(ws: ws, generation: 1)
        try await LocalWipe(index: w.env.index).wipe(ws: ws, generation: 1)
        let config = RealmWipe.Config(realm: .demo, layout: w.env.layout, custody: w.custody, vaults: [w.vault])
        try await RealmWipe(config).run(index: w.env.index)             // the index (and its tombstone table) is gone
        let fresh = try await WorkspaceIndex(layout: w.env.layout)
        #expect(try await fresh.nextGeneration(ws: ws) == 2)           // the coordination files still say generation 1 is removed
    }

    @Test func theLiveTransportIsLiveOnlyAndSharesTheContextGeneration() throws {
        let ctx = try RealmContext.live(origin: "https://relay.example.org")
        let t = try LiveTransport.make(context: ctx)
        #expect(t.context.generation === ctx.generation && t.context.origin == "https://relay.example.org")
        ctx.invalidate()
        #expect(!t.context.isCurrent)
    }
}
