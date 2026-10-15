import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchStore
@testable import OrchProtocol

/// A wall clock that runs one action the first time it is read after arming: a deterministic interleaving point inside
/// `WorkspaceSession.prepare` (after the generation was checked, before the sealing transaction).
final class TripWall: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var action: (@Sendable () -> Void)?
    let base: TestClock
    init(base: TestClock) { self.base = base }
    func arm(_ a: @escaping @Sendable () -> Void) { lock.withLock { armed = true; action = a } }
    var nowMs: Int64 {
        let a: (@Sendable () -> Void)? = lock.withLock { defer { armed = false; action = nil }; return armed ? action : nil }
        a?()
        return base.nowMs
    }
}

@Suite struct RealmFenceFlowTests {
    /// (a) The realm ends between the session's check and its signing/sealing transaction: nothing is signed, stored or sent.
    @Test func aSendInFlightWhenTheRealmEndsSignsAndSendsNothing() async throws {
        let w = try await World.make()
        let index = w.env.index
        try await index.addWorkspace(ws: w.ws.hex, generation: 1)
        let container = try await WorkspaceContainer(index: index, ws: w.ws.hex, generation: 1)
        let pclock = TestClock(wallStartMs: w.clock.nowMs)
        let wall = TripWall(base: pclock)
        let cfg = WorkspaceSessionConfig(context: w.env.context, workspace: w.ws, generation: 1, identity: w.env.device, wsk: w.host.wskPublic,
                                         container: container, vault: w.vault.scoped(to: .demo), transport: w.transport, clock: pclock, wall: wall)
        let session = try await WorkspaceSession(cfg)
        try await session.refreshGrants()
        let before = await w.relay.storedBodyCount()
        let ctx = w.env.context
        wall.arm { ctx.invalidate() }
        await #expect(throws: RealmViolation.staleGeneration) { _ = try await session.exchange(meta: httpGet) }
        #expect(await w.relay.storedBodyCount() == before)
        let db = try await container.database()
        #expect(try await db.query("SELECT rid FROM bridge_requests").isEmpty)
        #expect(try await db.query("SELECT key FROM meta WHERE key='next_seq'").isEmpty)
        // and nothing more can be started on the retained handle
        await #expect(throws: (any Error).self) { _ = try await session.exchange(meta: httpGet) }
        #expect(try await db.query("SELECT rid FROM bridge_requests").isEmpty)
    }

    /// A runtime owns exactly one RealmContext: a session whose transport belongs to another generation is refused.
    @Test func aSessionOnAnotherRealmsTransportIsRefused() async throws {
        let w = try await World.make(), other = try await World.make()
        try await w.env.index.addWorkspace(ws: w.ws.hex, generation: 1)
        let container = try await WorkspaceContainer(index: w.env.index, ws: w.ws.hex, generation: 1)
        let clock = TestClock()
        let cfg = WorkspaceSessionConfig(context: w.env.context, workspace: w.ws, generation: 1, identity: w.env.device, wsk: w.host.wskPublic,
                                         container: container, vault: w.vault.scoped(to: .demo), transport: other.transport, clock: clock, wall: clock)
        await #expect(throws: RealmViolation.wrongTransport) { _ = try await WorkspaceSession(cfg) }
    }

    /// (b) A join whose realm ends just before the commit commits nothing: no workspace row, profile, vault item or files.
    @Test func aJoinCompletingAfterInvalidateCommitsNothing() async throws {
        let h = try await PairHarness.make(.firstTime)
        try await h.driveToJoining()
        let ctx = h.env.context
        await h.coordinator.setHook { name in if name == "install.precommit" { ctx.invalidate() } }
        await h.coordinator.poll()
        let s = await h.coordinator.state
        if case .ready = s { Issue.record("join completed after the realm ended") }
        #expect(try await h.env.index.workspaces().isEmpty)
        #expect(try await h.env.index.profile(ws: h.wsHex) == nil)
        #expect(!h.wsDirExists, "dir")
        // The participant's own rollback deletes are fenced too (a successor realm shares these ids), so what it staged in the vault
        // stays until the teardown path, which holds an unfenced view, wipes the realm.
        try h.vault.wipe(realm: .demo)
        #expect(h.vaultItems.isEmpty && h.deviceCert == nil)
        if case .failed(.realm(.staleGeneration)) = s {} else { Issue.record("unexpected state \(s)") }
    }

    /// The realm's sessions and coordinators are registered and `shutdownParticipants` ends them (bounded) after `invalidate`.
    @Test func shutdownEndsEveryRegisteredSessionAndCoordinator() async throws {
        let w = try await World.make()
        let phone = try await w.makePhone()
        let h = try await PairHarness.make(.firstTime)
        #expect(w.env.context.generation.participantCount == 1)
        #expect(h.env.context.generation.participantCount == 1)
        await phone.session.startViews()
        w.env.context.invalidate()
        await w.env.context.shutdownParticipants(timeout: .seconds(10))
        h.env.context.invalidate()
        await h.env.context.shutdownParticipants(timeout: .seconds(10))
        let st = await h.coordinator.state
        #expect(st == .cancelled || st == .idle)
    }
}
