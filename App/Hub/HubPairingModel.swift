#if DEBUG
import Foundation
import Observation
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol

/// The pairing-with-a-hub screen's model (design B1; V3 dev builds only). It holds what the person typed and the coordinator's state; the
/// coordinator owns every key, token and check. The password and the code live here only until `pair()` hands them over and are cleared.
@MainActor @Observable
final class HubPairingModel: Identifiable {
    var linkText = ""
    var password = ""
    var totp = ""
    var hubName = "Dev hub"
    private(set) var state: HubPairingState = .idle
    /// DEBUG launch helpers (`--hub-fake`): an in-process hub so the Simulator can run the whole flow without a real one.
    @ObservationIgnored private(set) var fake: FakeHub?
    @ObservationIgnored private let coordinator: HubPairingCoordinator
    @ObservationIgnored private var task: Task<Void, Never>?

    init(coordinator: HubPairingCoordinator, fake: FakeHub? = nil) {
        self.coordinator = coordinator; self.fake = fake
    }

    /// The real stack: the keychain of the app (an in-memory vault when the Simulator build is unsigned), the hub over Network.framework.
    static func live() -> HubPairingModel {
        let backend: any VaultBackend = KeychainBackend.fromBundle() ?? InMemoryVaultBackend()
        let custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        return HubPairingModel(coordinator: HubPairingCoordinator(HubPairingConfig(custody: custody)))
    }

    /// `--hub-fake`: the same stack against `FakeHub` (no network). `script` is `link`, `confirm` or `paired` (screenshots and UI tests).
    static func fake(script: String?) -> HubPairingModel {
        let hub = FakeHub(origin: "https://hub.dev.orch.example")
        let backend: any VaultBackend = InMemoryVaultBackend()   // the fake hub never touches the keychain
        let custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        let cfg = HubPairingConfig(custody: custody, makeSender: { origin in
            guard origin == hub.origin else { throw HubAPIError.network }
            return hub
        })
        let m = HubPairingModel(coordinator: HubPairingCoordinator(cfg), fake: hub)
        m.linkText = hub.pairingLink
        if script == "confirm" || script == "paired" || script == "failed" {
            m.start()
            if script == "paired" { m.password = hub.password; m.totp = hub.totp; m.task = Task { await m.waitConfirmThenPair() } }
            if script == "failed" { m.password = "wrong"; m.totp = "000000"; m.task = Task { await m.waitConfirmThenPair() } }
        }
        return m
    }

    private func waitConfirmThenPair() async {
        await task?.value
        pair()
    }

    var busy: Bool {
        switch state { case .checking, .working: true; default: false }
    }

    /// Scan or paste: parse, fetch and verify the card and the signed origin. No password has been asked for yet.
    func start() {
        guard !busy else { return }
        let text = linkText
        task = Task { [coordinator] in
            let s = await coordinator.begin(link: text)
            state = s
        }
        state = .checking
    }

    func pair() {
        guard !busy, case .confirm = state else { return }
        let (p, t, n) = (password, totp, hubName)
        password = ""; totp = ""
        task = Task { [coordinator] in
            state = await coordinator.complete(password: p, totp: t, label: n)
        }
        state = .working(.signingIn)
    }

    func cancel() {
        task?.cancel()
        password = ""; totp = ""
        Task { [coordinator] in await coordinator.cancel() }
        state = .idle
    }

    func tryAgain() { password = ""; totp = ""; state = .idle }
}

/// DEBUG launch arguments for the hub pairing screen (Release does not compile this file): `--hub-pair` opens the real stack,
/// `--hub-fake [link|confirm|paired|failed]` the in-process fake hub (screenshots and UI tests).
enum HubLaunch {
    static func isHubLink(_ text: String) -> Bool { text.hasPrefix("orch://hub-pair/") }

    @MainActor static func model(link: String) -> HubPairingModel {
        let m = HubPairingModel.live()
        m.linkText = link
        m.start()
        return m
    }

    @MainActor static func model(arguments: [String] = ProcessInfo.processInfo.arguments) -> HubPairingModel? {
        if let i = arguments.firstIndex(of: "--hub-fake") {
            let script = arguments.indices.contains(i + 1) && !arguments[i + 1].hasPrefix("--") ? arguments[i + 1] : nil
            return HubPairingModel.fake(script: script)
        }
        return arguments.contains("--hub-pair") ? HubPairingModel.live() : nil
    }
}
#endif
