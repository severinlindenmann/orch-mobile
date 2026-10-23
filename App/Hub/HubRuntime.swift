#if DEBUG
import CryptoKit
import Foundation
import Observation
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchPush

/// The hub side of push for the whole app (design B4; V3 dev builds only): one custody, one `HubPushCoordinator`. It registers the push key and
/// the APNs target after the pairing and when the token changes, and catches up from the channel's relay mailbox when the app becomes active,
/// every 60 s while it is in the foreground, and after a push arrives. A hint only wakes it: lists are read from the hub through its API (B2).
@MainActor @Observable
final class HubRuntime {
    static let shared = HubRuntime()

    /// What the person may be told (no ids, no tokens).
    enum Status: Equatable {
        case notPaired
        case active
        /// The relay said the channel is revoked and the hub confirmed: B6 handles it. The phone wipes nothing here.
        case revokedByHub
        /// The relay said revoked, the hub could not be asked: polling is stopped until it can.
        case waitingForHub
    }

    private(set) var status: Status = .notPaired
    /// Hints handled since launch (each opened, fresh, unseen): the lists refresh when this changes.
    private(set) var hintsHandled = 0
    /// Called with every handled hint batch (B2/B3 wire their lists here). A hint is never an authority.
    @ObservationIgnored var onHints: (@MainActor ([HubPushHint]) -> Void)?

    @ObservationIgnored let custody: HubKeyCustody
    @ObservationIgnored let coordinator: HubPushCoordinator
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var running = false

    /// Test/preview injection: a custody and coordinator of the caller's making (the fake hub in the Simulator).
    init(custody: HubKeyCustody? = nil, coordinator: HubPushCoordinator? = nil) {
        let c = custody ?? Self.makeCustody()
        self.custody = c
        self.coordinator = coordinator ?? HubPushCoordinator(.init(custody: c, pushDir: Self.pushDir()))
    }

    static func makeCustody() -> HubKeyCustody {
        let backend: any VaultBackend = KeychainBackend.fromBundle() ?? InMemoryVaultBackend()
        return HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
    }

    /// The App Group's push directory (shared with the extension); an unsigned Simulator build has none and uses a private one.
    static func pushDir() -> URL {
        PushGroup.pushDir() ?? FileManager.default.temporaryDirectory.appendingPathComponent("orch-hub-push", isDirectory: true)
    }

    /// The APNs target to register: the stored token of a real device. The Simulator has no APNs: it registers a stable placeholder so the
    /// hub still seals hints and leaves them in the mailbox, which the catch-up reads (the Simulator push path).
    func target() -> HubPushTarget? {
        if let s = APNsTokenStore().stored { return HubPushTarget(env: s.environment, token: s.token) }
        #if targetEnvironment(simulator)
        guard let hub = (try? custody.pairedHubs())?.first else { return nil }
        return HubPushTarget(env: .sandbox, token: B64U.encode(Data(SHA256.hash(data: Data("orch-simulator-push|\(hub)".utf8)))))
        #else
        return nil
        #endif
    }

    // MARK: triggers

    /// After a successful pairing, and whenever iOS hands over a token.
    func registerPush() async {
        guard let t = target() else { return }
        _ = await coordinator.registerPush(t)
    }

    /// The app became active: register (idempotent), catch up, and poll every 60 s while it stays in the foreground.
    func foreground() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func background() { poll?.cancel(); poll = nil }

    /// A push arrived while the app was in the foreground: read the mailbox now.
    func pushArrived() { Task { await tick() } }

    func tick() async {
        guard !running else { return }
        running = true; defer { running = false }
        await registerPush()
        switch await coordinator.catchUp() {
        case .notPaired: status = .notPaired
        case .done(let hints, _):
            status = .active
            if !hints.isEmpty { hintsHandled += hints.count; onHints?(hints) }
        case .relayRevoked(.revoked): status = .revokedByHub
        case .relayRevoked(.unconfirmed): status = .waitingForHub
        case .relayRevoked(.live), .noRelay, .noMaterial, .paused, .network: if status == .notPaired { status = .active }
        }
    }
}
#endif
