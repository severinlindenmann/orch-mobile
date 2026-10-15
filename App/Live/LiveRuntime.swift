import Foundation
import OrchClient
import OrchCoordination
import OrchCustody
import OrchProtocol
import OrchPush
import OrchStore
import UserNotifications

enum LiveError: Error, Equatable {
    /// No keychain access-group configuration in this build: Live fails closed (there is no in-memory fallback for Live secrets).
    case keychainUnavailable
    /// The persisted install record names an origin or owner key this build refuses.
    case invalidInstall
    /// The runtime has not finished booting (no index yet).
    case notBooted
    /// The committed workspaces of this install name more than one owner (or an owner other than the pinned one): one owner per install,
    /// so the boot is refused and nothing is rebuilt. Leaving Live is the way out.
    case ownerDisagreement
    /// The install record could not be written (or did not read back): the flow stops before any Live secret or index row exists.
    case installNotSaved
    /// Live entry is not possible in the current state (a realm is active, a wipe is unfinished, or an entry is already running).
    case entryUnavailable
    /// The relay could not be reached to remove a push registration; the cleanup stays owed.
    case pushCleanupFailed(String)
    /// The invitation names another relay origin than this install's: refused before any network access.
    case differentOrigin
    /// Not an `https` relay origin the Live realm accepts (no loopback `http`, no Demo origin).
    case unsupportedOrigin
}

/// The persisted fact that this iPhone is a Live install: the ONE relay origin (taken only from an invitation, B2b) and, once the first
/// pairing committed, the owner key it pinned. One origin and one owner per Live install; it is never retargeted.
struct LiveInstall: Codable, Equatable, Sendable {
    var origin: String
    /// base64url x963 of the pinned owner key; nil until the first pairing committed.
    var owner: String?
}

struct LiveInstallStore {
    static let key = "orch.live.install"
    let defaults: UserDefaults
    func load() -> LiveInstall? { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(LiveInstall.self, from: $0) } }
    /// Limits: the read-back goes through the same `UserDefaults` object, so it catches an encoding fault or a store that drops the write,
    /// not a failed flush to disk after it. Throws when the record cannot be encoded or does not read back: a Live install that is not durably recorded must fail the flow that
    /// needed it (no silent `try?`).
    func save(_ install: LiveInstall) throws {
        let data = try JSONEncoder().encode(install)
        defaults.set(data, forKey: Self.key)
        guard defaults.data(forKey: Self.key) == data else { throw LiveError.installNotSaved }
    }
    func clear() { defaults.removeObject(forKey: Self.key) }
    /// Present but unreadable still counts as an install: a corrupt record must not read as "no Live" (it would let Demo start next to
    /// Live data). `load` is nil then and boot reports a failed start instead.
    var exists: Bool { defaults.object(forKey: Self.key) != nil }
}

/// Everything a Live runtime stands on, built in one place so a test can inject all of it. `production()` is the only construction the app
/// uses; it has no in-memory vault and no loopback transport.
struct LiveStorage: Sendable {
    var layout: StoreLayout
    var backend: any VaultBackend
    /// Simulator only (software custody); a device uses the Secure Enclave and ignores it.
    var lock: SimulatedLock
    /// Monotonic clock for polling and deadlines (`WorkspaceSessionConfig.clock` must not be wall-derived).
    var clock: any Clock<Duration>
    var wall: any WallClock
    var entropy: any Entropy
    var makeTransport: @Sendable (RealmContext) throws -> any RelayTransport
    /// Removes delivered and pending notifications of one workspace. Best effort and bounded: a wedged daemon never holds a wipe.
    var purgeNotifications: @Sendable (_ workspace: String) async -> Void

    static func production() throws -> LiveStorage {
        guard let backend = KeychainBackend.fromBundle() else { throw LiveError.keychainUnavailable }
        return LiveStorage(layout: try liveLayout(), backend: backend, lock: SimulatedLock(), clock: ContinuousClock(), wall: SystemWallClock(),
                           entropy: SystemEntropy(), makeTransport: { try LiveTransport.make(context: $0) },
                           purgeNotifications: { await LiveNotifications.purge(workspace: $0) })
    }

    /// `<Application Support>/OrchLive/app/orch/live/...`, and the Live realm's subdirectories of both App Groups (push state, share
    /// staging and quarantine). Without the App Group entitlement (unsigned builds) the groups fall back under the app root, like Demo's.
    static func liveLayout() throws -> StoreLayout {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OrchLive", isDirectory: true)
        func group(_ id: String, _ fallback: String) -> URL {
            fm.containerURL(forSecurityApplicationGroupIdentifier: id) ?? base.appendingPathComponent(fallback, isDirectory: true)
        }
        return try StoreLayout(appRoot: base.appendingPathComponent("app", isDirectory: true),
                               pushGroupRoot: group("group.io.severin.orch", "push"),
                               shareGroupRoot: group("group.io.severin.orch.share", "share"),
                               realm: Realm.live.rawValue)
    }

    func keysVault() -> SecretVault { SecretVault(group: .keys, backend: backend) }
    func pushVault() -> SecretVault { SecretVault(group: .push, backend: backend) }

    /// Secure Enclave on a device, software keys on the Simulator. Passphrase custody for the Simulator (orch-core #465) is a later item.
    func makeCustody() -> any DeviceKeyCustody {
        #if targetEnvironment(simulator)
        DefaultCustody.make(vault: keysVault(), lock: lock)
        #else
        DefaultCustody.make(vault: keysVault())
        #endif
    }

    /// Removes the Live files (realm directory and the Live subdirectories of both App Groups) without the keychain or the index. Tombstone
    /// coordination files stay (a burnt generation stays burnt).
    static func removeLiveFiles(layout: StoreLayout) throws {
        let fm = FileManager.default
        var first: (any Error)?
        for dir in [layout.realmDir,
                    layout.pushDir.appendingPathComponent("state").appendingPathComponent(layout.realm, isDirectory: true),
                    layout.shareDir.appendingPathComponent("staging").appendingPathComponent(layout.realm, isDirectory: true),
                    layout.shareDir.appendingPathComponent("quarantine").appendingPathComponent(layout.realm, isDirectory: true)]
        where fm.fileExists(atPath: dir.path) {
            do { try fm.removeItem(at: dir) } catch { if first == nil { first = error } }
        }
        if let first { throw first }
    }

    /// The realm-wide local wipe over UNFENCED vaults: what Leave Live runs, and what a launch runs to finish an interrupted one.
    func realmWipe(hooks: any WipeHooks) -> RealmWipe {
        RealmWipe(RealmWipe.Config(realm: .live, layout: layout, custody: makeCustody(), vaults: [keysVault(), pushVault()], hooks: hooks))
    }

    func wipeHooks() -> LiveWipeHooks {
        LiveWipeHooks(keys: keysVault().scoped(to: .live), push: pushVault().scoped(to: .live), purge: purgeNotifications)
    }
}

/// Per-workspace wipe hooks of the Live realm: unfenced vault views (the teardown path), best-effort notification purge.
struct LiveWipeHooks: WipeHooks {
    let keys: RealmVault
    let push: RealmVault
    let purge: @Sendable (String) async -> Void
    func quiesce(realm: String, ws: String) async throws {}
    func purgeNotifications(realm: String, ws: String) async throws { await purge(ws) }
    func purgeSecrets(realm: String, ws: String) async throws {
        try keys.wipe(ws: ws)
        try push.wipe(ws: ws)
    }
}

enum LiveNotifications {
    static func purge(workspace ws: String) async {
        let delivered: [String]? = await boundedOSCall(seconds: 2) { done in
            UNUserNotificationCenter.current().getDeliveredNotifications { done($0.filter { $0.request.content.threadIdentifier == ws }.map(\.request.identifier)) }
        }
        if let delivered, !delivered.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: delivered) }
        let pending: [String]? = await boundedOSCall(seconds: 2) { done in
            UNUserNotificationCenter.current().getPendingNotificationRequests { done($0.filter { $0.content.threadIdentifier == ws }.map(\.identifier)) }
        }
        if let pending, !pending.isEmpty { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: pending) }
    }
}

/// The Live realm on this iPhone: exactly one `RealmContext` (one relay origin, one owner), one `WorkspaceIndex` bound to its generation,
/// protected containers, realm-scoped vaults, and the real transport. What `DemoRuntime` is for the in-process fakes.
///
/// Lifetime: the CONTEXT is created synchronously by `init`, before any boot work starts, so a teardown can `invalidate()` a boot that is
/// still running (the index opening, a wipe being resumed, sessions being rebuilt): from then on none of it can sign, send or commit.
/// `boot()` then does the asynchronous part; `shutdown()` is the Leave/Reset path.
@MainActor
final class LiveRuntime: RealmRuntime {
    var realm: Realm { .live }
    /// Drop, share and push come back when owner-approved relay routes exist; Live starts with all of them off.
    var capabilities: RealmCapabilities = .live
    var deviceLabel = "iPhone"
    var nowMs: Int64 { storage.wall.nowMs }

    /// The one context of this runtime. Everything built here (transport, index, pairing, sessions) is bound to its generation.
    let context: RealmContext
    let install: LiveInstall
    let storage: LiveStorage
    private let keys: SecretVault
    private let push: SecretVault
    private let custody: any DeviceKeyCustody
    let transport: any RelayTransport
    private(set) var index: WorkspaceIndex?
    private(set) var booted = false
    /// Committed workspaces that could not be rebuilt (stable reason tags). They stay in the index untouched.
    private(set) var skipped: [(ws: String, reason: String)] = []
    /// The owner key (base64url x963) the committed workspaces agree on, derived at boot when the install record carries no pin yet (the
    /// record is written after the first commit, so a crash between the two leaves the profiles as the source of truth). The services
    /// persist it with a throwing save. nil when no workspace is committed or the record already pins one.
    private(set) var derivedOwner: String?
    /// The owner key the install record carries (base64url x963); set once it is durably recorded.
    var recordedOwner: String?
    private var restored: [JoinedHandle] = []
    private var realmWipe: RealmWipe?
    #if DEBUG
    /// Tests: awaited at named boot steps ("index", "recover", "restore") so a teardown can be raced against a boot in progress.
    var bootGate: (@Sendable (String) async -> Void)?
    #endif
    private func step(_ name: String) async throws {
        #if DEBUG
        await bootGate?(name)
        #endif
        try checkCurrent()
    }

    init(install: LiveInstall, storage: LiveStorage) throws {
        guard storage.layout.realm == Realm.live.rawValue else { throw RealmViolation.wrongStore }
        var owner: SigningPublicKey?
        if let text = install.owner {
            guard let bytes = B64U.decode(text), let key = try? SigningPublicKey(x963: bytes) else { throw LiveError.invalidInstall }
            owner = key
        }
        let context = try RealmContext.live(origin: install.origin, pinnedOwner: owner)
        let transport = try storage.makeTransport(context)
        // A runtime owns exactly one RealmContext: a transport on any other generation would not stop when this one is invalidated.
        guard transport.context.sharesLifetime(with: context), transport.context.origin == context.origin, transport.context.realm == .live else {
            throw RealmViolation.wrongTransport
        }
        self.install = install; self.storage = storage; self.context = context; self.transport = transport
        recordedOwner = install.owner
        keys = storage.keysVault(); push = storage.pushVault(); custody = storage.makeCustody()
    }

    // MARK: Boot

    /// Opens the realm (no wipe: Live data survives launches), then resumes interrupted workspace wipes, reconciles interrupted pairings
    /// and rebuilds the sessions of committed workspaces. Idempotent after success; a failure can be retried. Every step re-checks the
    /// realm, so a teardown that invalidated the context ends the boot at the next step.
    func boot() async throws {
        guard !booted else { return }
        try await step("start")
        let idx: WorkspaceIndex
        if let index { idx = index } else {
            idx = try await WorkspaceIndex(layout: storage.layout, fence: context.writeFence)       // the fence is bound at construction
            index = idx                                  // kept even if the realm ended meanwhile: the wipe closes it
        }
        try await step("index")
        try await LocalWipe(index: idx, hooks: storage.wipeHooks()).resumePendingWipes()
        try await step("wipes")
        // Pairing recovery: finishes what a crashed pairing left (secrets, directories, new keys). Best effort; "not clean" retries next launch.
        let recovery = makeBootCoordinator(idx)
        _ = await recovery.recover()
        await recovery.realmShutdown()                 // the recovery coordinator is not kept: a retried boot builds a fresh one
        try await step("recover")
        derivedOwner = try await Self.agreedOwner(index: idx, pinned: install.owner)
        let outcome = try await WorkspaceRestoration.restore(RestoreConfig(
            context: context, transport: transport, index: idx, vault: keys, custody: custody, clock: storage.clock, wall: storage.wall,
            entropy: storage.entropy))
        do { try await step("restore") }
        catch { await WorkspaceRestoration.release(outcome.handles); throw error }
        await WorkspaceRestoration.release(restored)   // handles of an earlier, unadopted boot (none normally)
        restored = outcome.handles
        skipped = outcome.skipped
        booted = true
    }

    /// One owner per install. With no pin yet, the committed profiles must agree with each other: more than one owner refuses the boot
    /// (nothing is rebuilt, nothing is erased), because the single-owner invariant was broken. Returns the owner to record when exactly one
    /// is committed. With a pin, a profile naming another owner is not rebuilt by `WorkspaceRestoration` (skipped with reason "owner",
    /// kept on disk, surfaced in Live Home); it never joins the session set.
    static func agreedOwner(index: WorkspaceIndex, pinned: String?) async throws -> String? {
        var owners = Set<String>()
        for row in try await index.workspaces() {
            guard let profile = try await index.profile(ws: row.ws) else { continue }
            // With a pin nothing is recorded: an undecodable row is left to the restore, which skips it ("pins") and Live Home flags it.
            // Without one, the value that WOULD be recorded must be a real key.
            if pinned == nil {
                guard let bytes = B64U.decode(profile.pkPub), (try? SigningPublicKey(x963: bytes)) != nil else { throw LiveError.invalidInstall }
            }
            owners.insert(profile.pkPub)
        }
        if pinned != nil { return nil }
        guard owners.count <= 1 else { throw LiveError.ownerDisagreement }
        return owners.first
    }

    private func checkCurrent() throws { guard context.isCurrent else { throw RealmViolation.staleGeneration } }

    // MARK: RealmRuntime

    func date(forMs ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    func makeCoordinator() throws -> PairingCoordinator {
        guard booted, let index else { throw LiveError.notBooted }
        return makeBootCoordinator(index)
    }

    private func makeBootCoordinator(_ index: WorkspaceIndex) -> PairingCoordinator {
        PairingCoordinator(PairingConfig(context: context, transport: transport, index: index, vault: keys, custody: custody,
                                         clock: storage.clock, wall: storage.wall, entropy: storage.entropy, deviceLabel: deviceLabel))
    }

    /// The workspaces `boot` rebuilt (handed over once).
    func restoreWorkspaces() async throws -> [JoinedHandle] {
        defer { restored = [] }
        return restored
    }

    func wipe(workspace: ID16, generation: Int64) async throws {
        guard let index else { throw LiveError.notBooted }
        let wipe = LocalWipe(index: index, hooks: storage.wipeHooks())
        do { try await wipe.wipe(ws: workspace.hex, generation: generation) }
        catch {
            // A tombstoned, half-finished wipe resumes from its persisted phase; only a finished wipe of THIS workspace counts.
            try await wipe.resumePendingWipes()
            let finished = try await index.tombstones().contains {
                $0.record.ws == workspace.hex && $0.record.generation >= generation && $0.phase >= LocalWipe.donePhase
            }
            guard finished else { throw error }
        }
    }

    func invalidate() { context.invalidate() }

    /// Sessions and coordinators are cancelled and awaited, then the containers of unadopted restored workspaces and the index are closed.
    /// The runtime is unusable afterwards (a later `shutdown` opens the persisted index itself for the wipe).
    func drain() async {
        await context.shutdownParticipants()
        await WorkspaceRestoration.release(restored); restored = []
        await index?.close()
        index = nil; booted = false
    }

    var writeFence: (any WriteFence)? { context.writeFence }

    /// Leave Live / Reset: the generation ends (idempotent; teardown already did it before its first await), every session and coordinator
    /// is cancelled and awaited (bounded), then the realm-wide wipe runs over unfenced vaults. A failure leaves everything a retry needs.
    func shutdown() async throws {
        invalidate()
        await context.shutdownParticipants()
        await WorkspaceRestoration.release(restored); restored = []
        let run = realmWipe ?? storage.realmWipe(hooks: storage.wipeHooks())
        realmWipe = run
        try await run.run(index: index)
        index = nil; booted = false
    }

    @discardableResult
    func rebuildPresentationGate() async -> Bool {
        guard let index else { return false }
        return await PresentationGate.rebuild {
            let t = try await index.tombstones(), w = try await index.workspaces()
            return (t.map { ($0.record.ws, $0.record.generation) }, w.map { ($0.ws, $0.generation) })
        }
    }

    /// Where a workspace keeps its unsent new-ticket draft: inside its own directory, which the wipe deletes. Writes go through
    /// `writeFence` (see `LiveWorkspace`).
    func draftURL(workspace: ID16) -> URL? {
        try? storage.layout.wsDir(workspace.hex).appendingPathComponent("ticket-draft.json")
    }

    /// Push material for this realm, written through the realm's fence (a successor realm reuses the ids). Not used while `push` is off.
    func makePushSink() -> VaultPushSink? { VaultPushSink(vault: push.scoped(to: .live, fence: context.writeFence)) }

    /// The owed half of a Leave: the workspace's session is gone, the realm's device key is not (it goes with Leave Live or Reset, which
    /// unregister before they wipe). `registration_id: null` needs no membership, so it works after the host removed this device.
    func unregisterPush(workspace: ID16) async throws {
        switch await unregisterPushOutcome(workspace: workspace) {
        case .failed(let why): throw LiveError.pushCleanupFailed(why)
        case .rateLimited: throw LiveError.pushCleanupFailed("rate_limited")
        case .removed, .pushOff, .refused, .registered: return
        }
    }

    func unregisterPushOutcome(workspace: ID16) async -> PushRegistrationOutcome {
        do {
            try checkCurrent()
            let identity = try context.deviceIdentity(custody: custody, createIfMissing: false)
            return await PushService.unregisterAll(workspace: workspace, identity: identity, transport: transport)
        } catch { return .failed("\(error)") }
    }

    func beginWipe(workspace: ID16, generation: Int64) async throws {
        guard let index else { throw LiveError.notBooted }
        try await LocalWipe(index: index, hooks: storage.wipeHooks()).begin(ws: workspace.hex, generation: generation)
    }

    /// Completes a Live wipe that an earlier launch started and did not finish. No runtime is built: the wipe works from the layout and
    /// the vaults alone.
    static func finishInterruptedReset(storage: LiveStorage) async throws {
        try await storage.realmWipe(hooks: storage.wipeHooks()).run(index: nil)
    }
}

extension RealmCapabilities {
    /// Live starts with Drop, share, push and Demo controls off (docs/live-mode.md).
    static let live = RealmCapabilities(drop: false, share: false, push: false, demoControls: false)
}
