import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchStore

/// Counts quiesce calls (once per wiped workspace), yields inside it so concurrent callers overlap, and can fail on demand.
final class CountingHooks: WipeHooks, @unchecked Sendable {
    private let lock = NSLock()
    private var _quiesces = 0, _failures: Int
    init(failures: Int = 0) { _failures = failures }
    var quiesces: Int { lock.withLock { _quiesces } }
    func quiesce(realm: String, ws: String) async throws {
        lock.withLock { _quiesces += 1 }
        for _ in 0..<200 { await Task.yield() }
    }
    func purgeSecrets(realm: String, ws: String) async throws {
        let fail: Bool = lock.withLock { if _failures > 0 { _failures -= 1; return true }; return false }
        if fail { throw CocoaError(.fileWriteUnknown) }
    }
}

@Suite struct ResetTests {
    func addWorkspace(_ w: World) async throws -> (ws: String, file: URL) {
        let ws = ID16.random().hex
        try await w.env.index.addWorkspace(ws: ws, generation: 1)
        let file = try w.env.layout.filesDir(ws).appendingPathComponent("n.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        return (ws, file)
    }

    @Test func concurrentResetsShareOneRun() async throws {
        let w = try await World.make()
        _ = try await addWorkspace(w)
        let hooks = CountingHooks()
        let (env, c, v) = (w.env, w.custody, w.vault)
        async let a: Void = DemoSetup.reset(env, custody: c, vaults: [v], wipeHooks: hooks)
        async let b: Void = DemoSetup.reset(env, custody: c, vaults: [v], wipeHooks: hooks)
        _ = try await (a, b)
        #expect(hooks.quiesces == 1)                       // one wipe of the one workspace, not two
        #expect(c.status(realm: .demo) == .missing)
        try await DemoSetup.reset(env, custody: c, vaults: [v], wipeHooks: hooks)       // finished: a no-op
        #expect(hooks.quiesces == 1)
    }

    @Test func aFailedResetKeepsItsStateAndARetryFinishesOnlyWhatIsLeft() async throws {
        let w = try await World.make()
        let (ws, file) = try await addWorkspace(w)
        let live = try w.custody.create(realm: .live)
        let (env, c, v) = (w.env, w.custody, w.vault)
        let flaky = CountingHooks(failures: 1)
        await #expect(throws: (any Error).self) { try await DemoSetup.reset(env, custody: c, vaults: [v], wipeHooks: flaky) }
        // The lifetime is over, but nothing that a retry needs was thrown away: the realm directory and index are still there.
        #expect(!env.generation.isCurrent)
        #expect(FileManager.default.fileExists(atPath: env.layout.realmDir.path))
        #expect(try await env.index.tombstones().contains { $0.record.ws == ws && $0.phase < 4 })
        // Custody was still handled (independent phase), and nothing live was touched.
        #expect(c.status(realm: .live) == .present)
        try await DemoSetup.reset(env, custody: c, vaults: [v], wipeHooks: flaky)
        #expect(!FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: env.layout.realmDir.path))
        #expect(c.status(realm: .demo) == .missing && c.status(realm: .live) == .present)
        #expect(try c.load(realm: .live).publicKeys == live.publicKeys)
        // The wipe resumed from its persisted phase: the quiesce phase ran once (it had completed before the failure).
        #expect(flaky.quiesces == 1)
    }

    @Test func aStaleContextCannotRecreateDeletedDemoKeys() async throws {
        let w = try await World.make()
        let before = w.env.device
        try await DemoSetup.reset(w.env, custody: w.custody, vaults: [w.vault])
        #expect(w.custody.status(realm: .demo) == .missing)
        #expect(throws: RealmViolation.staleGeneration) { _ = try w.env.context.deviceIdentity(custody: w.custody, createIfMissing: true) }
        #expect(throws: RealmViolation.staleGeneration) { _ = try w.env.context.deviceIdentity(custody: w.custody, createIfMissing: false) }
        #expect(w.custody.status(realm: .demo) == .missing)            // nothing was recreated
        _ = before
    }

    @Test func everyDemoIdentityReturnedByTheContextIsLeased() async throws {
        let w = try await World.make()
        let ctx = w.env.context
        let id = try ctx.deviceIdentity(custody: w.custody, createIfMissing: false)
        #expect(id.publicKeys == w.env.device.publicKeys)
        let session = RelayClient(transport: w.transport)
        _ = try await session.openDeviceSession(identity: id, deviceID: w.phoneID)         // works while current
        w.env.generation.invalidate()
        await #expect(throws: TransportError.realm(.staleGeneration)) { _ = try await session.openDeviceSession(identity: id, deviceID: w.phoneID) }
    }
}
