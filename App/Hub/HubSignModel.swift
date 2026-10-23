#if DEBUG
import Foundation
import LocalAuthentication
import Observation
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol

/// Stand-in link: the hub's browser home (no item deep link yet). The independent check is Mission Control's content reference.
@Sendable func hubHome(_ origin: String, _ ws: String, _ log: String) -> URL? { URL(string: origin + "/") }

/// The sign prompt's model (design B3; V3 dev builds only, like the pairing screen). Every check and every key is in `HubSignSession`; this
/// holds what the screen shows. It never holds a ctx or a digest: `confirm` hands the session the prepared id and nothing else.
///
/// The seam for the workspace list (B2) and for pushes (B4): `open(preparedID:)` ("open the sign prompt for prepared id") and
/// `start(workspaceID:action:)` ("start a decision on this item"). Present `HubSignScreen(model:)` in a sheet.
@MainActor @Observable
final class HubSignModel: Identifiable {
    enum State: Equatable {
        case idle
        case loading
        case review(HubSignPrompt)
        case signing(HubSignPrompt)
        case signed(HubSignReceipt)
        case failed(HubSignFailure)
    }

    private(set) var state: State = .idle
    @ObservationIgnored fileprivate var session: HubSignSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// DEBUG launch helpers (`--hub-sign`): the in-process hub the scripted states run against.
    @ObservationIgnored fileprivate(set) var fake: FakeHub?

    init(session: HubSignSession?, fake: FakeHub? = nil) { self.session = session; self.fake = fake }

    /// The real stack for the first paired hub (D-B1: one in V3), or nil when this iPhone is not paired. `workspaces` is B2's list: a pushed
    /// request is refused unless its workspace is one of them.
    static func live(workspaces: @escaping @Sendable (String) async -> Bool = { _ in false }) -> HubSignModel? {
        let backend: any VaultBackend = KeychainBackend.fromBundle() ?? InMemoryVaultBackend()
        let custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        guard let hubID = try? custody.pairedHubs().first else { return nil }
        return HubSignModel(session: HubSignSession(HubSignConfig(custody: custody, isMyWorkspace: workspaces, contentLink: hubHome, wipe: HubStorage.wipe), hubID: hubID))
    }

    /// The sign model for the one paired hub of this runtime. `workspaces` is B2's list at the moment the person opened the item: a request
    /// for any other workspace is refused (`isMyWorkspace`).
    static func make(runtime: HubRuntime, workspaces: Set<String>) -> HubSignModel? {
        guard let hubID = try? runtime.custody.pairedHubs().first else { return nil }
        let cfg = HubSignConfig(custody: runtime.custody, makeSender: runtime.makeSender, biometry: runtime.biometry,
                                isMyWorkspace: { workspaces.contains($0) }, contentLink: hubHome, wipe: runtime.wipe)
        return HubSignModel(session: HubSignSession(cfg, hubID: hubID))
    }

    var busy: Bool { switch state { case .loading, .signing: true; default: false } }

    /// Start a decision the person chose on an item (self-started): the hub prepares it and the prompt follows.
    func start(workspaceID: String, action: HubSignAction) {
        guard !busy else { return }
        state = .loading
        task = Task { [session] in
            guard let session else { state = .failed(.notPaired); return }
            do { state = .review(try await session.prepare(workspaceID: workspaceID, action: action)) }
            catch { state = .failed(Self.failure(error)) }
        }
    }

    /// Open the sign prompt for a prepared id (a push, or a row in the needs-you list).
    func open(preparedID: String) {
        guard !busy else { return }
        state = .loading
        task = Task { [session] in
            guard let session else { state = .failed(.notPaired); return }
            do { state = .review(try await session.open(preparedID: preparedID)) }
            catch { state = .failed(Self.failure(error)) }
        }
    }

    /// The person tapped Confirm: Face ID, then the proof, then the hub.
    func confirm() {
        guard case .review(let p) = state else { return }
        state = .signing(p)
        task = Task { [session] in
            guard let session else { state = .failed(.notPaired); return }
            do { state = .signed(try await session.confirm(preparedID: p.preparedID)) }
            catch let f as HubSignFailure {
                // a cancelled or failed Face ID leaves the request live: back to the prompt
                if case .biometry(let b) = f, b == .cancelled || b == .failed { state = .review(p) } else { state = .failed(f) }
            } catch { state = .failed(.custody) }
        }
    }

    func dismiss() {
        task?.cancel()
        if case .review(let p) = state { Task { [session] in await session?.discard(preparedID: p.preparedID) } }
        if case .signing(let p) = state { Task { [session] in await session?.discard(preparedID: p.preparedID) } }
        state = .idle
    }

    fileprivate static func failure(_ e: Error) -> HubSignFailure { (e as? HubSignFailure) ?? .custody }
}

// MARK: DEBUG scripted states (screenshots, UI tests): `--hub-sign [review|code|question|signed|type|changed|expired|offline]`

/// Face ID stand-in for the in-process hub (the Simulator has no enrolled face unless the tester sets it up): matches the recorded state.
final class ScriptedBiometry: BiometricContext, @unchecked Sendable {
    static let state = Data("scripted-faces".utf8)
    var localizedFallbackTitle: String?
    var evaluatedPolicyDomainState: Data? { Self.state }
    func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool { policy == .deviceOwnerAuthenticationWithBiometrics }
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool {
        try await Task.sleep(nanoseconds: 300_000_000)
        return policy == .deviceOwnerAuthenticationWithBiometrics
    }
}

private final class OfflineSwitch: RequestSender, @unchecked Sendable {
    let inner: FakeHub
    private let lock = NSLock()
    private var down = false
    var origin: String { inner.origin }
    init(_ inner: FakeHub) { self.inner = inner }
    func goOffline() { lock.withLock { down = true } }
    func send(_ request: WireRequest) async throws -> WireReply {
        if lock.withLock({ down }) { throw TransportError.disconnected }
        return try await inner.send(request)
    }
}

extension HubSignModel {
    /// Pairs with an in-process hub, then plays the named script (the screen follows `state`).
    static func fake(script: String?) -> HubSignModel {
        let hub = FakeHub(origin: "https://hub.dev.orch.example")
        let link = OfflineSwitch(hub)
        let backend: any VaultBackend = InMemoryVaultBackend()
        let custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        let make: @Sendable (String) throws -> any RequestSender = { _ in link }
        let wipe = HubWipe(custody: custody, cache: InMemoryHubCache())
        let m = HubSignModel(session: nil, fake: hub)
        m.state = .loading
        m.task = Task {
            let coordinator = HubPairingCoordinator(HubPairingConfig(custody: custody, makeSender: make, biometryBaseline: { ScriptedBiometry.state }, wipe: wipe))
            guard case .confirm = await coordinator.begin(link: hub.pairingLink),
                  case .paired(let s) = await coordinator.complete(password: hub.password, totp: hub.totp, label: "Dev hub") else {
                m.state = .failed(.notPaired); return
            }
            m.session = HubSignSession(HubSignConfig(custody: custody, makeSender: make, biometry: BiometricGate(makeContext: { ScriptedBiometry() }), contentLink: hubHome, wipe: wipe),
                                       hubID: s.hubID)
            await m.play(script, hub: hub, link: link)
        }
        return m
    }

    fileprivate func play(_ name: String?, hub: FakeHub, link: OfflineSwitch) async {
        let log = hub.ticketLog, h = FakeHub.contentHash
        var f = FakeHub.Faults()
        switch name {
        case "type": f.buildType = "ticket.moved"
        case "changed": f.wrongDigest = true
        case "expired": f.preparedTTLMs = 3_000
        default: break
        }
        hub.faults = f
        let action: HubSignAction = switch name {
        case "code": .approveGate(log: log, gate: "code", hash: h)
        case "question": .answerQuestion(log: log, question: "Q2", hash: h, option: "yes-ship-it", text: nil)
        default: .approveGate(log: log, gate: "plan", hash: h)
        }
        state = .idle   // `start` refuses while busy
        start(workspaceID: hub.workspaceID, action: action)
        await task?.value
        if name == "offline" { link.goOffline(); confirm(); await task?.value }
        if name == "signed" { confirm() }
    }
}
#endif
