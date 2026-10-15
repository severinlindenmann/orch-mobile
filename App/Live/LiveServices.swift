import Foundation
import Observation
import OrchClient
import OrchFakeHost
import OrchProtocol
import OrchPush
import OrchCustody
import OrchShareStaging
import UserNotifications

/// The App's real service layer. In Demo it runs the real client stack against the in-process fakes (`DemoRuntime`); a build without a
/// reachable relay has no workspaces at all (pairing says so). Screens see only the view-model protocols (A4): never FakeHost, custody
/// or signing.
@MainActor @Observable
final class LiveServices: AppServices, HomeModel, DropModel, SettingsModel, ShareWorld {
    private enum Keys {
        static let demo = "orch.demo.entered"
        static let resetPending = "orch.demo.resetPending"
        /// The Live realm's own gate: set at the start of a Live Leave/Reset, cleared only after the realm-wide wipe succeeded. A launch that
        /// finds it set completes the wipe BEFORE any realm starts, so no Live successor ever runs next to unwiped Live data.
        static let liveResetPending = "orch.live.resetPending"
        /// A Live pairing got as far as the host's comparison or beyond (the Mac may hold a device entry). Cleared with the install.
        static let pairingProgressed = "orch.live.pairingProgressed"
    }

    let options: LaunchOptions
    private(set) var ready = false
    /// Derived from the attached runtime's realm, never from "a runtime exists".
    var isDemo: Bool { runtime?.realm == .demo }
    var isLive: Bool { runtime?.realm == .live }
    /// The persisted Live install record (origin and pinned owner). Present from the first Live invitation until a Leave/Reset wiped Live.
    var installStore: LiveInstallStore { LiveInstallStore(defaults: resetFlags) }
    var hasLiveInstall: Bool { installStore.exists }
    /// Why the Live runtime did not start (nil when it did, or when Live is not in use). The runtime stays attached and Live data stays
    /// untouched; foregrounding retries.
    private(set) var liveBootError: String?
    private(set) var live: [LiveWorkspace] = []
    /// Committed Live workspaces `LiveRuntime` could not rebuild at restore (kept on disk): surfaced in Live Home.
    private(set) var skippedWorkspaceCount = 0
    private(set) var liveNotice: String?
    @ObservationIgnored private var lastLiveBootError: (any Error)?
    /// True once this Live install ever had a join: a workspace on screen or kept, or a recorded owner. Decides whether a Leave says
    /// "finish removing it on your Mac" (there may be a device entry there) or only "Removed from this iPhone."
    /// UNKNOWN counts as yes: an install whose runtime did not boot (owner disagreement, bad record, no runtime) cannot say what the Mac
    /// saw, and a pairing that reached the host's approval is remembered in a flag even if nothing committed.
    var liveHadJoin: Bool {
        guard hasLiveInstall else { return false }
        if resetFlags.bool(forKey: Keys.pairingProgressed) { return true }
        guard let rt = runtime as? LiveRuntime, rt.booted else { return true }
        return rt.recordedOwner != nil || rt.install.owner != nil || !live.isEmpty || !rt.skipped.isEmpty || rt.derivedOwner != nil
    }
    /// Observed by the views: the install record lives in `UserDefaults`, which SwiftUI cannot track, so every change of it bumps this.
    private var installRevision = 0
    var liveInstalled: Bool { _ = installRevision; return hasLiveInstall }
    var liveProblem: String? { liveBootError }
    private(set) var pendingDecisions: [DecisionStatus] = []
    private(set) var lastChecked = Date()
    private var heldDropItems: [DropItem] = []
    var dropItems: [DropItem] { live.flatMap { $0.drop?.rows ?? [] } + heldDropItems }
    private(set) var demoPushResult: String?
    var onRetryShared: (() -> Void)?
    var onStopShared: (() -> Void)?
    var deviceLabel = "Demo iPhone"
    var notificationStatus: NotificationStatus = .notAsked
    private(set) var pushDiagnostics = ""
    private(set) var pendingServerCleanups: [PendingServerCleanup] = []
    /// What the attached realm offers (Drop, share, push, Demo controls), derived from its runtime. A graph with no realm (Welcome,
    /// recovery) offers nothing: no push registration, no share destinations, no Drop. Features are gated on these, never on `isDemo`.
    var capabilities: RealmCapabilities { runtime?.capabilities ?? .none }
    /// The realm of the attached runtime; nil while no realm is attached.
    var realm: Realm? { runtime?.realm }
    /// nil without an attached realm: such a graph has no share bridge.
    var shareRealm: String? { realm?.rawValue }
    var shareFence: (any WriteFence)? { runtime?.writeFence }
    var requiresShareFence: Bool { runtime?.realm == .live }
    /// Invalidated when the realm is left or retired: late completions check it before they write, sign or register anything.
    @ObservationIgnored private(set) var lifetime = RealmLifetime()
    /// Set by `RealmController`: realm transitions go through it. Without one (unit tests) leaving only tears this graph down.
    @ObservationIgnored weak var transitions: (any RealmTransitions)?
    /// Per realm; nil until a realm is attached.
    @ObservationIgnored private(set) var cleanupStore: ServerCleanupStore?
    var cleanupDefaults: UserDefaults { resetFlags }
    /// The server-side half of Leave (push unsubscribe, membership removal). Demo simulates it; it throws while offline.
    @ObservationIgnored var serverCleanup: (PendingServerCleanup) async throws -> Void = { _ in }
    var pairingScenario: PairingScenario = .firstTime
    var signOutcome: SignOutcome = .accepted
    @ObservationIgnored private(set) var runtime: (any RealmRuntime)?
    /// The Demo interface of the runtime; nil outside Demo. Everything Demo-only goes through it.
    var demo: (any DemoControls)? { runtime as? any DemoControls }
    @ObservationIgnored var beforeWorkspaceRemoval: ((String) -> Bool)?
    @ObservationIgnored var onRedirectQuarantined: ((_ jobID: String, _ workspaceID: String) -> Void)?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var bootTask: Task<(any RealmRuntime)?, Never>?
    @ObservationIgnored private var submitted: [String: ReviewValue] = [:]
    /// Keyed "<workspace hex>/<decision hex>"; an entry is removed when its task ends.
    @ObservationIgnored private var reconcileTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var reconcileSerials: [String: Int] = [:]
    @ObservationIgnored private var reconcileSerial = 0
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var demoLockRelease: Task<Void, Never>?
    private(set) var lifecycle: [String: WorkspaceLifecycle] = [:]
    private(set) var active = true
    @ObservationIgnored private var refreshTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var failedReset: (any RealmRuntime)?
    private(set) var resetIncomplete = false
    @ObservationIgnored private let resetFlags: UserDefaults
    @ObservationIgnored private var resetRevision = 0
    // Injection points exercise failure boundaries without weakening the runtime availability check.
    @ObservationIgnored var wipeWorkspace: (any RealmRuntime, LiveWorkspace) async throws -> Void = { runtime, ws in
        try await runtime.wipe(workspace: ws.workspaceID, generation: ws.generation)
    }
    /// Writes the workspace wipe's tombstone (intent) without wiping. A test seam.
    @ObservationIgnored var beginWorkspaceWipe: (any RealmRuntime, LiveWorkspace) async throws -> Void = { runtime, ws in
        try await runtime.beginWipe(workspace: ws.workspaceID, generation: ws.generation)
    }
    @ObservationIgnored var resetRuntime: (any RealmRuntime) async throws -> Void = { try await $0.shutdown() }

    @ObservationIgnored var finishInterruptedReset: () async throws -> Void = { try await DemoRuntime.finishInterruptedReset() }
    /// Everything Live stands on (layout, keychain, clocks, transport). Production fails closed without a keychain configuration.
    @ObservationIgnored var liveStorage: () throws -> LiveStorage = { try LiveStorage.production() }
    /// Completes an interrupted Live wipe from storage alone (no runtime).
    /// Writes the install record. The default is the throwing `LiveInstallStore.save`; a failure fails the Live entry (a test seam).
    @ObservationIgnored var persistInstall: ((LiveInstall) throws -> Void)?
    /// Removes the Live files without touching the keychain (the stuck-wipe escape). Keychain leftovers go at the next Live entry.
    /// (DEBUG `--live-test-relay` points it at the test layout.)
    @ObservationIgnored var removeLiveFiles: () throws -> Void = { try LiveStorage.removeLiveFiles(layout: try LiveStorage.liveLayout()) }
    @ObservationIgnored private var enteringLive = false
    /// The Live pairing on screen, if any (scene changes pause and resume it).
    @ObservationIgnored weak var livePairing: LivePairingModel?
    @ObservationIgnored var finishInterruptedLiveReset: (LiveStorage) async throws -> Void = { try await LiveRuntime.finishInterruptedReset(storage: $0) }
    #if DEBUG
    /// Tests: installed on the Live runtime at creation so a teardown can be raced against a boot in progress.
    @ObservationIgnored var liveBootGate: (@Sendable (String) async -> Void)?
    #endif
    private func finishLiveReset() async throws { try await finishInterruptedLiveReset(try liveStorage()) }
    /// Cleanups and gates of the reset in progress, kept across retries and cleared only after the wipe succeeded (L4).
    @ObservationIgnored private var cleanupToClear: [ServerCleanupStore] = []
    @ObservationIgnored private var resetFlagKeys: Set<String> = []

    func state(for id: String) -> WorkspaceLifecycle { lifecycle[id] ?? .removed }
    func isLive(_ id: String) -> Bool { state(for: id) == .live }
    func canUse(_ id: String) -> Bool { lifetime.isActive && active && isLive(id) }
    func register(_ ws: LiveWorkspace) {
        ws.services = self
        // A re-paired workspace is a new membership: an old cleanup must never reach it.
        pendingServerCleanups = cleanupStore?.remove(ws: ws.workspaceID.hex) ?? []
        PresentationGate.unblock(ws.workspaceID.hex)
        lifecycle[ws.info.id] = .live
        live.append(ws)
    }
    func waitForLifecycle() async { await lifecycleTask?.value }
    func waitForReset() async { await resetTask?.value }

    func transition(_ id: String, to state: WorkspaceLifecycle) {
        if state != .live { live.first { $0.info.id == id }?.drop?.cancelUI(clear: true) }
        // Removing, removal-incomplete (quarantined) and removed workspaces never present a foreground notification.
        if state != .live { PresentationGate.block(id) }
        lifecycle[id] = state
        if state != .live { refreshTasks[id]?.cancel(); refreshTasks[id] = nil }
    }

    init(options: LaunchOptions, runtime: (any RealmRuntime)? = nil, resetFlags: UserDefaults? = nil) {
        self.resetFlags = resetFlags ?? (options.uiTesting
            ? UserDefaults(suiteName: "orch.tests.\(UUID().uuidString)")! : .standard)
        self.options = options
        #if DEBUG
        if options.uiTesting, options.liveTestRelay {
            let storage = LiveUITestSupport.makeStorage()
            liveStorage = storage
            removeLiveFiles = { try LiveStorage.removeLiveFiles(layout: try storage().layout) }
        }
        #endif
        if let runtime { attach(runtime) }
    }

    /// Binds the realm's runtime: capabilities and the realm-scoped cleanup list follow it.
    private func attach(_ r: any RealmRuntime) {
        runtime = r
        let store = ServerCleanupStore(defaults: resetFlags, realm: r.realm)
        cleanupStore = store
        pendingServerCleanups = store.load()
        // Live's owed cleanup is the push unsubscribe (the Mac-side removal is finished on the Mac). Demo simulates it.
        if r.realm == .live {
            serverCleanup = { [weak r] item in
                // A runtime that is gone cannot clean anything: the item stays owed, it is not reported as done.
                guard let r else { throw LiveError.notBooted }
                guard let id = ID16(hex: item.ws) else { return }          // an unreadable id can never be cleaned: drop it
                try await r.unregisterPush(workspace: id)
            }
        }
    }

    // MARK: Boot

    /// `enterDemo`: the Welcome choice "Try Demo" (the controller boots a fresh realm for it) instead of a launch flag or persisted entry.
    /// `launch`: this is the app's first realm, so launch flags and the persisted Demo entry apply; a realm created by a later transition starts exactly as asked.
    /// Whether this graph's own boot asked for Demo (launch flag, persisted entry or Welcome choice).
    @ObservationIgnored private(set) var wantsDemo = false

    func boot(enterDemo: Bool = false, launch: Bool = true) async {
        guard !ready else { return }
        let defaults = UserDefaults.standard
        // Ticket drafts now live in the workspace directory; remove any older copy that outlived a Leave.
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("orch.ticket.draft.") { defaults.removeObject(forKey: key) }
        // An interrupted wipe of ANY realm is finished first, before any realm starts (even a requested Demo).
        if resetFlags.bool(forKey: Keys.liveResetPending) {
            do {
                try await finishLiveReset()
                clearLiveRealmRecords()
                resetFlags.set(false, forKey: Keys.liveResetPending)
            } catch {
                resetIncomplete = true
                PresentationGate.requireRebuild()
            }
        }
        if !options.uiTesting, resetFlags.bool(forKey: Keys.resetPending) {
            // A Demo reset was interrupted: finish it first, whether or not Demo was entered.
            do {
                try await finishInterruptedReset()
                ServerCleanupStore(defaults: resetFlags, realm: .demo).clear()
                resetFlags.set(false, forKey: Keys.resetPending)
            } catch {
                resetIncomplete = true
                PresentationGate.requireRebuild()
            }
        }
        if resetIncomplete {
            // An unfinished wipe blocks every realm, even a requested Demo: recovery comes first.
            wantsDemo = false
            await ensurePresentationGate(intendedDemo: false)
            ready = true
            return
        }
        // A persisted Live install restores on every launch; it wins over a persisted Demo entry (one active realm). A realm entered
        // by a later transition (`launch == false`) starts exactly as asked.
        var liveWanted = false
        if launch, installStore.exists, !enterDemo {
            liveWanted = true
            await startLive()
        }
        let persisted = launch && !liveWanted && !options.uiTesting && defaults.bool(forKey: Keys.demo)
        wantsDemo = !liveWanted && ((launch && options.demo) || persisted || enterDemo)
        if wantsDemo { _ = await startDemo() }
        if launch, options.demoSeed, isDemo { await seedDemoWorkspaces() }
        await ensurePresentationGate(intendedDemo: wantsDemo || liveWanted)
        // Demo boot retries owed purges itself, ordered after its stale purge; only a live start needs it here.
        if !isDemo { Task.detached { await SystemDemoNotifications().retryOwedPurges() } }
        ready = true
    }

    /// What a successful Live wipe also removes: the install record and the realm's pending server cleanups.
    private func clearLiveRealmRecords() {
        installStore.clear()
        resetFlags.removeObject(forKey: Keys.pairingProgressed)
        installRevision += 1
        ServerCleanupStore(defaults: resetFlags, realm: .live).clear()
    }

    /// Starts the Live runtime from the persisted install. The runtime (and with it the realm context) is created and attached
    /// synchronously, BEFORE the boot task starts, so `teardown` can invalidate a boot in progress (M3). A start that fails keeps the
    /// runtime attached and Live data untouched; the failure is visible as `liveBootError` and foregrounding retries.
    private func startLive() async {
        guard !retired, runtime == nil else { return }
        guard let install = installStore.load() else { liveBootError = "The Live record on this iPhone is unreadable."; PresentationGate.requireRebuild(); return }
        let runtime: LiveRuntime
        do { runtime = try LiveRuntime(install: install, storage: try liveStorage()) }
        catch {
            // Nothing is attached: the graph has no realm. Live data and its share destinations stay as they are.
            liveBootError = "Live could not start (\(error))."
            PresentationGate.requireRebuild()
            return
        }
        attach(runtime)
        runtime.deviceLabel = deviceLabel
        #if DEBUG
        runtime.bootGate = liveBootGate
        #endif
        await bootLive(runtime)
    }

    private func bootLive(_ runtime: LiveRuntime) async {
        if let bootTask { _ = await bootTask.value; return }
        let revision = resetRevision
        let task = Task { () -> (any RealmRuntime)? in
            do { try await runtime.boot(); return runtime } catch { self.lastLiveBootError = error; return nil }
        }
        bootTask = task
        let result = await task.value
        guard revision == resetRevision, self.runtime === runtime else { return }     // a teardown replaced this boot
        bootTask = nil
        guard result != nil else {
            if let e = lastLiveBootError as? LiveError, e == .ownerDisagreement {
                liveBootError = "This iPhone holds workspaces from two different owners, which one Live install never allows, so nothing was opened. Leave Live to start over; your Macs are not changed."
            } else {
            liveBootError = "Live could not start. It will try again when you return to orch."
            }
            PresentationGate.requireRebuild()
            return
        }
        liveBootError = nil
        skippedWorkspaceCount = runtime.skipped.count
        // The owner pin is derived from the committed profiles when the record has none yet (a crash between the first commit and the
        // record write): recorded with a throwing save, so a failure is visible and retried at the next launch.
        recordOwner(runtime.derivedOwner, runtime: runtime)
        await runtime.rebuildPresentationGate()
        for handle in (try? await runtime.restoreWorkspaces()) ?? [] { workspaceJoined(handle, lifetime: lifetime) }
    }

    func notePairingProgress() { if hasLiveInstall { resetFlags.set(true, forKey: Keys.pairingProgressed) } }

    private func save(_ install: LiveInstall) throws {
        if let persistInstall { try persistInstall(install) } else { try installStore.save(install) }
    }

    /// Records the single owner of this Live install (once). A failed write keeps the join and says so; the next boot derives it again.
    /// Only for the runtime it was started for, in a graph that is still alive: a Leave that ran meanwhile must not be partly undone by
    /// re-saving the install record.
    func recordOwner(_ owner: String?, runtime: LiveRuntime) {
        guard let owner, runtime.recordedOwner == nil, !retired, lifetime.isActive, (self.runtime as AnyObject?) === runtime else { return }
        do {
            try save(LiveInstall(origin: runtime.install.origin, owner: owner))
            runtime.recordedOwner = owner
            liveNotice = nil
        } catch {
            liveNotice = "orch could not record the owner of this workspace yet. It will try again the next time orch starts."
        }
    }

    // MARK: Live entry (B2b)

    /// The runtime a Live pairing for an invitation at `origin` runs on. Everything that must not happen before the person said "Connect"
    /// has not: this is called by the Connect action only.
    ///
    /// Order for a first entry (each step completes before the next):
    ///   1. the origin must be an `https` Live origin (no loopback `http`, no Demo origin), and no other realm may be active;
    ///   2. orphans are wiped: the keychain survives an uninstall, so leftover Live items and device keys are removed first
    ///      (`wipe(realm: .live)` on both vault groups, `custody.delete(realm: .live)`, the Live files) and a keychain that cannot be
    ///      read stops the entry here, before anything is written;
    ///   3. the install record is persisted (throwing); a failure fails the entry with nothing left behind;
    ///   4. only then the runtime is created and booted, so no Live keychain item or index row can exist without an install record.
    /// An existing install is reused only for its own origin; any other origin is refused before any network access.
    func liveRuntimeForPairing(origin: String) async throws -> LiveRuntime {
        guard !retired, lifetime.isActive else { throw LiveError.entryUnavailable }
        guard Self.isLiveOrigin(origin) else { throw LiveError.unsupportedOrigin }
        if let existing = runtime as? LiveRuntime {
            guard existing.install.origin == origin else { throw LiveError.differentOrigin }
            guard existing.booted else { throw LiveError.notBooted }
            return existing
        }
        if let install = installStore.load() {
            guard install.origin == origin else { throw LiveError.differentOrigin }
            throw LiveError.entryUnavailable           // Live is installed but not running: it recovers or is left, never re-entered
        }
        guard runtime == nil, !hasLiveInstall, !resetIncomplete, !enteringLive else { throw LiveError.entryUnavailable }
        enteringLive = true
        defer { enteringLive = false }
        let storage = try liveStorage()
        // 2. orphans
        try await storage.realmWipe(hooks: storage.wipeHooks()).run(index: nil)
        guard !retired, lifetime.isActive, runtime == nil, !hasLiveInstall else { throw LiveError.entryUnavailable }
        // 3. the record
        let install = LiveInstall(origin: origin, owner: nil)
        do { try save(install) } catch { installStore.clear(); throw error }
        // 4. the runtime
        let created: LiveRuntime
        do { created = try LiveRuntime(install: install, storage: storage) }
        catch { installStore.clear(); throw error }
        attach(created)
        installRevision += 1
        created.deviceLabel = deviceLabel
        #if DEBUG
        created.bootGate = liveBootGate
        #endif
        transitions?.realmEnteredLive()
        await bootLive(created)
        guard created.booted else { throw LiveError.notBooted }
        return created
    }

    /// `https` only and not the Demo origin: what `RealmContext.live` accepts, checked here too so a refusal happens before anything else.
    static func isLiveOrigin(_ origin: String) -> Bool {
        origin.hasPrefix("https://") && (try? RealmContext.live(origin: origin)) != nil
    }

    /// The reviewed origin of the active or recorded Live install (nil without one).
    var liveOrigin: String? { (runtime as? LiveRuntime)?.install.origin ?? installStore.load()?.origin }

    /// The stuck-wipe escape: erases the Live files on this iPhone without waiting for the keychain or the index. Keychain items that
    /// cannot be removed now are removed at the next Live entry (the orphan wipe). Used only from the recovery card, after a confirmation.
    func forceEraseLive() async throws {
        retire()
        await waitForRetire()
        try removeLiveFiles()
        clearLiveRealmRecords()
        resetFlags.set(false, forKey: Keys.liveResetPending)
        resetIncomplete = false
        liveBootError = nil
        PresentationGate.openWithoutIndex()
    }

    /// Opens the foreground-presentation gate once the workspace index has been read. The app has one index, the runtime's
    /// (Demo or live realm alike); with no runtime and none wanted there are no workspaces and nothing to block. A wanted
    /// runtime that did not start, or an unreadable index, leaves the gate closed; the next foreground retries.
    func ensurePresentationGate(intendedDemo: Bool = false) async {
        if let runtime { await runtime.rebuildPresentationGate() }
        else if !intendedDemo { PresentationGate.openWithoutIndex() }
    }

    @discardableResult
    private func startDemo() async -> (any RealmRuntime)? {
        if let bootTask {
            let revision = resetRevision
            let result = await bootTask.value
            return revision == resetRevision ? result : nil
        }
        await resetTask?.value
        // Another caller may have booted (or started booting) while the reset was awaited.
        if let bootTask {
            let revision = resetRevision
            let result = await bootTask.value
            return revision == resetRevision ? result : nil
        }
        if let runtime { return runtime }
        guard failedReset == nil else { return nil }
        let revision = resetRevision
        let task = Task { () -> (any RealmRuntime)? in
            do { return try await DemoRuntime.boot(temporaryStorage: self.options.uiTesting) } catch { return nil }
        }
        bootTask = task
        let r = await task.value
        guard revision == resetRevision else { return nil }
        bootTask = nil
        if let r { attach(r) }
        if r == nil { PresentationGate.requireRebuild() }
        if let r {
            r.deviceLabel = deviceLabel; await r.rebuildPresentationGate()
            // Committed workspaces of an earlier launch (none in Demo: its boot wipes the previous realm).
            for handle in (try? await r.restoreWorkspaces()) ?? [] { workspaceJoined(handle, lifetime: lifetime) }
        }
        if !options.uiTesting { UserDefaults.standard.set(r != nil, forKey: Keys.demo) }
        return r
    }

    /// The running Demo, booting it first when "Try Demo" is still starting it.
    func demoRuntime() async -> (any DemoControls)? {
        if let demo { return demo }
        if isDemo || bootTask != nil { return await startDemo() as? any DemoControls }
        return nil
    }

    /// DEBUG UI tests only: pairs the two Demo workspaces through the same pairing model, with the Demo humans' explicit actions
    /// played by this loop, on a fast Demo clock.
    private func seedDemoWorkspaces() async {
        guard let runtime = demo else { return }
        runtime.speed = 10
        defer { runtime.speed = 1 }
        for _ in 0..<2 {
            let model = LivePairingModel(services: self, start: nil)
            model.useDemoInvitation()
            let deadline = Date().addingTimeInterval(90)
            var done = false
            while !done, Date() < deadline {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { model.cancel(); return }
                switch model.state {
                case .comparingHost where !model.demoHostCode.isEmpty: model.hostApprove()
                case .waitingPrimary: model.primaryOpenRequest()
                case .comparingPrimary where model.demoPrimaryHasChallenge: model.primaryApprove()
                case .ready, .refused, .alarm, .expired, .denied: done = true
                default: break
                }
            }
            model.cancel()
        }
        for ws in live { await ws.refresh() }
        await refreshPending()
    }

    // MARK: AppServices

    var home: any HomeModel { self }
    var drop: any DropModel { self }
    var settings: any SettingsModel { self }

    func workspace(_ id: String) -> any WorkspaceModel {
        live.first { $0.info.id == id } ?? RemovedWorkspaceModel(id: id)
    }

    func review(workspaceID: String, questionID: String, optionID: String) -> any QuestionReviewModel {
        guard canUse(workspaceID), let ws = live.first(where: { $0.info.id == workspaceID }) else { return UnavailableReviewModel() }
        return LiveReviewModel(services: self, workspace: ws, questionID: questionID, optionID: optionID)
    }

    func makePairing(start: PairingState?) -> any PairingFlowModel { LivePairingModel(services: self, start: start) }
    /// A Live pairing for a reviewed invitation; started by the person's explicit "Connect".
    func makeLivePairing(link: PairingLink) -> any PairingFlowModel { LivePairingModel(services: self, link: link) }

    func workspaceID(forQuestion id: String) -> String? { resolveQuestion(id)?.workspaceID }

    func resolveWorkspace(_ raw: String) -> String? {
        if let ws = live.first(where: { $0.info.id == raw }) { return ws.info.id }
        guard let demo else { return nil }
        return live.first { ws in demo.entry(for: ws.workspaceID)?.kind.alias == raw }?.info.id
    }

    func resolveQuestion(_ raw: String) -> (workspaceID: String, questionID: String)? {
        for ws in live {
            if ws.questions.contains(where: { $0.id == raw }) { return (ws.info.id, raw) }
            if let id = demo?.entry(for: ws.workspaceID)?.aliases[raw] { return (ws.info.id, id.hex) }
        }
        return nil
    }

    // MARK: Workspaces

    /// A completed pairing (or a restored workspace). `lifetime` is the realm lifetime the pairing started in: a join that completes
    /// after that realm was left or retired is dropped and builds nothing (no workspace, no Drop service, no session).
    func workspaceJoined(_ handle: JoinedHandle, lifetime joinedIn: RealmLifetime) {
        guard joinedIn === lifetime, lifetime.isActive, let runtime else { return }
        let j = handle.joined
        guard !live.contains(where: { $0.workspaceID == j.workspace }) else { return }
        let demo = self.demo
        let entry = demo?.entry(for: j.workspace)
        // Demo knows its fake hosts by name; any other realm uses the verified join identity and "Your Mac" (no authenticated host label).
        if demo != nil, entry == nil { return }
        demo?.markJoined(j.workspace)
        let kind = entry?.kind
        let info = WorkspaceInfo(
            id: j.workspace.hex, name: j.name, host: kind?.hostLabel ?? "Your Mac", hue: kind.map { $0.rawValue } ?? live.count,
            hostedBy: j.hosted.marker ? (j.hosted.hostedBy ?? "(unknown)") : nil, clientHosted: j.hosted.marker,
            scopes: Mapping.scopes(j.scopes), connection: .online, primaryLabel: demo != nil ? "Demo Mac" : "Your Mac",
            notificationsOn: capabilities.push)
        let ws = LiveWorkspace(workspaceID: j.workspace, generation: j.generation, api: BridgeWorkspaceAPI(session: j.session), info: info)
        ws.services = self
        ws.downloadContainer = j.downloadContainer
        ws.draftURL = runtime.draftURL(workspace: j.workspace)
        ws.draftFence = runtime.writeFence
        ws.requiresDraftFence = runtime.realm == .live
        // No Drop capability, no Drop: the service is never constructed, not merely hidden.
        if capabilities.drop, let service = try? j.makeDropService() { ws.drop = LiveDrop(service: service, workspace: ws) }
        register(ws)
        if isLive, capabilities.push { startPush(for: ws, joined: j) }
        Task {
            if let drop = ws.drop { await demo?.seedDropFixture(into: drop, workspace: j.workspace) }
            await ws.drop?.refresh()
        }
        ws.start()
        Task { await refreshPending() }
        if let live = runtime as? LiveRuntime, live.recordedOwner == nil {
            let hex = j.workspace.hex
            Task { [weak self, weak live] in
                guard let live, let owner = try? await live.index?.profile(ws: hex)?.pkPub else { return }
                self?.recordOwner(owner, runtime: live)
            }
        }
    }

    func workspaceRemoved(_ ws: LiveWorkspace) {
        Task { _ = await leave(workspaceID: ws.info.id, simulateOffline: false) }
    }

    func snapshotApplied(_ ws: LiveWorkspace) {
        reconcileNotifications()
        Task {
            if let ms = await ws.api.verifiedReceiptMs, let runtime { lastChecked = runtime.date(forMs: ms) } else { lastChecked = Date() }
        }
    }

    /// The notification centre the app replaces/removes through (a recorder in tests).
    @ObservationIgnored var notificationCenter: any NotificationCentering = UNNotificationCentering()
    /// Tests answer the permission question without the OS.
    @ObservationIgnored var notificationPermissionOverride: (() async -> NotificationStatus)?
    @ObservationIgnored private var notificationReconcileTask: Task<Void, Never>?
    @ObservationIgnored private var notificationReconcileDirty = false

    /// Replace-on-closed and reconcile-on-open. For every question this app knows is closed, a delivered (or scheduled) notification
    /// for it becomes "Answered on <device>" under the SAME identifier. Local Demo notifications never reach the notification
    /// extension, and a real push can arrive before the app learns the question closed, so the app does this itself on every
    /// applied snapshot and on foreground. Serialised; a stalled notification daemon only stalls this task.
    func reconcileNotifications() {
        if notificationReconcileTask != nil { notificationReconcileDirty = true; return }
        notificationReconcileTask = Task { [weak self] in
            while let self {
                self.notificationReconcileDirty = false
                var closed: [String: QuestionClosure] = [:]
                for ws in self.live where ws.usable {
                    for q in ws.answered {
                        closed["\(ws.workspaceID.hex)/\(q.id)"] = QuestionClosure(workspaceName: ws.info.name, deviceLabel: q.resolution?.byDeviceLabel ?? "")
                    }
                }
                await NotificationReconciler.reconcile(center: self.notificationCenter, closed: closed)
                if !self.notificationReconcileDirty { break }
            }
            self?.notificationReconcileTask = nil
        }
    }

    /// Lock/background: reviews and arming are dropped; return to foreground reads afresh and re-drives stored submissions.
    func setActive(_ active: Bool) {
        self.active = active
        livePairing?.setActive(active)
        if active, ready, liveBootError != nil {
            if let live = runtime as? LiveRuntime { if !live.booted { Task { await bootLive(live) } } }
            else if runtime == nil, hasLiveInstall { Task { await startLive() } }      // the runtime could not even be built: try again
        }
        if active, isLive, capabilities.push, !pendingServerCleanups.isEmpty { Task { await retryServerCleanup() } }
        if active, ready, !PresentationGate.isRebuilt { Task { await ensurePresentationGate(intendedDemo: wantsDemo || hasLiveInstall) } }
        if !active { for ws in live { ws.drop?.cancelUI(clear: false) } }
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks = [:]
        if !active { reconcileTasks.values.forEach { $0.cancel() } }
        let previous = lifecycleTask
        let workspaces = live
        lifecycleTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            for ws in workspaces {
                if let drop = ws.drop {
                    if active && self.canUse(ws.info.id) { try? await drop.service.activate() }
                    else { await drop.service.suspend() }
                }
                await ws.api.setForeground(active && self.canUse(ws.info.id))
            }
            guard active, self.active else { return }
            // Local retention is independent of relay authorization and Drop alarms.
            for ws in workspaces where ws.info.lifecycle != .removed {
                do { try await ws.downloadContainer?.purgeExpiredDownloads(nowMs: ws.drop?.alarm == true ? .max : (self.runtime?.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000))) }
                catch { ws.drop?.status = "Local cleanup needs retry" }
            }
            for ws in workspaces where self.canUse(ws.info.id) {
                ws.start()
                self.refreshTasks[ws.info.id] = Task { [weak self] in
                    await ws.drop?.foreground()
                    await ws.api.refreshViews()
                    guard !Task.isCancelled, let self, self.canUse(ws.info.id) else { return }
                    await self.refreshPending(reconcile: true)
                    self.reconcileNotifications()
                }
            }
        }
    }

    // MARK: HomeModel

    var workspaces: [WorkspaceInfo] { live.map(\.info) }

    var needsYou: [NeedsYouGroup] {
        live.compactMap { ws in
            let waiting = ws.waiting
            return waiting.isEmpty ? nil : NeedsYouGroup(workspace: ws.info, questions: waiting)
        }.sorted { ($0.questions.first?.created ?? .distantFuture) < ($1.questions.first?.created ?? .distantFuture) }
    }

    var needsYouCount: Int { live.reduce(0) { $0 + $1.waiting.count } }

    var oldestWaiting: (question: Question, workspace: WorkspaceInfo)? {
        live.flatMap { ws in ws.waiting.map { ($0, ws.info) } }.min { $0.0.created < $1.0.created }
    }

    func waitingCount(in workspaceID: String) -> Int { live.first { $0.info.id == workspaceID }?.waiting.count ?? 0 }

    var dropSummary: DropSummary {
        let unread = dropItems.filter { $0.direction == .received && $0.unread }
        return DropSummary(newCount: unread.count, lastName: unread.last?.name)
    }

    func enterDemo() {
        if let transitions { transitions.realmEnterDemo() } else { Task { await startDemo() } }
    }

    // MARK: Pending decisions (U8)

    func recordSubmission(_ review: ReviewValue) {
        guard lifetime.isActive else { return }
        submitted[review.questionID + "/" + review.optionID] = review
    }

    func storedDecision(workspace: LiveWorkspace, questionID: String) async -> ID16? {
        guard canUse(workspace.info.id), let qid = ID16(hex: questionID) else { return nil }
        return (try? await workspace.api.pendingDecisions())?.first { $0.questionID == qid }?.decisionID
    }

    func refreshPending(reconcile: Bool = false) async {
        guard lifetime.isActive else { return }
        var out: [DecisionStatus] = []
        for ws in live where canUse(ws.info.id) {
            // A store error is not an empty list: keep what is shown until the next read succeeds.
            guard let statuses = try? await ws.api.pendingDecisions(), canUse(ws.info.id), !Task.isCancelled else { return }
            for d in statuses {
                let q = ws.question(id: d.questionID.hex)
                let key = d.questionID.hex + "/" + d.optionID
                let review = submitted[key] ?? ReviewValue(
                    workspaceID: ws.info.id, workspaceName: ws.info.name, hue: ws.info.hue, clientHosted: ws.info.clientHosted,
                    hostedBy: ws.info.hostedBy, questionID: d.questionID.hex, ticket: q?.ticket ?? "", text: q?.text ?? "",
                    optionID: d.optionID, optionLabel: q?.options.first { $0.id == d.optionID }?.label ?? d.optionID,
                    options: q?.options ?? [], contentHash: q?.contentHash ?? "", revision: 0, isDemo: isDemo)
                let outcome: DecisionOutcomeState = switch d.state {
                case .uncertain: .uncertain
                case .needsRetry: .needsRetry
                case .pending: .pending
                }
                out.append(DecisionStatus(decisionID: d.decisionID.hex, questionID: d.questionID.hex, workspaceID: ws.info.id,
                                          optionID: d.optionID, optionLabel: review.optionLabel, review: review, outcome: outcome))
                if reconcile { startReconcile(workspace: ws, decisionID: d.decisionID) }
            }
        }
        pendingDecisions = out.filter { $0.outcome != .resolved }
    }

    /// Bounded background reconciliation while the app runs; the state stays visible on Home. It reconciles the stored decision only.
    func startReconcile(workspace: LiveWorkspace, decisionID: ID16) {
        guard canUse(workspace.info.id) else { return }
        if options.holdReconcile { Task { await refreshPending() }; return }
        let key = workspace.workspaceID.hex + "/" + decisionID.hex
        reconcileTasks[key]?.cancel()
        reconcileSerial += 1
        let serial = reconcileSerial
        reconcileSerials[key] = serial
        reconcileTasks[key] = Task { [weak self] in
            // Remove this task's own entry when it ends (finished, settled or cancelled), never a newer one under the same key.
            defer { self?.reconcileEnded(key: key, serial: serial) }
            for _ in 0..<6 {
                do { try await Task.sleep(for: .seconds(self?.options.uiTesting == true ? 20 : 4)) } catch { return }
                guard let self, self.canUse(workspace.info.id) else { return }
                if let outcome = try? await workspace.api.reconcile(decisionID: decisionID), outcome != .uncertain {
                    await self.decisionSettled(workspace: workspace)
                    return
                }
            }
        }
        Task { await refreshPending() }
    }

    private func reconcileEnded(key: String, serial: Int) {
        guard reconcileSerials[key] == serial else { return }
        reconcileTasks[key] = nil
        reconcileSerials[key] = nil
    }

    func decisionSettled(workspace: LiveWorkspace) async {
        guard lifetime.isActive else { return }
        await workspace.refresh()
        await refreshPending()
    }

    // MARK: Demo controls (real host behaviour, one shot)

    /// True once when "Review fails to load" is armed: the next review read is treated as failed (nothing is signed or stored).
    func takeDemoReadFailure() -> Bool {
        guard capabilities.demoControls, isDemo, signOutcome == .loadFails else { return false }
        signOutcome = .accepted
        return true
    }

    func applyDemoSignControl(workspace: LiveWorkspace, questionID: String, optionID: String) async {
        let outcome = signOutcome
        guard workspace.usable, outcome != .accepted, outcome != .loadFails, let runtime = demo,
              let host = runtime.entry(for: workspace.workspaceID)?.host, let qid = ID16(hex: questionID) else { return }
        signOutcome = .accepted              // one-shot
        switch outcome {
        case .alreadyAnswered:
            let first = workspace.question(id: questionID)?.options.first?.id ?? optionID
            try? await host.demoAnswerOnHost(question: qid, optionID: first)
        case .questionChanged:
            let text = workspace.question(id: questionID)?.text ?? ""
            try? await host.demoEditQuestion(qid, text: text + "\nEdited at the Mac.")
        case .uncertain:
            await host.demoLoseNextDecisionResponse(faults: runtime.faults)
        case .locked:
            // The simulated phone is locked for this attempt; it unlocks by itself a few seconds later (the person unlocking it).
            runtime.lock.isLocked = true
            demoLockRelease?.cancel()
            demoLockRelease = Task { [weak runtime] in
                try? await Task.sleep(for: .seconds(2))
                runtime?.lock.isLocked = false
            }
        default: break
        }
    }

    var deviceLocked: Bool { demo?.lock.isLocked ?? false }

    // MARK: DropModel (simulated: no Drop service yet)

    func items(_ direction: DropDirection) -> [DropItem] { dropItems.filter { $0.direction == direction } }
    func item(id: String) -> DropItem? { dropItems.first { $0.id == id || $0.presentationID == id } }
    func items(workspace: String) -> [DropItem] { dropItems.filter { $0.workspaceID == workspace } }

    func canSend(to workspaceID: String) -> Bool { eligibleShareDestination(workspaceID) }

    func send(_ draft: DropDraft) {
        guard canUse(draft.workspaceID), let drop = live.first(where: { $0.info.id == draft.workspaceID })?.drop else { return }
        drop.startSend(draft)
    }

    func refreshDrop() async {
        for ws in live where canUse(ws.info.id) { await ws.drop?.refresh() }
    }
    func verifyDropRow(_ id: String) async {
        if let item = item(id: id), let drop = dropState(item.id) { await drop.verifyVisible(item.id); return }
        // A fixture deep route resolves only after metadata verification; no fake object is inserted.
        if id.hasPrefix("d-") {
            await refreshDrop()
            for drop in live.compactMap(\.drop) {
                for row in drop.rows.prefix(12) {
                    await drop.verifyVisible(row.id)
                    if item(id: id) != nil { return }
                }
            }
        }
    }
    func dropState(_ id: String) -> LiveDrop? {
        live.compactMap(\.drop).first { $0.objects[id] != nil || $0.rows.contains { $0.presentationID == id } }
    }
    private(set) var shareStatus: String?
    var dropRefreshRevision: Int { live.reduce(0) { $0 + ($1.drop?.listRevision ?? 0) } }
    var dropStatus: String? { live.compactMap { $0.drop?.status }.first ?? shareStatus ?? (live.contains { $0.drop?.loading == true } ? "Loading…" : nil) }
    func shareProgress(_ value: String) { shareStatus = value }
    func waitForShareActivation() async {
        await waitForLifecycle()
        for task in Array(refreshTasks.values) { await task.value }
    }
    func eligibleShareDestination(_ id: String) -> Bool {
        capabilities.share && canUse(id) && live.first(where: { $0.info.id == id })?.drop?.canOperate == true
    }
    func stopShareJob(_ job: StagedJob, inbox: ShareInbox, workspaceID: String) async throws {
        guard eligibleShareDestination(workspaceID), let drop = live.first(where: { $0.info.id == workspaceID })?.drop else { throw DropError.suspended }
        try await drop.service.discardShareJob(job, inbox: inbox)
        await drop.refresh()
    }
    func importShareJob(_ job: StagedJob, inbox: ShareInbox, workspaceID: String) async throws {
        guard eligibleShareDestination(workspaceID), let drop = live.first(where: { $0.info.id == workspaceID })?.drop else { throw DropError.suspended }
        let mine = drop.revision
        let objects: [DropObject]
        do { objects = try await drop.service.importShareJob(job, inbox: inbox) }
        catch {
            if mine == drop.revision && drop.workspace?.usable == true { drop.report(error) }
            throw error
        }
        guard drop.canOperate, mine == drop.revision else { throw DropError.suspended }
        for (index, object) in objects.enumerated() {
            drop.aliases[object.descriptor.object.hex] = "share-\(job.manifest.jobID)-\(index)"
        }
        await drop.refresh()
    }

    func shareIdentity(of workspaceID: String) -> (ws: String, generation: Int64)? {
        return live.first { $0.info.id == workspaceID }.map { ($0.workspaceID.hex, $0.generation) }
    }

    func importShared(workspaceID: String, items: [PreviewWorld.SharedItem], expires: Date) {}

    func setQuarantined(_ entries: [(job: String, workspaceID: String, name: String, bytes: Int, kind: DropKind, expires: Date)]) {
        heldDropItems.removeAll { $0.quarantineJob != nil }
        for e in entries {
            heldDropItems.insert(DropItem(id: "share-q-\(e.job)", workspaceID: e.workspaceID, name: e.name, bytes: e.bytes, kind: e.kind,
                                      direction: .sending, expires: e.expires, versions: 1, unread: false, text: nil,
                                      from: "This iPhone", quarantineJob: e.job), at: 0)
        }
    }

    func redirectQuarantined(id: String, to workspaceID: String) {
        guard isLive(workspaceID), let job = dropItems.first(where: { $0.id == id })?.quarantineJob else { return }
        onRedirectQuarantined?(job, workspaceID)
    }

    func markRead(id: String) {
        if let drop = dropState(id), let index = drop.rows.firstIndex(where: { $0.id == id || $0.presentationID == id }) {
            drop.readIDs.insert(drop.rows[index].id); drop.rows[index].unread = false
        }
    }

    // MARK: SettingsModel

    var custody: String { DefaultCustody.isSecureEnclave ? "Secure Enclave" : "Software key (Simulator)" }

    var realmSummary: RealmSummary? {
        guard let realm else { return nil }
        let build = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + " ("
            + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")"
        let connection: String
        if realm == .demo { connection = "Simulated on this iPhone" }
        else if live.isEmpty { connection = "No workspace yet" }
        else if live.allSatisfy({ if case .online = $0.info.connection { true } else { false } }) { connection = "Connected" }
        else { connection = "Offline" }
        return RealmSummary(name: realm == .live ? "Live" : "Demo", origin: realm == .live ? liveOrigin : nil, custody: custody,
                            connection: connection, lastChecked: live.isEmpty ? nil : lastChecked, build: build)
    }

    func leaveLive(thenDemo: Bool) { leaveRealm(thenDemo: thenDemo) }

    func setNotifications(_ on: Bool, workspaceID: String) {
        guard capabilities.push, isLive(workspaceID) else { return }
        live.first { $0.info.id == workspaceID }?.setNotifications(on)
        if on, notificationStatus == .notAsked { Task { await ensureNotificationPermission() } }
    }

    private func map(_ state: PushPermission.State) -> NotificationStatus {
        switch state {
        case .notDetermined: .notAsked
        case .denied: .denied
        case .authorized, .provisional: .allowed
        }
    }

    /// Reads the real OS status (so a denial from an earlier run shows up) and, for a real installation that is allowed,
    /// attempts APNs registration. Demo never registers with APNs: there is no relay behind it.
    func refreshNotificationStatus() async {
        // Without the push capability nothing here touches the OS: no permission read, no APNs registration.
        guard capabilities.push else { notificationStatus = .notAsked; pushDiagnostics = ""; return }
        let state = await currentPermission()
        notificationStatus = map(state)
        if !isDemo, notificationStatus == .allowed { registerForAPNs(); Task { await registerPushAll() } }
        pushDiagnostics = PushDiagnostics.summary(isDemo: isDemo, permission: notificationStatus.rawValue, relay: pushCoordinator?.summary)
    }

    /// Asks the system once (never at launch) and waits for the answer.
    @discardableResult
    private func ensureNotificationPermission() async -> NotificationStatus {
        guard capabilities.push else { return notificationStatus }
        if let notificationPermissionOverride { return await notificationPermissionOverride() }
        let state = await PushPermission.requestIfNeeded()
        notificationStatus = map(state)
        if !isDemo, notificationStatus == .allowed { registerForAPNs(); Task { await registerPushAll() } }
        pushDiagnostics = PushDiagnostics.summary(isDemo: isDemo, permission: notificationStatus.rawValue, relay: pushCoordinator?.summary)
        return notificationStatus
    }

    /// Reads the OS permission and registers with APNs. Injected so a test can prove a realm without push never calls either.
    @ObservationIgnored var currentPermission: () async -> PushPermission.State = { await PushPermission.current() }
    @ObservationIgnored var registerForAPNs: () -> Void = { PushPermission.registerForAPNs() }

    func openNotificationSettings() { PushPermission.openSystemSettings() }

    func demoSendPush(workspaceID: String) {
        guard capabilities.demoControls, isLive(workspaceID) else { return }
        Task { await sendDemoNotification(workspaceID: workspaceID, delay: 1) }
    }

    /// Settings -> Demo controls: one tap, short delay so the tester can lock the phone or go home.
    func demoSendNotification() async {
        guard capabilities.demoControls else { return }
        guard let ws = live.first(where: { isLive($0.info.id) }) else {
            demoPushResult = "Pair a Demo workspace first."
            return
        }
        await sendDemoNotification(workspaceID: ws.info.id, delay: options.uiTesting ? 1 : Self.demoNotificationDelay)
    }

    static let demoNotificationDelay: TimeInterval = 8

    private func sendDemoNotification(workspaceID: String, delay: TimeInterval) async {
        guard let ws = live.first(where: { $0.info.id == workspaceID }), let runtime = demo else { return }
        demoPushResult = "Checking notification permission…"
        let status = await ensureNotificationPermission()
        guard status == .allowed else {
            demoPushResult = "Notifications are off for orch. Turn them on in iOS Settings, then try again."
            return
        }
        // The notification must belong to a real open question, or nothing could ever replace it.
        var target = ws.waiting.first?.id
        if target == nil {
            demoPushResult = "Asking a Demo question…"
            guard let asked = await runtime.askDemoQuestion(workspace: ws.workspaceID) else {
                demoPushResult = "The Demo question could not be created."; return
            }
            target = asked.hex
            Task { await ws.refresh() }      // the new question appears in the app; never awaited here
        }
        demoPushResult = "Sending…"
        let result = await runtime.simulatePush(workspace: ws.workspaceID, name: ws.info.name, generation: ws.generation,
                                                label: "Demo: a question is waiting", questionID: target, delay: delay)
        guard let result else { demoPushResult = "The Demo push could not be sealed."; return }
        if let failure = UNUserNotificationScheduler.lastError.current {
            demoPushResult = "iOS refused the notification: \(failure)"
        } else if delay >= 5 {
            demoPushResult = "Notification scheduled — lock the phone or go home. Local notification scheduled (\(result.outcome)) in \(Int(delay)) s."
        } else {
            demoPushResult = "Local notification scheduled (\(result.outcome))"
        }
    }

    // MARK: Relay push (P3-D40)

    /// The Live realm's push coordinator; nil in Demo (which only simulates push) and while the realm offers no push capability.
    @ObservationIgnored private(set) var pushCoordinator: PushRegistrationCoordinator?
    /// The APNs environment and token as this build has them. Seams for tests; production reads the provisioning profile and the token store.
    @ObservationIgnored var pushEnvironment: () -> PushEnvironment? = { APNsEnvironment.current }
    /// The stored token, only if it was issued for the environment this build resolves now (a token from another environment is not ours).
    @ObservationIgnored var pushToken: () -> String? = {
        guard let stored = APNsTokenStore().stored, stored.environment == APNsEnvironment.current else { return nil }
        return stored.token
    }
    /// Tests: replaces the realm transport for the detached unregister.
    @ObservationIgnored var pushUnregister: ((ID16) async -> PushRegistrationOutcome)?

    func pushCoordinatorForLive() -> PushRegistrationCoordinator? {
        guard isLive, capabilities.push, let runtime else { return nil }
        if let pushCoordinator { return pushCoordinator }
        let c = PushRegistrationCoordinator(.init(
            realm: runtime.realm.rawValue,
            enabled: { [weak self] in guard let self else { return false }; return self.capabilities.push && self.lifetime.isActive && !self.retired },
            environment: { [weak self] in self?.pushEnvironment() },
            token: { [weak self] in self?.pushToken() },
            permissionAllowed: { [weak self] in self?.notificationStatus == .allowed },
            sink: { [weak self] in self?.runtime?.makePushSink() },
            isActive: { [weak self, weak runtime] id in
                guard let self, let runtime, self.runtime === runtime else { return false }
                return self.canUse(id.hex)
            },
            unregisterDetached: { [weak self, weak runtime] id in
                if let f = self?.pushUnregister { return await f(id) }
                guard let runtime else { return .failed("runtime gone") }
                return await runtime.unregisterPushOutcome(workspace: id)
            }))
        pushCoordinator = c
        // iOS hands the token over at every launch that registers: refresh the relay registrations then (a changed token gets a new id).
        OrchAppDelegate.onTokenReceived = { [weak self] _ in Task { @MainActor in await self?.registerPushAll() } }
        return c
    }

    /// A Live workspace is ready (joined now or restored at launch): keep the notification extension's material current, follow the epoch,
    /// and register with the relay if the permission and token allow. Nothing here runs without the push capability.
    private func startPush(for ws: LiveWorkspace, joined j: JoinedWorkspace) {
        guard let c = pushCoordinatorForLive() else { return }
        let service: any PushRegistering = makePushService(j)
        ws.push = service
        c.workspaceStarted(j.workspace)
        let observer: @Sendable (UInt32) -> Void = { [weak self, weak ws] _ in
            Task { @MainActor in
                guard let self, let ws, let c = self.pushCoordinator, let s = ws.push, self.canUse(ws.info.id) else { return }
                await c.publishMaterial(s, name: ws.info.name, generation: ws.generation)
            }
        }
        Task { [weak self, weak ws] in
            await j.session.setEpochObserver(observer)
            guard let self, let ws else { return }
            await c.publishMaterial(service, name: ws.info.name, generation: ws.generation)
            await self.refreshNotificationStatus()         // reads the permission; allowed -> asks iOS for the token (never prompts)
            // Owed cleanups first: a removal still owed for an earlier membership must reach the relay before this device registers anew.
            await self.retryServerCleanup(within: self.registrationCleanupBound)
            await c.register(service)
        }
    }

    @ObservationIgnored var makePushService: (JoinedWorkspace) -> any PushRegistering = { $0.makePushService() }

    /// Every Live workspace, in turn: at launch with a token, and when iOS hands over a new one.
    func registerPushAll() async {
        guard let c = pushCoordinator, isLive else { return }
        await c.registerAll(live.filter { isLive($0.info.id) }.compactMap(\.push))
    }

    // MARK: Pending server cleanup (U9)

    private func enqueueServerCleanup(ws: String, generation: Int64) {
        pendingServerCleanups = cleanupStore?.add(PendingServerCleanup(ws: ws, generation: generation, since: Date())) ?? []
    }

    /// An owed push cleanup older than this is dropped: the relay deletes an unrefreshed registration after 60 days anyway.
    static let owedCleanupLifetime: TimeInterval = 60 * 86_400
    @ObservationIgnored private var cleanupRun: Task<Void, Never>?

    /// Back online (a start, a foreground, "Retry now"): tries each pending server-side cleanup once, one run at a time. Successes leave the
    /// list; failures stay for the next try. An item whose workspace is joined again (a re-pair is a new membership) is dropped without
    /// being sent, so an old cleanup can never remove a fresh registration; one older than `owedCleanupLifetime` is dropped too.
    ///
    /// `within` bounds how long THIS caller waits (an unreachable relay must not hold a registration for the transport timeout); the run itself
    /// is not cancelled and finishes in the background, and a later call joins it.
    func retryServerCleanup() async { await retryServerCleanup(within: nil) }

    func retryServerCleanup(within seconds: Double?) async {
        if let running = cleanupRun { await waitBounded(running, seconds); return }
        guard let cleanupStore else { return }
        let run = Task { @MainActor [self] in
            defer { cleanupRun = nil }
            for item in cleanupStore.load() {
                if live.contains(where: { $0.workspaceID.hex == item.ws }) || Date().timeIntervalSince(item.since) > Self.owedCleanupLifetime {
                    _ = cleanupStore.remove(ws: item.ws, generation: item.generation); continue
                }
                do { try await serverCleanup(item); _ = cleanupStore.remove(ws: item.ws, generation: item.generation) }
                catch { continue }
            }
            pendingServerCleanups = cleanupStore.load()
        }
        cleanupRun = run
        await waitBounded(run, seconds)
    }

    private func waitBounded(_ run: Task<Void, Never>, _ seconds: Double?) async {
        guard let seconds else { await run.value; return }
        _ = await racing(seconds: seconds) { await run.value }
    }

    /// How long a registration waits for owed cleanups before it goes ahead (they continue in the background).
    @ObservationIgnored var registrationCleanupBound: Double = 3

    /// Leave = "Remove from this iPhone": the real local wipe first and network-independent; server cleanup is reported separately (U9).
    func leave(workspaceID: String, simulateOffline: Bool) async -> LeaveReport {
        guard let ws = live.first(where: { $0.info.id == workspaceID }) else {
            return LeaveReport(workspaceName: "Workspace", server: .finishOnMac, incomplete: true)
        }
        guard let runtime, state(for: workspaceID) != .removing else {
            return LeaveReport(workspaceName: ws.info.name, server: .pendingOffline, incomplete: true)
        }
        transition(workspaceID, to: .removing)
        await ws.drop?.service.invalidate()
        let name = ws.info.name
        // The share outbox journals the removal first; a failed journal keeps the workspace in place.
        // A failed share-outbox journal must not block the local wipe (U9: Leave never depends on anything but this phone). The wipe's
        // own phase 1 publishes the tombstone to both App Groups first and fails the whole wipe if it cannot, so nothing is
        // reported removed without a durable tombstone.
        var journaled = beforeWorkspaceRemoval?(workspaceID) != false
        let canDeregister = ws.info.scopes.contains(.operate)
        await waitForLifecycle()
        await ws.stop()
        // Relay push, best effort and bounded. The wipe's tombstone is written FIRST (the intent is durable: a kill in the window below is
        // finished at relaunch), then the registration is removed through the realm transport and device key (the workspace session is
        // stopped and its store carries the tombstone). If the relay cannot be reached the cleanup is recorded as owed (below); it never
        // blocks or changes the local wipe beyond the bound.
        var pushOwed = false
        if let c = pushCoordinator, ws.push != nil {
            // The owed cleanup is durable BEFORE the window (a kill between the tombstone and the end of the wipe must not lose it) and is
            // removed only when the relay answered done.
            enqueueServerCleanup(ws: ws.workspaceID.hex, generation: ws.generation)
            do {
                try await beginWorkspaceWipe(runtime, ws)
                pushOwed = await c.unregister(workspace: ws.workspaceID) == .owed
            } catch { pushOwed = true }       // the wipe below writes the tombstone itself; the cleanup stays owed
            if !pushOwed { pendingServerCleanups = cleanupStore?.remove(ws: ws.workspaceID.hex, generation: ws.generation) ?? [] }
        }
        let prefix = ws.workspaceID.hex + "/"
        for (key, task) in reconcileTasks where key.hasPrefix(prefix) { task.cancel(); reconcileTasks[key] = nil; reconcileSerials[key] = nil }
        do { try await wipeWorkspace(runtime, ws) }
        catch {
            // Never report success on a failed wipe: the workspace stays listed, stopped and marked "removal incomplete"; Leave again
            // resumes the persisted wipe (LocalWipe.resumePendingWipes). A half-wiped workspace is not restarted.
            transition(workspaceID, to: .removalIncomplete)
            return LeaveReport(workspaceName: name, server: .pendingOffline, incomplete: true, failure: "\(error)")
        }
        PresentationGate.block(ws.workspaceID.hex)
        // The wipe is durable; retry the share-outbox journal now and say so if it is still unfinished (publishTargets keeps retrying).
        if !journaled { journaled = beforeWorkspaceRemoval?(workspaceID) != false }
        if !journaled { shareStatus = "Share cleanup for a removed workspace is unfinished. It will be retried." }
        transition(workspaceID, to: .removed)
        live.removeAll { $0.info.id == workspaceID }
        heldDropItems.removeAll { $0.workspaceID == workspaceID }
        pendingDecisions.removeAll { $0.workspaceID == workspaceID }
        // Only Demo can acknowledge a server-side removal; Live has no implemented, acknowledged operation yet, so it never claims one.
        let server: LeaveServerStatus = (!canDeregister || runtime.realm == .live) ? .finishOnMac : (simulateOffline ? .pendingOffline : .done)
        if server == .pendingOffline || pushOwed { enqueueServerCleanup(ws: ws.workspaceID.hex, generation: ws.generation) }
        return LeaveReport(workspaceName: name, server: server)
    }

    /// Wipes the Demo realm through the real reset path and leaves Demo.
    func resetThisiPhone() { leaveRealm(thenDemo: false) }
    func exitDemo() { leaveRealm(thenDemo: false) }
    /// "Reset Demo data" is leave-then-Demo: only a `RealmController` can do the second half, so without one it is a no-op.
    func resetDemoData() { leaveRealm(thenDemo: true) }

    private func leaveRealm(thenDemo: Bool) {
        guard !retired else { return }
        if let transitions { transitions.realmLeave(thenDemo: thenDemo); return }
        // Without a controller (unit tests): the same two halves.
        guard !thenDemo else { return }
        if beginLeave() { Task { await drainPushRegistrations(); teardown() } } else { teardown() }
    }

    /// True while Leave Live / Reset is removing the relay registrations (the realm is already marked for removal and cut off from the UI).
    @ObservationIgnored private(set) var leavingRealm = false
    @ObservationIgnored private var drainTargets: [(ws: ID16, workspace: LiveWorkspace)] = []

    /// First half of Leave Live / Reset, synchronous: the intent is made durable BEFORE anything is awaited (the Live reset gate is persisted,
    /// so a kill from here on is finished at relaunch, which skips the relay and completes the wipe), the push coordinator refuses every
    /// further register and publish, and every workspace stops being usable (`removing`, never presented). Returns true when the relay
    /// registrations still have to be removed (`drainPushRegistrations`) before `teardown`; false means `teardown` can run now.
    func beginLeave() -> Bool {
        guard !leavingRealm, !retired, isLive, capabilities.push, lifetime.isActive, let c = pushCoordinator, !live.isEmpty else { return false }
        leavingRealm = true
        c.beginClosing()
        resetFlags.set(true, forKey: Keys.liveResetPending)
        drainTargets = live.map { ($0.workspaceID, $0) }
        // Nothing reconciles in the background any more: the realm is cut off from the UI, and now from its own tasks too.
        reconcileTasks.values.forEach { $0.cancel() }; reconcileTasks = [:]; reconcileSerials = [:]
        for ws in live { transition(ws.info.id, to: .removing) }
        PresentationGate.blockAll(live.map { $0.workspaceID.hex })
        return true
    }

    /// Second half, bounded (a few seconds): sessions stop, then every registration of this device is removed through the realm transport
    /// and device key, all workspaces at once. If the relay cannot be reached nothing can be owed afterwards (the device key goes with the
    /// wipe): the registration ends by the host's removal of the device, an APNs 410, revocation, or 60 days without a refresh.
    ///
    /// One deadline (`drainBound`) covers the whole drain: stopping every session, every in-flight registration and every unregister. When it
    /// passes the drain returns (the teardown that follows stops what is left); nothing here can hold the wipe past it.
    func drainPushRegistrations() async {
        defer { leavingRealm = false }
        guard let c = pushCoordinator else { return }
        let targets = drainTargets
        drainTargets = []
        let bound = drainBound
        let started = Date()
        #if DEBUG
        let beforeStop = drainBeforeStop
        #endif
        _ = await racing(seconds: bound) {
            #if DEBUG
            await beforeStop?()
            #endif
            // Sessions first: from here no workspace write or send can race the unregister.
            for t in targets { await t.workspace.drop?.service.invalidate(); await t.workspace.stop() }
            let left = max(bound - Date().timeIntervalSince(started), 0.05)
            let running = targets.map { t in Task { @MainActor in _ = await c.unregister(workspace: t.ws, seconds: left) } }
            for r in running { await r.value }
        }
    }

    /// The one bound of the realm drain, in seconds.
    @ObservationIgnored var drainBound: Double = 3
    #if DEBUG
    @ObservationIgnored var drainBeforeStop: (@Sendable () async -> Void)?
    var reconcileTaskCount: Int { reconcileTasks.count }
    #endif

    /// True once a transition replaced this graph: a stray call into it must not touch the active realm's storage.
    @ObservationIgnored private(set) var retired = false

    /// Ends this realm's lifetime without wiping anything: every late completion that still holds this instance becomes inert.
    /// Used when a transition replaces the whole service graph.
    ///
    /// L1: a retired graph leaves nothing running. The realm is invalidated (synchronously: no send, signature or commit from now on),
    /// and its sessions, pairing coordinators and workspace consumers are then cancelled and awaited (bounded) in `retireDrain`. A
    /// retire does not wipe: use `teardown` for that.
    func retire() {
        retired = true
        let runtime = self.runtime
        runtime?.invalidate()          // idempotent: a retired graph's realm is over
        lifetime.invalidate()
        reconcileTasks.values.forEach { $0.cancel() }; reconcileTasks = [:]; reconcileSerials = [:]
        refreshTasks.values.forEach { $0.cancel() }; refreshTasks = [:]
        demoLockRelease?.cancel()
        let workspaces = live
        let pendingBoot = bootTask
        bootTask = nil
        guard runtime != nil || !workspaces.isEmpty else { return }
        let previous = retireDrain
        retireDrain = Task {
            await previous?.value
            _ = await pendingBoot?.value
            await runtime?.drain()
            for ws in workspaces { await ws.drop?.service.invalidate(); await ws.stop(); await ws.downloadContainer?.close() }
        }
    }

    /// Completes when a retired graph's sessions and consumers have stopped (tests, and nothing else, wait on it).
    func waitForRetire() async { await retireDrain?.value }
    @ObservationIgnored private var retireDrain: Task<Void, Never>?

    /// The in-place realm exit (also what `RealmController` drives). The lifetime is invalidated first, before any await.
    func teardown() {
        guard !retired else { return }
        runtime?.invalidate()          // before any await: the realm's generation fences OrchClient itself (signing, send, commits)
        lifetime.invalidate()
        resetRevision += 1
        let pendingBoot = bootTask
        bootTask = nil
        let old = runtime
        if let old { failedReset = old }
        // The realm being wiped: the attached one, or the one whose earlier wipe failed. A graph with no realm (Welcome, a boot that never
        // produced a runtime) resets Demo as before, and Live too when a Live install is on record.
        let target = old ?? failedReset
        if let target {
            resetFlagKeys.insert(target.realm == .live ? Keys.liveResetPending : Keys.resetPending)
        } else {
            resetFlagKeys.insert(Keys.resetPending)
            if installStore.exists { resetFlagKeys.insert(Keys.liveResetPending) }
        }
        for ws in live { transition(ws.info.id, to: .removing) }
        let workspaces = live
        PresentationGate.blockAll(workspaces.map { $0.workspaceID.hex })
        runtime = nil; live = []; heldDropItems = []; pendingDecisions = []; submitted = [:]
        reconcileTasks.values.forEach { $0.cancel() }
        reconcileTasks = [:]; reconcileSerials = [:]
        refreshTasks.values.forEach { $0.cancel() }; refreshTasks = [:]
        demoLockRelease?.cancel()
        for key in resetFlagKeys { resetFlags.set(true, forKey: key) }
        // L4: pending server cleanups are NOT cleared here. They are cleared only after the wipe succeeded: a failed wipe keeps them
        // (and the realm's data) for the retry, and a relaunch completes the wipe and then clears them.
        if let cleanupStore { cleanupToClear.append(cleanupStore) }
        cleanupStore = nil
        deviceLabel = "iPhone"
        liveBootError = nil
        if !options.uiTesting { UserDefaults.standard.set(false, forKey: Keys.demo) }
        let previous = resetTask
        resetTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if let booted = await pendingBoot?.value { self.failedReset = booted }
            await self.waitForLifecycle()
            for ws in workspaces { await ws.drop?.service.invalidate(); await ws.stop() }
            do {
                if let pending = self.failedReset { try await self.resetRuntime(pending) }
                else {
                    if self.resetFlagKeys.contains(Keys.resetPending), !self.options.uiTesting { try await self.finishInterruptedReset() }
                    if self.resetFlagKeys.contains(Keys.liveResetPending) { try await self.finishLiveReset() }
                }
                self.failedReset = nil
                for id in self.lifecycle.keys { self.transition(id, to: .removed) }
                // The wipe succeeded: only now do the realm's records and cleanups go.
                if self.resetFlagKeys.contains(Keys.liveResetPending) { self.clearLiveRealmRecords() }
                for store in self.cleanupToClear { store.clear() }
                self.cleanupToClear = []
                self.pendingServerCleanups = []
                for key in self.resetFlagKeys { self.resetFlags.set(false, forKey: key) }
                self.resetFlagKeys = []
                self.resetIncomplete = false
            } catch {
                self.resetIncomplete = true
                for id in self.lifecycle.keys { self.transition(id, to: .removalIncomplete) }
            }
        }
    }

}

/// The realm transitions a `RealmController` performs on behalf of the services' own Welcome/Settings actions.
@MainActor
protocol RealmTransitions: AnyObject {
    func realmEnterDemo()
    func realmLeave(thenDemo: Bool)
    /// A Live entry attached its runtime to the current (Welcome) graph.
    func realmEnteredLive()
    /// The stuck-wipe escape for Live (see `LiveServices.forceEraseLive`).
    func realmForceEraseLive()
}

/// A review for a workspace that is no longer on this iPhone: it can load nothing.
@MainActor @Observable
final class UnavailableReviewModel: QuestionReviewModel {
    private(set) var load: ReviewLoad = .failed("This workspace is no longer on this iPhone.")
    private(set) var review: ReviewValue?
    private(set) var phase: SignPhase = .invalidated
    func loadReview() async {}
    func sign() async {}
    func reread() async {}
    func checkWhetherReceived() async {}
    func sendAgain() async {}
    func invalidate() {}
    func retryAfterUnlock() {}
}

#if DEBUG
extension LiveServices {
    func demoDropPending() async {
        guard options.uiTesting, let runtime = demo, let drop = live.first(where: { $0.info.scopes.contains(.operate) })?.drop,
              let id = drop.workspace?.info.id else { return }
        for _ in 0..<100 where live.contains(where: { !($0.drop?.verifying.isEmpty ?? true) || $0.drop?.loading == true }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard drop.canOperate else { return }
        runtime.faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "GET " + HostAPI.base + "/drop/")
        await drop.send(.init(workspaceID: id, attachments: [], note: "Foreground recovery bytes"))
    }
    func demoDropReject() async {
        guard options.uiTesting, let runtime = demo else { return }
        do { try await runtime.env.relay.demoRejectNextDrop() } catch { shareStatus = "Could not arm Demo fault" }
    }
    func demoDropInbox() async {
        guard options.uiTesting, let runtime = demo, let ws = live.first(where: { $0.info.scopes.contains(.operate) }),
              let entry = runtime.entry(for: ws.workspaceID) else { return }
        do {
            try await entry.host.demoInboxDrop(relay: runtime.env.relay, transport: runtime.env.transport, session: entry.session)
            await ws.drop?.refresh()
        } catch { ws.drop?.report(error) }
    }
    func demoDropExpire() {
        guard options.uiTesting else { return }
        setActive(false)
        demo?.fastForward(seconds: 604801)
        setActive(true)
    }
}
#endif
