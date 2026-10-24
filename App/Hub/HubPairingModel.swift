import Foundation
import Observation
import OrchClient
import OrchCustody
#if DEBUG
import OrchFakeHost
#endif
import OrchProtocol

/// The pairing-with-a-hub screen's model (design B1). It holds what the person typed and the coordinator's state; the
/// coordinator owns every key, token and check. The password and the code live here only until `pair()` hands them over and are cleared.
@MainActor @Observable
final class HubPairingModel: Identifiable {
    var linkText = ""
    var password = ""
    var totp = ""
    var hubName = "Dev hub"
    private(set) var state: HubPairingState = .idle
    #if DEBUG
    /// DEBUG launch helper (`--hub-fake`): an in-process hub so the Simulator can run the whole flow without a real one.
    @ObservationIgnored var fake: FakeHub?
    #endif
    @ObservationIgnored private let coordinator: HubPairingCoordinator
    @ObservationIgnored private var task: Task<Void, Never>?

    init(coordinator: HubPairingCoordinator) { self.coordinator = coordinator }

    /// The process-wide stack (`HubRuntime.shared`): one pairing coordinator per process, never one per sheet (L2-B1d-2).
    static func live() -> HubPairingModel {
        let m = HubPairingModel(coordinator: HubRuntime.shared.pairing)
        #if DEBUG
        m.fake = HubRuntime.shared.fake
        #endif
        return m
    }

    /// An opened `orch://hub-pair/...` link: the pairing screen starts on it.
    static func live(link: String) -> HubPairingModel {
        let m = live()
        m.linkText = link
        m.start()
        return m
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
            // After bind: publish the extension's material and register the push key and target (B4). Not part of the pairing: a failure leaves
            // the phone paired, and the next foreground tries again.
            if case .paired = state { await HubPushDriver.shared.registerPush() }
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

/// The `orch://hub-pair/...` link of a hub QR code or invite.
enum HubPairingLink {
    static func isHubLink(_ text: String) -> Bool { text.hasPrefix("orch://hub-pair/") }
}

#if DEBUG
extension HubPairingModel {
    /// `--hub-fake`: the same stack against `FakeHub` (no network). `script` is `link`, `confirm` or `paired` (screenshots and UI tests).
    static func fake(script: String?) -> HubPairingModel {
        let hub = FakeHub(origin: "https://hub.dev.orch.example")
        let backend: any VaultBackend = InMemoryVaultBackend()   // the fake hub never touches the keychain
        let custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        let cfg = HubPairingConfig(custody: custody, makeSender: { origin in
            guard origin == hub.origin else { throw HubAPIError.network }
            return hub
        }, wipe: HubWipe(custody: custody, cache: InMemoryHubCache()))
        let m = HubPairingModel(coordinator: HubPairingCoordinator(cfg))
        m.fake = hub
        m.linkText = hub.pairingLink
        if script == "confirm" || script == "paired" || script == "failed" {
            m.start()
            if script == "paired" { m.password = hub.password; m.totp = hub.totp }
            if script == "failed" { m.password = "wrong"; m.totp = "000000" }
            if script != "confirm" { let started = m.task; m.task = Task { await started?.value; m.pair() } }
        }
        return m
    }
}

/// DEBUG launch arguments for the hub pairing screen (Release does not compile this block): `--hub-pair` opens the real stack,
/// `--hub-fake [link|confirm|paired|failed]` the in-process fake hub (screenshots and UI tests).
enum HubLaunch {
    /// Whether a launch argument asks for the hub screen (no model is made: `HubLaunchRoot` makes it once).
    static func model(arguments: [String], probe: Bool) -> Bool { arguments.contains("--hub-fake") || arguments.contains("--hub-pair") || arguments.contains("--hub-sign") }

    /// `--hub-fake home...`: the hub home instead of the pairing screen.
    static func homeScript(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let i = arguments.firstIndex(of: "--hub-fake"), arguments.indices.contains(i + 1), arguments[i + 1].hasPrefix("home") else { return nil }
        return arguments[i + 1]
    }

    @MainActor static func model(arguments: [String] = ProcessInfo.processInfo.arguments) -> HubPairingModel? {
        if let i = arguments.firstIndex(of: "--hub-fake") {
            let script = arguments.indices.contains(i + 1) && !arguments[i + 1].hasPrefix("--") ? arguments[i + 1] : nil
            return HubPairingModel.fake(script: script)
        }
        return arguments.contains("--hub-pair") ? HubPairingModel.live() : nil
    }
}

import SwiftUI

/// Owns the launch-argument model for the life of the view (a computed `root` would rebuild it on every body pass).
struct HubLaunchRoot: View {
    @State private var model = (HubLaunch.homeScript() == nil && HubLaunchRoot.signModel() == nil) ? (HubLaunch.model() ?? HubPairingModel.live()) : nil
    /// `--hub-sign [script]`: the sign prompt against the in-process hub (screenshots and UI tests).
    @State private var sign = HubLaunchRoot.signModel()
    /// `--hub-pair` on the real stack: after "Done" the home of the hub just paired (the Simulator lane, one launch from pairing to sign).
    @State private var home = false
    var body: some View {
        if let sign { HubSignScreen(model: sign) }
        else if let script = HubLaunch.homeScript() { HubHomeLaunchRoot(script: script) }
        else if home { HubHomeScreen() }
        else if let model { HubPairingScreen(model: model, onDone: ProcessInfo.processInfo.arguments.contains("--hub-pair") ? { home = true } : nil) }
    }

    static func signModel(arguments: [String] = ProcessInfo.processInfo.arguments) -> HubSignModel? {
        guard let i = arguments.firstIndex(of: "--hub-sign") else { return nil }
        return HubSignModel.fake(script: arguments.indices.contains(i + 1) && !arguments[i + 1].hasPrefix("--") ? arguments[i + 1] : nil)
    }
}
#endif
