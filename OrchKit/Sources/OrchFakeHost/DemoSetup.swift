import Foundation
import OrchClient
import OrchCustody
import OrchProtocol
import OrchStore

/// A signing handle that dies with its Demo lifetime: after `DemoSetup.reset` every use throws `staleGeneration`.
struct LeasedSigner: Signer {
    let inner: any Signer
    let generation: DemoGeneration
    var publicKey: SigningPublicKey { inner.publicKey }
    func rawSignature(over message: Data) throws -> Data { try generation.check(); return try inner.rawSignature(over: message) }
}

struct LeasedKeyAgreer: KeyAgreer {
    let inner: any KeyAgreer
    let generation: DemoGeneration
    var publicKey: AgreementPublicKey { inner.publicKey }
    func sharedSecret(with peer: AgreementPublicKey) throws -> Data { try generation.check(); return try inner.sharedSecret(with: peer) }
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
    private let resetLock = NSLock()
    nonisolated(unsafe) private var resetDone = false
    var isReset: Bool { resetLock.withLock { resetDone } }
    func markReset() { resetLock.withLock { resetDone = true } }

    init(context: RealmContext, capability: DemoCapability, layout: StoreLayout, index: WorkspaceIndex, relay: FakeRelay,
         transport: InProcessRelayTransport, device: DeviceIdentity, clock: any Clock<Duration>, wall: any WallClock, entropy: any Entropy) {
        self.context = context; self.capability = capability; self.layout = layout; self.index = index; self.relay = relay
        self.transport = transport; self.clock = clock; self.wall = wall; self.entropy = entropy
        let g = capability.generation
        self.device = DeviceIdentity(sig: LeasedSigner(inner: device.sig, generation: g), kx: LeasedKeyAgreer(inner: device.kx, generation: g),
                                     realm: device.realm)
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
    /// 1. The generation is invalidated first: no new request, signature or authority operation starts, and work suspended in a
    ///    fault delay refuses when it resumes (it checks before it writes, with no suspension between check and write).
    /// 2. The relay drops its tables, sessions and mailboxes.
    /// 3. Every Demo workspace is wiped through `OrchStore`'s `LocalWipe` (tombstoned, files, databases), the index is closed and the
    ///    Demo realm directory removed.
    /// 4. Demo device keys and Demo vault items are deleted. Live items are never addressed.
    ///
    /// A failing step does not skip the later ones; the first error is rethrown at the end.
    public static func reset(_ env: DemoEnvironment, custody: any DeviceKeyCustody, vaults: [SecretVault]) async throws {
        guard !env.isReset else { return }                  // a second tap on "Reset Demo" is a no-op, not an error
        var firstError: (any Error)?
        func attempt(_ body: () async throws -> Void) async { do { try await body() } catch { if firstError == nil { firstError = error } } }

        env.generation.invalidate()
        await env.relay.retire()
        await attempt {
            let wipe = LocalWipe(index: env.index)
            for w in try await env.index.workspaces() { try await wipe.wipe(ws: w.ws, generation: w.generation) }
            try await wipe.resumePendingWipes()
        }
        await env.index.close()
        await attempt {
            let dir = env.layout.realmDir
            if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        }
        await attempt { do { try custody.delete(realm: .demo) } catch CustodyError.missing {} catch CustodyError.orphaned {} }
        for v in vaults { await attempt { try v.wipe(realm: .demo) } }
        if let e = firstError { throw e }
        env.markReset()
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
