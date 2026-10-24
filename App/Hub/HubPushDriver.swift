import CryptoKit
import Foundation
import Observation
import OrchClient
import OrchCustody
import OrchProtocol
import OrchPush

/// When the hub push work runs (design B4; V3 dev builds): after the pairing and when the APNs token changes (register), when the app becomes
/// active, every 60 s while it stays in the foreground, and after a push arrives (catch up from the relay mailbox). A handled hint only
/// triggers a refresh of the lists through B2's home coordinator: the hint is never data, and the lists come from the hub over the channel.
@MainActor @Observable
final class HubPushDriver {
    static let shared = HubPushDriver()

    /// Changes whenever hints were handled: the home screen refreshes on it.
    private(set) var hintTick = 0
    /// What the last catch-up said (for a status line; no ids or tokens).
    private(set) var lastCatchUp: HubCatchUp?

    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var permissionAsked = false
    @ObservationIgnored private let runtime: HubRuntime

    init(runtime: HubRuntime = .shared) {
        self.runtime = runtime
        runtime.wipe.onQuiesce { [weak self] _ in await self?.quiesce() }
    }

    /// Phase 1 of a wipe: stop polling. What is already running is stopped by the wipe barrier (`HubWorkToken`), not by a flag here.
    private func quiesce() { poll?.cancel(); poll = nil }

    /// The APNs target to register: the stored token of a real device. The Simulator has no APNs: it registers a stable placeholder so the hub
    /// still seals hints and leaves them in the mailbox, which the catch-up reads (the Simulator push path).
    func target() -> HubPushTarget? {
        if let s = APNsTokenStore().stored { return HubPushTarget(env: s.environment, token: s.token) }
        #if targetEnvironment(simulator)
        guard let hub = (try? runtime.custody.pairedHubs())?.first else { return nil }
        return HubPushTarget(env: .sandbox, token: B64U.encode(Data(SHA256.hash(data: Data("orch-simulator-push|\(hub)".utf8)))))
        #else
        return nil
        #endif
    }

    /// After a successful pairing, and whenever iOS hands over a token.
    func registerPush() async {
        guard let t = target() else { return }
        _ = await runtime.push.registerPush(t)
    }

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

    /// A push arrived while the app was in the foreground.
    func pushArrived() { Task { await tick() } }

    /// Once per process, and only on a real device with a paired hub: the system permission prompt, then APNs registration (U10: never at launch,
    /// never before a hub is paired). The Simulator has no APNs; it must not raise a system alert in the middle of a UI test.
    private func askForPushPermission() async {
        #if !targetEnvironment(simulator)
        guard !permissionAsked, (try? runtime.custody.pairedHubs())?.first != nil else { return }
        permissionAsked = true
        let state = await PushPermission.requestIfNeeded()
        if state == .authorized || state == .provisional { PushPermission.registerForAPNs() }
        #endif
    }

    func tick() async {
        let work = runtime.wipe.workToken()          // the wipe barrier (HubWorkBarrier): a unit of work is one tick
        guard !running, work.isValid else { return }
        running = true; defer { running = false }
        await askForPushPermission()
        await registerPush()
        guard work.isValid else { return }           // a wipe began during the registration: no catch-up
        let r = await runtime.push.catchUp()
        lastCatchUp = r
        if case .done(let hints, _) = r, !hints.isEmpty { hintTick += 1 }
    }
}
