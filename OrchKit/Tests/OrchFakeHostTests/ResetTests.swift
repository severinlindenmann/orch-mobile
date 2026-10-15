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

func blockingWait(_ s: DispatchSemaphore) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.global().async { s.wait(); c.resume() } }
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

    /// Custody whose `create` parks until released, to hold a lookup inside custody while a reset runs.
    final class ParkedCustody: DeviceKeyCustody, @unchecked Sendable {
        let inner: any DeviceKeyCustody
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        init(_ inner: any DeviceKeyCustody) { self.inner = inner }
        func create(realm: Realm) throws -> DeviceIdentity { entered.signal(); release.wait(); return try inner.create(realm: realm) }
        func load(realm: Realm) throws -> DeviceIdentity { try inner.load(realm: realm) }
        func delete(realm: Realm) throws { try inner.delete(realm: realm) }
        func status(realm: Realm) -> CustodyStatus { inner.status(realm: realm) }
    }

    @Test func aLookupInsideCustodyCannotRecreateKeysAfterTheResetCompletes() async throws {
        let w = try await World.make()
        try w.custody.delete(realm: .demo)                           // the lookup will take the create path
        let parked = ParkedCustody(w.custody)
        let ctx = w.env.context
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var lookupResult: Result<Void, any Error> = .success(())
        Thread.detachNewThread {
            lookupResult = Result { _ = try ctx.deviceIdentity(custody: parked, createIfMissing: true) }
            done.signal()
        }
        await blockingWait(parked.entered)                                        // the lookup passed the generation check and is inside custody
        let (env, c, v) = (w.env, w.custody, w.vault)
        // Reset synchronously waits for the generation lock held by the parked lookup. Release it from
        // Dispatch, independently of the cooperative pool, even if every pool thread is waiting on locks.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { parked.release.signal() }
        let reset = Task { try await DemoSetup.reset(env, custody: c, vaults: [v]) }
        await blockingWait(done)
        try await reset.value
        _ = lookupResult
        #expect(w.custody.status(realm: .demo) == .missing)          // nothing recreated after the reset's deletion
    }

    final class FlakyBackend: VaultBackend, @unchecked Sendable {
        let inner = InMemoryVaultBackend()
        private let lock = NSLock(); private var failList: Bool
        init(failList: Bool) { self.failList = failList }
        func heal() { lock.withLock { failList = false } }
        func write(_ d: Data, at a: VaultAddress) throws { try inner.write(d, at: a) }
        func add(_ d: Data, at a: VaultAddress) throws { try inner.add(d, at: a) }
        func read(_ a: VaultAddress) throws -> Data { try inner.read(a) }
        func remove(_ a: VaultAddress) throws { try inner.remove(a) }
        func list(group: KeychainGroup) throws -> [SecretID] {
            if lock.withLock({ failList }) { throw VaultError.unexpected(-1) }
            return try inner.list(group: group)
        }
        func removeAll(group: KeychainGroup) throws { try inner.removeAll(group: group) }
    }

    @Test func eachVaultIsCleanedIndependentlyAndOnlyTheFailedOneIsRetried() async throws {
        let w = try await World.make()
        let flaky = FlakyBackend(failList: true)
        let bad = SecretVault(group: .push, backend: flaky)
        let good = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let id = try SecretID(realm: .demo, ws: ID16.random().hex, purpose: "wk")
        try good.put(Data([1]), for: id)
        try bad.put(Data([2]), for: SecretID(realm: .demo, ws: ID16.random().hex, purpose: "wk"))
        try bad.put(Data([3]), for: SecretID(realm: .live, ws: ID16.random().hex, purpose: "wk"))
        let (env, c) = (w.env, w.custody)
        // The failing vault is first, so a single throwing phase would never reach the good one.
        await #expect(throws: (any Error).self) { try await DemoSetup.reset(env, custody: c, vaults: [bad, good]) }
        #expect(try good.ids().isEmpty)                              // the good vault was cleaned despite the earlier failure
        flaky.heal()
        try await DemoSetup.reset(env, custody: c, vaults: [bad, good])
        #expect(try bad.ids().map(\.realm) == [.live])              // demo item gone, live item intact
        #expect(c.status(realm: .demo) == .missing)
    }

    @Test func aRetryWithAReorderedVaultListStillCleansTheFailedVault() async throws {
        let w = try await World.make()
        let flaky = FlakyBackend(failList: true)
        let bad = SecretVault(group: .push, backend: flaky)
        let good = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        try bad.put(Data([2]), for: try SecretID(realm: .demo, ws: ID16.random().hex, purpose: "wk"))
        let (env, c) = (w.env, w.custody)
        await #expect(throws: (any Error).self) { try await DemoSetup.reset(env, custody: c, vaults: [bad, good]) }
        flaky.heal()
        try await DemoSetup.reset(env, custody: c, vaults: [good, bad])
        #expect(try bad.ids().isEmpty && good.ids().isEmpty)
    }
}
