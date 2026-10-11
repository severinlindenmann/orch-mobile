import Foundation
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchPush
import OrchProtocol
import OrchStore

/// The Demo realm, running in-process (decision P3): `DemoSetup` creates it, `FakeRelay`/`FakeHost`/`FakePrimary` serve it and the phone
/// talks to them through the real `PairingCoordinator` and `WorkspaceSession`. One shared Demo clock (a `TestClock` driven by a real-time
/// ticker) lets the Demo panels fast-forward expiry; nothing here approves anything: every human decision is an explicit call.
@MainActor
final class DemoRuntime {
    enum Kind: Int, CaseIterable {
        case laptop, clientVM, lab
        var name: String { switch self { case .laptop: "Laptop"; case .clientVM: "Client VM"; case .lab: "Demo Lab" } }
        var clientHosted: Bool { self == .clientVM }
        var hostedBy: String? { self == .clientVM ? "Example Client" : nil }
        var hostLabel: String { switch self { case .laptop: "Your MacBook"; case .clientVM: "Development VM"; case .lab: "Demo Mac" } }
        var scopes: [String] { self == .clientVM ? ["look", "decide"] : ["look", "decide", "operate", "type"] }
        var alias: String { switch self { case .laptop: "laptop"; case .clientVM: "client-vm"; case .lab: "demo-lab" } }
    }

    final class Entry {
        let host: FakeHost
        let kind: Kind
        var session: RelaySession
        var openedMs: Int64
        var aliases: [String: ID16] = [:]
        /// False after a `linkUsed` scenario: the host never answers.
        var answers = true
        var joined = false
        init(host: FakeHost, kind: Kind, session: RelaySession, openedMs: Int64) {
            self.host = host; self.kind = kind; self.session = session; self.openedMs = openedMs
        }
    }

    struct Invitation {
        let link: String
        let entry: Entry
    }

    let notifications: DemoNotifications
    let clock: TestClock
    let faults: ScriptedFaults
    let lock: SimulatedLock
    let keysVault: SecretVault
    let pushVault: SecretVault
    let custody: any DeviceKeyCustody
    let env: DemoEnvironment
    let primary: FakePrimary
    private(set) var entries: [ID16: Entry] = [:]
    private var primaryCert: JSONValue?
    private var ticker: Task<Void, Never>?
    /// Demo clock seconds per real second (1 normally; high only while a UI test seeds pairings).
    var speed: Int64 = 1
    var primaryOnline = true
    private(set) var invitationCount = 0
    var deviceLabel = "Demo iPhone"

    private init(clock: TestClock, faults: ScriptedFaults, lock: SimulatedLock, keys: SecretVault, push: SecretVault, custody: any DeviceKeyCustody,
                 env: DemoEnvironment, primary: FakePrimary, notifications: DemoNotifications) {
        self.notifications = notifications
        self.clock = clock; self.faults = faults; self.lock = lock; keysVault = keys; pushVault = push; self.custody = custody; self.env = env; self.primary = primary
    }

    // MARK: Boot / reset

    static func layout(temporary: Bool) throws -> StoreLayout {
        let fm = FileManager.default
        let base: URL
        if temporary {
            base = fm.temporaryDirectory.appendingPathComponent("orch-demo-" + UUID().uuidString, isDirectory: true)
        } else {
            base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("OrchDemo", isDirectory: true)
        }
        func group(_ id: String, _ fallback: String) -> URL {
            fm.containerURL(forSecurityApplicationGroupIdentifier: id) ?? base.appendingPathComponent(fallback, isDirectory: true)
        }
        return try StoreLayout(appRoot: base.appendingPathComponent("app", isDirectory: true),
                               pushGroupRoot: group("group.io.severin.orch", "push"),
                               shareGroupRoot: group("group.io.severin.orch.share", "share"),
                               realm: Realm.demo.rawValue)
    }

    /// Finishes a Demo reset that was interrupted (the app was killed mid-reset): same real reset path, nothing kept running.
    static func finishInterruptedReset() async throws {
        let lock = SimulatedLock()
        let backend: any VaultBackend = KeychainBackend.fromBundle() ?? InMemoryVaultBackend(lock: lock)
        let keys = SecretVault(group: .keys, backend: backend)
        let push = SecretVault(group: .push, backend: backend)
        #if targetEnvironment(simulator)
        let custody = DefaultCustody.make(vault: keys, lock: lock)
        #else
        let custody = DefaultCustody.make(vault: keys)
        #endif
        let clock = TestClock(wallStartMs: SystemWallClock().nowMs)
        let stale = try await DemoSetup.setup(layout: try layout(temporary: false), custody: custody, clock: clock, wall: clock, faults: ScriptedFaults())
        // Detached: a wedged notification daemon must never delay Home (an unanswered purge is recorded as owed and retried).
        await SystemDemoNotifications().purge(workspace: nil)   // bounded by one 2 s deadline
        try await DemoSetup.reset(stale, custody: custody, vaults: [keys, push])
    }

    /// Builds a fresh Demo environment. The fakes' authority keys exist only in memory (decision P3), so a Demo realm left by an earlier
    /// launch cannot be served any more: it is wiped through the real reset path first.
    static func boot(temporaryStorage: Bool, notifications: DemoNotifications = DemoNotifications()) async throws -> DemoRuntime {
        let lock = SimulatedLock()
        let backend: any VaultBackend = KeychainBackend.fromBundle() ?? InMemoryVaultBackend(lock: lock)
        let keys = SecretVault(group: .keys, backend: backend)
        let push = SecretVault(group: .push, backend: backend)
        #if targetEnvironment(simulator)
        let custody = DefaultCustody.make(vault: keys, lock: lock)
        #else
        let custody = DefaultCustody.make(vault: keys)
        #endif
        let layout = try layout(temporary: temporaryStorage)
        let clock = TestClock(wallStartMs: SystemWallClock().nowMs)
        let stale = try await DemoSetup.setup(layout: layout, custody: custody, clock: clock, wall: clock, faults: ScriptedFaults())
        // Detached: a wedged notification daemon must never delay Home (an unanswered purge is recorded as owed and retried).
        // One ordered task: stale purge first (the new runtime's scheduling is gated on it), then owed retries.
        let stalePurge = Task.detached { await SystemDemoNotifications().purge(workspace: nil) }
        await notifications.hold(until: stalePurge)
        Task.detached { await stalePurge.value; await SystemDemoNotifications().retryOwedPurges() }
        try await DemoSetup.reset(stale, custody: custody, vaults: [keys, push])
        let faults = ScriptedFaults()
        let env = try await DemoSetup.setup(layout: layout, custody: custody, clock: clock, wall: clock, faults: faults)
        let runtime = DemoRuntime(clock: clock, faults: faults, lock: lock, keys: keys, push: push, custody: custody, env: env, primary: DemoSetup.makeAuthority(env), notifications: notifications)
        runtime.startTicker()
        return runtime
    }

    /// "Leave Demo" / "Reset this iPhone": the real reset path (generation invalidated, relay dropped, workspaces wiped, realm directory,
    /// Demo device keys and Demo vault items removed). Only the Demo realm.
    func reset() async throws {
        ticker?.cancel(); ticker = nil
        await notifications.purge()
        try await DemoSetup.reset(env, custody: custody, vaults: [keysVault, pushVault])
    }

    // MARK: Time

    func date(forMs ms: Int64) -> Date { Date().addingTimeInterval(Double(ms - clock.nowMs) / 1000) }

    func fastForward(seconds: Int) { clock.advance(by: .seconds(seconds)) }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    private func tick() async {
        clock.advance(milliseconds: 250 * speed)
        for entry in Array(entries.values) where entry.answers {
            _ = try? await entry.host.pumpPairing(relay: env.relay, transport: env.transport)
            guard entry.joined else { continue }
            if clock.nowMs - entry.openedMs > 600_000 {
                if let s = try? await entry.host.openSession(transport: env.transport) { entry.session = s; entry.openedMs = clock.nowMs }
            }
            do { _ = try await entry.host.pump(relay: env.relay, transport: env.transport, session: entry.session) }
            catch {
                if let s = try? await entry.host.openSession(transport: env.transport) { entry.session = s; entry.openedMs = clock.nowMs }
            }
        }
    }

    // MARK: Hosts and invitations

    func nextKind() -> Kind {
        let used = Set(entries.values.map(\.kind))
        return Kind.allCases.first { !used.contains($0) } ?? .lab
    }

    /// A new Demo host (the "Mac") with its first offer: the link its Remote tab would show.
    func createInvitation(scenario: PairingScenario) async throws -> Invitation {
        let kind = nextKind()
        let host = try DemoSetup.makeHost(env, primary: primary, name: kind.name, clientHosted: kind.clientHosted, hostedBy: kind.hostedBy, demoDropFixtures: true)
        let cert: JSONValue
        if let primaryCert { cert = primaryCert } else { cert = try await primary.certifyOwnDevice(); primaryCert = cert }
        let session = try await host.publishInitial(relay: env.relay, transport: env.transport,
                                                    devices: [(primary.deviceKeys, cert, ["look", "decide", "operate", "type"])])
        let entry = Entry(host: host, kind: kind, session: session, openedMs: clock.nowMs)
        let ids = try await host.demoSeedViews(questions: DemoContent.questions(kind), tickets: DemoContent.tickets(kind))
        for (seed, id) in zip(DemoContent.questionAliases(kind), ids) { entry.aliases[seed] = id }
        switch scenario {
        case .r1Attack: await host.setR1Attack(true)
        case .echoWrongKey: await host.setEchoWrongKey(.signing)
        case .linkUsed: entry.answers = false
        default: break
        }
        primaryOnline = scenario != .primaryOffline
        if scenario == .existingCert { try await enrollExistingCertificate() }
        let offer = try await host.createOffer(scopes: kind.scopes)
        invitationCount += 1
        entries[host.workspace] = entry
        return Invitation(link: offer.link, entry: entry)
    }

    /// `existingCert`: this iPhone already belongs to the owner (it was paired with another workspace before).
    private func enrollExistingCertificate() async throws {
        let id = try env.context.deviceIdentity(custody: custody, createIfMissing: true)
        let cert = try await primary.certify(DemoKeys(id.publicKeys), label: deviceLabel, scopesMax: ["look", "decide", "operate", "type"])
        try await makeCoordinator().adoptCertificate(cert, owner: primary.publicKey)
    }

    func makeCoordinator() -> PairingCoordinator {
        PairingCoordinator(PairingConfig(context: env.context, transport: env.transport, index: env.index, vault: keysVault, custody: custody,
                                         clock: clock, wall: clock, entropy: SystemEntropy(), deviceLabel: deviceLabel))
    }

    func entry(for workspace: ID16) -> Entry? { entries[workspace] }

    func forget(_ workspace: ID16) { entries[workspace] = nil }

    // MARK: Wipe (Leave)

    func wipe(workspace: ID16, generation: Int64) async throws {
        let wipe = LocalWipe(index: env.index, hooks: DemoWipeHooks(keys: keysVault.scoped(to: .demo), push: pushVault.scoped(to: .demo), notifications: notifications))
        do { try await wipe.wipe(ws: workspace.hex, generation: generation) }
        catch {
            // A tombstoned, half-finished wipe resumes from its persisted phase. Only a finished wipe of THIS workspace counts: a wipe that
            // failed before its tombstone was recorded has nothing to resume, so the original error stands.
            try await wipe.resumePendingWipes()
            let finished = try await env.index.tombstones().contains {
                $0.record.ws == workspace.hex && $0.record.generation >= generation && $0.phase >= LocalWipe.donePhase
            }
            guard finished else { throw error }
        }
        forget(workspace)
    }

    /// Where a workspace keeps its unsent new-ticket draft: inside its own directory, which the local wipe deletes.
    func draftURL(workspace: ID16) -> URL? {
        try? env.layout.wsDir(workspace.hex).appendingPathComponent("ticket-draft.json")
    }

    // MARK: Demo push

    /// Seals a push as the host would and runs it through the same processor the notification extension uses, ending in a local,
    /// labelled-as-simulated notification (decision A12).
    func simulatePush(workspace: ID16, name: String, generation: Int64, label: String, delay: TimeInterval = 1) async -> PushSimulator.Result? {
        guard let entry = entries[workspace], let sealed = try? await entry.host.demoSealPush(kind: "question", id: "demo-" + UUID().uuidString, label: label) else { return nil }
        let keys = await entry.host.demoPushKeys()
        guard let material = try? PushMaterial(generation: generation, name: name, wsk: entry.host.wskPublic, kPush: [keys.epoch: keys.kPush]) else { return nil }
        let sim = PushSimulator(materials: [workspace: material], scheduler: ScopedDemoNotifications(owner: notifications, workspace: workspace.hex), delay: delay, now: { [clock] in Date(timeIntervalSince1970: Double(clock.nowMs) / 1000) })
        return await sim.simulate(sealed: sealed)
    }
}

struct DemoWipeHooks: WipeHooks {
    let keys: RealmVault
    let push: RealmVault
    let notifications: DemoNotifications
    func quiesce(realm: String, ws: String) async throws { await notifications.purge(workspace: ws) }
    func purgeNotifications(realm: String, ws: String) async throws { await notifications.purge(workspace: ws) }
    func purgeSecrets(realm: String, ws: String) async throws {
        try keys.wipe(ws: ws)
        try push.wipe(ws: ws)
    }
}
