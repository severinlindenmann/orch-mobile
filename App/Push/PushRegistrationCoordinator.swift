import Foundation
import OrchClient
import OrchPush
import OrchProtocol
import os

/// What the coordinator needs from one workspace's `PushService` (a fake in tests).
protocol PushRegistering: Sendable {
    var workspace: ID16 { get }
    var generation: Int64 { get }
    func register(token: String, env: PushEnvironment) async -> PushRegistrationOutcome
    func keyMaterial() async throws -> (wsk: SigningPublicKey, kPush: [UInt32: Data])
}

extension PushService: PushRegistering {
    func keyMaterial() async throws -> (wsk: SigningPublicKey, kPush: [UInt32: Data]) { try await keyMaterial(maxEpochs: PushMaterial.maxEpochs) }
}

/// Runs `op` and gives up on it after `seconds`: the result of whichever finishes first, nil on the deadline. The operation is cancelled
/// but never awaited past the deadline (a wedged network call must not hold a Leave).
func racing<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
        let once = OSAllocatedUnfairLock(initialState: false)
        @Sendable func finish(_ v: T?) {
            if once.withLock({ done -> Bool in if done { return false }; done = true; return true }) { c.resume(returning: v) }
        }
        let task = Task { finish(await op()) }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(seconds, 0.01)) { task.cancel(); finish(nil) }
    }
}

/// The phone side of relay push (P3-D40) for the Live realm: publishes the notification extension's key material, registers the APNs token
/// with the relay per workspace, and unregisters on Leave. Main-actor confined; every write that outlives a call goes through the realm's
/// fence (the sink is fenced, the registration record lives in the fenced workspace store).
///
/// Nothing here runs unless `enabled()` (the realm's `capabilities.push`) and the build has an APNs environment (not the Simulator).
@MainActor
final class PushRegistrationCoordinator {
    enum Status: Hashable, Sendable {
        case registered
        /// 404: push is not configured on this relay. Asked again on a later launch or foreground, but at most every `pushOffRetry`.
        case relayPushOff
        case refused(String)
        case rateLimited
        case failed(String)
    }

    struct Config {
        var realm: String
        var enabled: () -> Bool
        var environment: () -> PushEnvironment?
        /// The stored APNs token (base64url), nil before iOS handed one over.
        var token: () -> String?
        /// The OS notification permission is allowed.
        var permissionAllowed: () -> Bool
        /// A sink bound to the realm's write fence; nil when the realm has none.
        var sink: () -> VaultPushSink?
        /// This workspace is still joined and live in the SAME runtime and realm lifetime that created the coordinator (not left, removed,
        /// retired or replaced). Asked before every send, and again after every await before a result is kept.
        var isActive: (ID16) -> Bool = { _ in true }
        /// Removes every registration of this device in a workspace through the realm transport and device key (no workspace session: it is
        /// stopped, and its store may already carry the wipe's tombstone). Throws nothing; the outcome says what happened.
        var unregisterDetached: (ID16) async -> PushRegistrationOutcome = { _ in .removed }
        var now: () -> Date = { Date() }
        /// When a 404 last told this install's relay has no push (persisted across launches), nil if never or cleared.
        var pushOffSince: () -> Date? = { nil }
        var setPushOffSince: (Date?) -> Void = { _ in }
    }

    /// A relay that answered 404 is not asked again for this long (launch and foreground triggers alike).
    static let pushOffRetry: TimeInterval = 15 * 60

    private let config: Config
    private(set) var status: [String: Status] = [:]
    /// True while a 404 on a push route (in the last `pushOffRetry`, also from an earlier launch) says the relay has no push. One relay per install.
    var relayPushOff: Bool {
        guard let since = config.pushOffSince() else { return false }
        let age = config.now().timeIntervalSince(since)
        return age >= 0 && age < Self.pushOffRetry
    }
    private var backoffUntil: Date?
    /// One registration at a time per workspace; a trigger that arrives meanwhile is answered by that run (or by one re-run if the token
    /// changed under it). Left workspaces are refused until they are started again (a re-pair).
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var left: Set<String> = []
    /// Set once Leave Live / Reset begins: every register and publish is refused from then on (separate from `enabled()`).
    private(set) var closing = false
    /// Workspaces the relay refused permanently (403, 400, an unusable reply): not asked again in this process.
    private var suppressed: Set<String> = []

    #if DEBUG
    func inFlightCount(workspace: ID16) -> Int { inFlight.keys.filter { $0.hasPrefix(workspace.hex + "/") }.count }
    #endif
    func beginClosing() { closing = true }
    private func key(_ t: any PushRegistering) -> String { "\(t.workspace.hex)/\(t.generation)" }

    /// A workspace was (re)joined: it may register again.
    func workspaceStarted(_ ws: ID16) { left.remove(ws.hex); suppressed.remove(ws.hex) }

    init(_ config: Config) { self.config = config }

    // MARK: material

    /// Publishes `K_push` for the held epochs and the pinned `WSK` (what the extension opens pushes with). Call when a workspace is joined or
    /// restored, and when a new epoch is accepted. A failure leaves the previous material (the extension then shows generic text).
    @discardableResult
    func publishMaterial(_ target: any PushRegistering, name: String, generation: Int64) async -> Bool {
        guard !closing, config.enabled(), config.isActive(target.workspace), let sink = config.sink() else { return false }
        do {
            let m = try await target.keyMaterial()
            // The awaits above may have outlived a Leave: nothing is written for a workspace that is gone (the sink is fenced as well).
            guard !m.kPush.isEmpty, !closing, config.enabled(), config.isActive(target.workspace) else { return false }
            let clipped = String(String.UnicodeScalarView(name.unicodeScalars.prefix(PushMaterial.maxNameScalars)))
            let material = try PushMaterial(generation: generation, name: clipped, wsk: m.wsk, kPush: m.kPush)
            try PushMaterialPublisher(sink: sink, realm: config.realm).publish(workspace: target.workspace, material: material)
            return true
        } catch { return false }
    }

    // MARK: registration

    /// Registers this workspace at the relay when everything allows it. Idempotent: the same token is the same body (200, free).
    /// Concurrent triggers (launch, foreground, token, epoch) for one workspace share one run.
    func register(_ target: any PushRegistering) async {
        let ws = target.workspace.hex, k = key(target)
        if let running = inFlight[k] { await running.value; return }
        let run = Task { @MainActor [self] in
            defer { inFlight[k] = nil }
            while true {
                guard !closing, canRegister(), !left.contains(ws), !suppressed.contains(ws), config.isActive(target.workspace),
                      let env = config.environment(), let token = config.token() else { return }
                let outcome = await target.register(token: token, env: env)
                // Stale authorization: a result is kept only if the workspace, the realm, the environment and the token are still the ones sent.
                guard !closing, !left.contains(ws), config.isActive(target.workspace) else { return }
                guard config.environment() == env, config.token() == token else { continue }
                record(outcome, ws: ws)
                return
            }
        }
        inFlight[k] = run
        await run.value
    }

    /// Every workspace in turn (a launch, a changed token).
    func registerAll(_ targets: [any PushRegistering]) async {
        for t in targets { await register(t) }
    }

    private func canRegister() -> Bool {
        guard !closing, config.enabled(), config.permissionAllowed(), !relayPushOff else { return false }
        if let until = backoffUntil, config.now() < until { return false }
        return true
    }

    private func record(_ outcome: PushRegistrationOutcome, ws: String) {
        switch outcome {
        case .registered: status[ws] = .registered; if config.pushOffSince() != nil { config.setPushOffSince(nil) }
        case .removed: status[ws] = nil
        case .pushOff: config.setPushOffSince(config.now()); status[ws] = .relayPushOff
        case .refused(let why): suppressed.insert(ws); status[ws] = .refused(why)
        case .rateLimited(let after): backoffUntil = config.now().addingTimeInterval(TimeInterval(max(after ?? 300, 1))); status[ws] = .rateLimited
        case .failed(let why): status[ws] = .failed(why)
        }
    }

    // MARK: leaving

    /// How a best-effort unregister ended.
    enum Removal: Equatable, Sendable {
        /// The relay holds none for this workspace any more (200, or 404 push off, or 403: nothing to ask again).
        case done
        /// Offline, rate limited or out of time: the caller records the cleanup as owed while the device key still exists.
        case owed
    }

    /// Unregisters every registration of this device in the workspace, within `seconds`, through the realm transport and device key. Never
    /// throws and never waits longer. A registration still in flight is waited for first (so its request cannot land after the
    /// unregister); if that wait runs out the cleanup is `owed`.
    func unregister(workspace: ID16, seconds: Double = 3) async -> Removal {
        guard config.enabled(), config.environment() != nil else { return .done }
        let ws = workspace.hex
        left.insert(ws)                       // no registration for this workspace may start or be kept from here on
        let started = Date()
        let running = inFlight.filter { $0.key.hasPrefix(ws + "/") }.map(\.value)
        if !running.isEmpty {
            // One bound for all in-flight generations together, not one per generation.
            let waited: Void? = await racing(seconds: seconds) { for r in running { await r.value } }
            if waited == nil { status[ws] = nil; return .owed }
        }
        let remaining = max(seconds - Date().timeIntervalSince(started), 0.05)
        nonisolated(unsafe) let detached = config.unregisterDetached
        let outcome = await racing(seconds: remaining) { await detached(workspace) }
        status[ws] = nil
        return Self.removal(for: outcome)
    }

    nonisolated static func removal(for outcome: PushRegistrationOutcome?) -> Removal {
        switch outcome {
        // Only a definite answer is done: removed, push off, or the relay's 403 (the host removed this device: nothing left to ask). Anything
        // unknown (an unreadable reply, a malformed request, a new code) stays owed.
        case .refused(let code)?: ["not_eligible", "revoked", "not_for_this_device"].contains(code) ? .done : .owed
        case .removed?, .pushOff?: .done
        case .rateLimited?, .failed?, .registered?, nil: .owed
        }
    }

    // MARK: diagnostics

    /// One line for Settings: no token, no id.
    var summary: String {
        if relayPushOff { return "relay: push is not enabled on this relay" }
        if status.isEmpty { return "relay: not registered" }
        let all = Set(status.values)
        if all == [.registered] { return "relay: registered (\(status.count))" }
        return "relay: " + all.map { s -> String in
            switch s {
            case .registered: "registered"
            case .relayPushOff: "push off"
            case .refused(let c): "refused (\(c))"
            case .rateLimited: "rate limited"
            case .failed(let c): "failed (\(c))"
            }
        }.sorted().joined(separator: ", ")
    }
}
