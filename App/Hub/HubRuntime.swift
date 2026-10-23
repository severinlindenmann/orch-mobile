#if DEBUG
import Foundation
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchPush

/// The one hub stack of this process (design B2; also L2-B1d-2): one pairing coordinator and one home coordinator over one custody. Every
/// screen gets these, never a coordinator of its own, so two sheets cannot pair at the same time and only one thing refreshes the lists.
final class HubRuntime: Sendable {
    let custody: HubKeyCustody
    let pairing: HubPairingCoordinator
    let home: HubHomeCoordinator
    let wipe: HubWipe
    /// Push key and target registration, and the channel's relay mailbox catch-up (design B4). A relay `channel_revoked` goes to `home`.
    let push: HubPushCoordinator
    /// DEBUG launch helper (`--hub-fake`): the in-process hub behind this runtime.
    let fake: FakeHub?
    /// What B3's sign sessions are built from: the same custody, the same hub senders, Face ID (scripted for the in-process hub).
    let makeSender: @Sendable (String) throws -> any RequestSender
    let biometry: BiometricGate

    init(custody: HubKeyCustody, cache: any HubCacheStore, wipe: HubWipe, config: HubPairingConfig, fake: FakeHub? = nil,
         pushDir: URL = HubStorage.pushDirectory, makeRelaySender: (@Sendable (String) throws -> any RequestSender)? = nil) {
        self.custody = custody; self.fake = fake; self.wipe = wipe
        makeSender = config.makeSender
        biometry = fake == nil ? BiometricGate() : BiometricGate(makeContext: { ScriptedBiometry() })
        pairing = HubPairingCoordinator(config)
        let home = HubHomeCoordinator(custody: custody, cache: cache, verifier: config.verifier, wall: config.wall, makeSender: config.makeSender, wipe: wipe)
        self.home = home
        // The relay's `channel_revoked` is unsigned (L2B-2): B2 drops the cache and asks the hub; this maps its answer. Nothing is wiped here.
        push = HubPushCoordinator(.init(custody: custody, pushDir: pushDir, verifier: config.verifier, wall: config.wall, makeSender: config.makeSender,
                                        makeRelaySender: makeRelaySender, onRelayRevoked: {
            switch await home.relayReportsRevoked() {
            case .revoked: .revoked
            case .live: .live
            default: .unconfirmed
            }
        }, wipe: wipe))
    }

    /// The real stack: the process-wide hub storage (the same objects Reset this iPhone wipes), the hub over Network.framework.
    static func live() -> HubRuntime {
        HubRuntime(custody: HubStorage.custody, cache: HubStorage.cache, wipe: HubStorage.wipe,
                   config: HubPairingConfig(custody: HubStorage.custody, biometryBaseline: { BiometricGate().currentDomainState() }, wipe: HubStorage.wipe))
    }

    /// `--hub-fake`: the same stack against `FakeHub` with sample data (no network, nothing on disk, nothing in the keychain).
    static func fake() -> HubRuntime {
        let hub = FakeHub(origin: "https://hub.dev.orch.example")
        hub.seedHome()
        let backend: any VaultBackend = InMemoryVaultBackend()
        let custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        let cache = InMemoryHubCache()
        let wipe = HubWipe(custody: custody, cache: cache)
        let cfg = HubPairingConfig(custody: custody, makeSender: { origin in
            guard origin == hub.origin else { throw HubAPIError.network }
            return hub
        }, biometryBaseline: { ScriptedBiometry.state }, wipe: wipe)
        return HubRuntime(custody: custody, cache: cache, wipe: wipe, config: cfg, fake: hub)
    }

    /// The process-wide runtime. `--hub-fake` (any variant) selects the fake one at first use; nothing else changes it.
    static let shared: HubRuntime = ProcessInfo.processInfo.arguments.contains("--hub-fake") ? fake() : live()

    /// Pairs the fake hub without a screen (screenshots and UI tests of the home).
    func pairFake() async {
        guard let hub = fake else { return }
        _ = await pairing.begin(link: hub.pairingLink)
        _ = await pairing.complete(password: hub.password, totp: hub.totp, label: "Dev hub")
    }
}
#endif
