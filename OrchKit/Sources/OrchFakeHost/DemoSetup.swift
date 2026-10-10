import Foundation
import OrchClient
import OrchCustody
import OrchProtocol
import OrchStore

/// The Demo realm, assembled. This is the only way to obtain a `DemoCapability` (challenge C1), and it will bind nothing but
/// a Demo `StoreLayout`/`WorkspaceIndex`, `Realm.demo` custody and the in-process relay. Callers cannot hand it a live store,
/// a live custody realm or an external transport.
public struct DemoEnvironment: Sendable {
    public let context: RealmContext
    public let capability: DemoCapability
    public let layout: StoreLayout
    public let index: WorkspaceIndex
    public let relay: FakeRelay
    public let transport: InProcessRelayTransport
    /// This iPhone's Demo keys: `Realm.demo` entries in custody, distinct from any live keys.
    public let device: DeviceIdentity
    public let deviceID: ID16
    public let clock: any Clock<Duration>
    public let wall: any WallClock
    public let entropy: any Entropy
}

public enum DemoSetup {
    /// `layout.realm` must be `demo` (a live store is refused). Demo device keys are created in `Realm.demo` or loaded from it.
    public static func setup(layout: StoreLayout, custody: any DeviceKeyCustody, clock: any Clock<Duration>, wall: any WallClock,
                             entropy: any Entropy = SystemEntropy(), faults: any FaultPolicy = NoFaults(),
                             limits: RelayLimits = RelayLimits()) async throws -> DemoEnvironment {
        guard layout.realm == Realm.demo.rawValue else { throw RealmViolation.wrongStore }
        let capability = DemoCapability(id: entropy.id16())
        let context = RealmContext.demo(capability)
        let index = try await WorkspaceIndex(layout: layout)
        let relay = FakeRelay(context: context, clock: clock, wall: wall, entropy: entropy, faults: faults, limits: limits)
        let transport = try InProcessRelayTransport(context: context, relay: relay)
        let device = try context.deviceIdentity(custody: custody, createIfMissing: true)
        return DemoEnvironment(context: context, capability: capability, layout: layout, index: index, relay: relay, transport: transport,
                               device: device, deviceID: Identifiers.deviceID(device.publicKeys.sig), clock: clock, wall: wall, entropy: entropy)
    }

    /// "Reset Demo": deletes only `Realm.demo` custody (device keys) and `Realm.demo` vault items. Live items are untouched.
    public static func reset(custody: any DeviceKeyCustody, vaults: [SecretVault]) throws {
        do { try custody.delete(realm: .demo) } catch CustodyError.missing {} catch CustodyError.orphaned {}
        for v in vaults { try v.wipe(realm: .demo) }
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
