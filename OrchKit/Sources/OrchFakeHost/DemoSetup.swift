import Foundation
import OrchClient
import OrchCustody
import OrchProtocol
import OrchStore

final class ResetState: @unchecked Sendable {
    enum Phase: Hashable { case wipe, removeRealm, custody, vaults }
    private let lock = NSLock()
    private var task: Task<Void, any Error>?
    private var done: Set<Phase> = []
    private var finished = false

    /// The task to await: the in-flight one, or a new one started by `start` (claimed under the lock).
    func claim(_ start: () -> Task<Void, any Error>) -> (task: Task<Void, any Error>, owner: Bool)? {
        lock.withLock {
            if finished { return nil }
            if let t = task { return (t, false) }
            let t = start(); task = t; return (t, true)
        }
    }
    func release(success: Bool) { lock.withLock { task = nil; if success { finished = true } } }
    func has(_ p: Phase) -> Bool { lock.withLock { done.contains(p) } }
    func mark(_ p: Phase) { lock.withLock { _ = done.insert(p) } }
}

/// The Demo realm, assembled, and its lifetime. This is the only way to obtain a `DemoCapability` (challenge C1), and it binds
/// nothing but a Demo `StoreLayout`/`WorkspaceIndex`, `Realm.demo` custody and the in-process relay. Callers cannot hand it a
/// live store, a live custody realm or an external transport.
///
/// `generation` is this environment's lifetime. `DemoSetup.reset` invalidates it: the context, transport, relay, authority
/// actors and the device's signing handles built from it all throw `RealmViolation.staleGeneration` from then on.
public final class DemoEnvironment: Sendable {
    public let context: RealmContext
    public let capability: DemoCapability
    public let layout: StoreLayout
    public let index: WorkspaceIndex
    public let relay: FakeRelay
    public let transport: InProcessRelayTransport
    /// This iPhone's Demo keys: `Realm.demo` entries in custody, distinct from any live keys. The handles are leased to
    /// `generation`: they stop signing when the environment is reset.
    public let device: DeviceIdentity
    public let deviceID: ID16
    public let clock: any Clock<Duration>
    public let wall: any WallClock
    public let entropy: any Entropy
    public var generation: DemoGeneration { capability.generation }
    /// Reset ownership and progress. One caller owns an in-flight reset; others await the same task. Finished phases are kept so a
    /// retry after a failure runs only what is left.
    let resetState = ResetState()

    init(context: RealmContext, capability: DemoCapability, layout: StoreLayout, index: WorkspaceIndex, relay: FakeRelay,
         transport: InProcessRelayTransport, device: DeviceIdentity, clock: any Clock<Duration>, wall: any WallClock, entropy: any Entropy) {
        self.context = context; self.capability = capability; self.layout = layout; self.index = index; self.relay = relay
        self.transport = transport; self.clock = clock; self.wall = wall; self.entropy = entropy
        self.device = device        // already leased to the generation by RealmContext.deviceIdentity
        deviceID = Identifiers.deviceID(device.publicKeys.sig)
    }
}

public enum DemoSetup {
    /// `layout.realm` must be `demo` (a live store is refused). Demo device keys are created in `Realm.demo` or loaded from it;
    /// a custody that answers with an identity of another realm is refused (`RealmViolation.wrongStore`) before anything else is built.
    public static func setup(layout: StoreLayout, custody: any DeviceKeyCustody, clock: any Clock<Duration>, wall: any WallClock,
                             entropy: any Entropy = SystemEntropy(), faults: any FaultPolicy = NoFaults(),
                             limits: RelayLimits = RelayLimits()) async throws -> DemoEnvironment {
        guard layout.realm == Realm.demo.rawValue else { throw RealmViolation.wrongStore }
        let capability = DemoCapability(id: entropy.id16(), generation: DemoGeneration())
        let context = RealmContext.demo(capability)
        let device = try context.deviceIdentity(custody: custody, createIfMissing: true)
        let index = try await WorkspaceIndex(layout: layout)
        let relay = try FakeRelay(capability: capability, context: context, clock: clock, wall: wall, entropy: entropy, faults: faults, limits: limits)
        let transport = try InProcessRelayTransport(context: context, relay: relay)
        return DemoEnvironment(context: context, capability: capability, layout: layout, index: index, relay: relay, transport: transport,
                               device: device, clock: clock, wall: wall, entropy: entropy)
    }

    /// "Reset Demo": ends this environment's lifetime and erases the Demo realm, and only the Demo realm.
    ///
    /// 1. The generation is invalidated first: no new request, signature, identity lookup or authority operation starts, and work
    ///    suspended in a fault delay refuses when it resumes (it checks before it writes, with no suspension between).
    /// 2. The relay drops its tables, sessions and mailboxes.
    /// 3. Every Demo workspace is wiped through `OrchStore`'s `LocalWipe` (tombstoned, resumable by phase). Only when that succeeded
    ///    is the index closed and the Demo realm directory removed.
    /// 4. Demo device keys and Demo vault items are deleted. Live items are never addressed.
    ///
    /// Concurrent callers share one run (the second awaits the first). A failing phase throws and is not marked done; calling
    /// `reset` again retries only the unfinished phases (LocalWipe resumes from its persisted phase). A completed reset is a no-op.
    ///
    /// `DemoAuthorities.shared` is deliberately NOT cleared: a live context keeps refusing certificates of old Demo authorities
    /// (defence in depth for "certificate reuse denied"), at the cost of a few ids held for the process lifetime.
    public static func reset(_ env: DemoEnvironment, custody: any DeviceKeyCustody, vaults: [SecretVault]) async throws {
        try await reset(env, custody: custody, vaults: vaults, wipeHooks: NoWipeHooks())
    }

    package static func reset(_ env: DemoEnvironment, custody: any DeviceKeyCustody, vaults: [SecretVault], wipeHooks: any WipeHooks) async throws {
        let state = env.resetState
        guard let (task, owner) = state.claim({
            Task { try await run(env, custody: custody, vaults: vaults, wipeHooks: wipeHooks) }
        }) else { return }
        do { try await task.value; if owner { state.release(success: true) } }
        catch { if owner { state.release(success: false) }; throw error }
    }

    private static func run(_ env: DemoEnvironment, custody: any DeviceKeyCustody, vaults: [SecretVault], wipeHooks: any WipeHooks) async throws {
        let state = env.resetState
        var firstError: (any Error)?
        func attempt(_ phase: ResetState.Phase, _ body: () async throws -> Void) async {
            guard !state.has(phase) else { return }
            do { try await body(); state.mark(phase) } catch { if firstError == nil { firstError = error } }
        }
        env.generation.invalidate()
        await env.relay.retire()
        await attempt(.wipe) {
            let wipe = LocalWipe(index: env.index, hooks: wipeHooks)
            for w in try await env.index.workspaces() { try await wipe.wipe(ws: w.ws, generation: w.generation) }
            try await wipe.resumePendingWipes()
        }
        if state.has(.wipe) {
            await attempt(.removeRealm) {
                await env.index.close()
                let dir = env.layout.realmDir
                if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
            }
        }
        await attempt(.custody) { do { try custody.delete(realm: .demo) } catch CustodyError.missing {} catch CustodyError.orphaned {} }
        await attempt(.vaults) { for v in vaults { try v.wipe(realm: .demo) } }
        if let e = firstError { throw e }
    }

    public static func makeAuthority(_ env: DemoEnvironment) -> FakePrimary {
        FakePrimary(capability: env.capability, wall: env.wall, entropy: env.entropy)
    }

    public static func makeHost(_ env: DemoEnvironment, primary: FakePrimary, name: String = "Laptop", clientHosted: Bool = false,
                                hostedBy: String? = nil, workspace: ID16? = nil) throws -> FakeHost {
        try FakeHost(capability: env.capability, context: env.context, primary: primary, name: name, clientHosted: clientHosted,
                     hostedBy: hostedBy, workspace: workspace, wall: env.wall, entropy: env.entropy)
    }
}
