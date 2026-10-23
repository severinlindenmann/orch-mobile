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
    /// Push key and target registration, and the channel's relay mailbox catch-up (design B4). A relay `channel_revoked` goes to `home`.
    let push: HubPushCoordinator
    /// DEBUG launch helper (`--hub-fake`): the in-process hub behind this runtime.
    let fake: FakeHub?
    /// What B3's sign sessions are built from: the same custody, the same hub senders, Face ID (scripted for the in-process hub).
    let makeSender: @Sendable (String) throws -> any RequestSender
    let biometry: BiometricGate

    init(custody: HubKeyCustody, cache: any HubCacheStore, config: HubPairingConfig, fake: FakeHub? = nil, pushDir: URL = HubRuntime.pushDirectory,
         makeRelaySender: (@Sendable (String) throws -> any RequestSender)? = nil) {
        self.custody = custody; self.fake = fake
        makeSender = config.makeSender
        biometry = fake == nil ? BiometricGate() : BiometricGate(makeContext: { ScriptedBiometry() })
        pairing = HubPairingCoordinator(config)
        let home = HubHomeCoordinator(custody: custody, cache: cache, verifier: config.verifier, wall: config.wall, makeSender: config.makeSender)
        self.home = home
        // The relay's `channel_revoked` is unsigned (L2B-2): B2 drops the cache and asks the hub; this maps its answer. Nothing is wiped here.
        push = HubPushCoordinator(.init(custody: custody, pushDir: pushDir, verifier: config.verifier, wall: config.wall, makeSender: config.makeSender,
                                        makeRelaySender: makeRelaySender, onRelayRevoked: {
            switch await home.relayReportsRevoked() {
            case .revoked: .revoked
            case .live: .live
            default: .unconfirmed
            }
        }))
    }

    /// The App Group's push directory (shared with the extension); an unsigned Simulator build has none and uses a private one.
    static var pushDirectory: URL {
        PushGroup.pushDir() ?? FileManager.default.temporaryDirectory.appendingPathComponent("orch-hub-push", isDirectory: true)
    }

    /// The hub's own area for its cache: never inside a direct-mode workspace container.
    static var cacheDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("OrchHub", isDirectory: true)
    }

    /// The real stack: the keychain of the app (an in-memory vault when the Simulator build is unsigned), the hub over Network.framework.
    static func live() -> HubRuntime {
        let backend: any VaultBackend = KeychainBackend.fromBundle() ?? InMemoryVaultBackend()
        let custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        return HubRuntime(custody: custody, cache: FileHubCache(directory: cacheDirectory), config: HubPairingConfig(custody: custody, biometryBaseline: { BiometricGate().currentDomainState() }))
    }

    /// `--hub-fake`: the same stack against `FakeHub` with sample data (no network, nothing on disk, nothing in the keychain).
    static func fake() -> HubRuntime {
        let hub = FakeHub(origin: "https://hub.dev.orch.example")
        hub.seedHome()
        let backend: any VaultBackend = InMemoryVaultBackend()
        let custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        let cfg = HubPairingConfig(custody: custody, makeSender: { origin in
            guard origin == hub.origin else { throw HubAPIError.network }
            return hub
        }, biometryBaseline: { ScriptedBiometry.state })
        return HubRuntime(custody: custody, cache: InMemoryHubCache(), config: cfg, fake: hub)
    }

    /// The process-wide runtime. `--hub-fake` (any variant) selects the fake one at first use; nothing else changes it.
    static let shared: HubRuntime = ProcessInfo.processInfo.arguments.contains("--hub-fake") ? fake() : live()

    /// Reset this iPhone also removes the hub's cache (the keychain items are removed by the existing reset path).
    static func removeAllCaches() { FileHubCache(directory: cacheDirectory).removeAll() }

    /// Pairs the fake hub without a screen (screenshots and UI tests of the home).
    func pairFake() async {
        guard let hub = fake else { return }
        _ = await pairing.begin(link: hub.pairingLink)
        _ = await pairing.complete(password: hub.password, totp: hub.totp, label: "Dev hub")
    }
}
#endif
