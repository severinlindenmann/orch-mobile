import XCTest
import OrchClient
import OrchCoordination
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchShareStaging
import OrchStore
@testable import Orch

/// A relay that is never reachable: restored sessions exist and stay offline, which is all these tests need.
private struct DownSender: RequestSender {
    let origin: String
    func send(_ request: WireRequest) async throws -> WireReply { throw TransportError.disconnected }
}

private actor BootGate {
    let name: String
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ name: String) { self.name = name }
    func hit(_ step: String) async {
        guard step == name else { return }
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func waitEntered() async { while !entered { try? await Task.sleep(for: .milliseconds(5)) } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor DraftStub: WorkspaceAPI {
    var submissions = 0
    var verifiedReceiptMs: Int64? { nil }
    func start() {}
    func setForeground(_ value: Bool) {}
    func refreshViews() async {}
    func invalidateReviews() {}
    func reconcile(decisionID: ID16) throws -> DecisionOutcome { throw ViewError.offline }
    func retry(decisionID: ID16) throws -> DecisionOutcome { throw ViewError.offline }
    func snapshot() throws -> WorkspaceSnapshot { throw ViewError.offline }
    func review(questionID: ID16) throws -> QuestionReview { throw ViewError.offline }
    func decide(_ review: QuestionReview, optionID: String) throws -> DecisionOutcome { throw ViewError.offline }
    func pendingDecisions() -> [OrchClient.DecisionStatus] { [] }
    func newTicket(_ draft: NewTicketSubmission) throws -> OrchClient.Ticket { submissions += 1; throw ViewError.offline }
    func events() async -> AsyncStream<WorkspaceEvent> { AsyncStream { $0.finish() } }
}

@MainActor
final class LiveRuntimeTests: XCTestCase {
    private let options = LaunchOptions.parse(arguments: ["--ui-testing"], debug: true)
    private let origin = "https://relay.example.org"

    override func setUp() { PresentationGate.defaults = UserDefaults(suiteName: "orch.tests.gate.\(UUID().uuidString)")!; PresentationGate.markRebuilt() }
    override func tearDown() { PresentationGate.defaults = .standard; PresentationGate.markRebuilt() }

    // MARK: Fixtures

    /// A Live install on a temporary disk and an in-memory keychain, with a relay that is down.
    private struct Rig {
        let storage: LiveStorage
        let flags: UserDefaults
        let suite: String
        var keys: SecretVault { storage.keysVault() }
        var push: SecretVault { storage.pushVault() }
        var install: LiveInstallStore { LiveInstallStore(defaults: flags) }
        func cleanup() { flags.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: storage.layout.appRoot.deletingLastPathComponent()) }
    }

    private func makeRig(installed: Bool = true) throws -> Rig {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("orch-liveruntime-" + UUID().uuidString)
        let layout = try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                                     shareGroupRoot: base.appendingPathComponent("share"), realm: "live")
        let storage = LiveStorage(layout: layout, backend: InMemoryVaultBackend(), lock: SimulatedLock(), clock: ContinuousClock(),
                                  wall: SystemWallClock(), entropy: SystemEntropy(),
                                  makeTransport: { try LiveTransport.testingTransport(context: $0, sender: DownSender(origin: $0.origin)) },
                                  purgeNotifications: { _ in })
        let suite = "orch.liveruntime.\(UUID().uuidString)"
        let rig = Rig(storage: storage, flags: UserDefaults(suiteName: suite)!, suite: suite)
        if installed { rig.install.save(LiveInstall(origin: origin, owner: nil)) }
        return rig
    }

    private func makeServices(_ rig: Rig) -> LiveServices {
        let services = LiveServices(options: options, resetFlags: rig.flags)
        services.liveStorage = { rig.storage }
        return services
    }

    private struct Joined { let profile: WorkspaceProfile; let generation: Int64 }
    /// A committed join built directly (no Demo pairing run): a Demo host's real signed card, its pins and the owner's key, as the profile a
    /// verified join commits. Deterministic and fast.
    private func demoJoin() async throws -> Joined {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("orch-fixture-" + UUID().uuidString)
        let layout = try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                                     shareGroupRoot: base.appendingPathComponent("share"), realm: "demo")
        defer { try? FileManager.default.removeItem(at: base) }
        let clock = TestClock(wallStartMs: SystemWallClock().nowMs)
        let custody = DefaultCustody.make(vault: SecretVault(group: .keys, backend: InMemoryVaultBackend()))
        let env = try await DemoSetup.setup(layout: layout, custody: custody, clock: clock, wall: clock)
        let primary = DemoSetup.makeAuthority(env)
        let host = try DemoSetup.makeHost(env, primary: primary, name: "Laptop")
        let card = try await host.card()
        let profile = WorkspaceProfile(
            ws: host.workspace.hex, name: "Laptop", description: "Demo workspace", origin: origin, clientHosted: false, hostedMarker: false,
            hostedBy: nil, wskPub: B64U.encode(host.wskPublic.x963), pkPub: B64U.encode(primary.publicKey.x963),
            ownerPerson: Identifiers.personID(primary.publicKey).hex, cardSeq: 1, listSeq: 1, epoch: 1, scopes: ["look", "decide", "operate", "type"],
            card: String(decoding: try canonicalJSON(card), as: UTF8.self), joinedMs: SystemWallClock().nowMs)
        env.context.invalidate()
        return Joined(profile: profile, generation: 1)
    }

    /// Commits `joined` into the rig's Live realm exactly as a Live join leaves it: index row and profile, and the device keys.
    private func commit(_ joined: Joined, into rig: Rig) async throws {
        _ = try rig.storage.makeCustody().create(realm: .live)
        let index = try await WorkspaceIndex(layout: rig.storage.layout)
        var profile = joined.profile
        profile.origin = origin
        try await index.savePairing(PairingRow(ws: profile.ws, offer: String(repeating: "0", count: 32), generation: joined.generation,
                                               origin: origin, phase: "joining", startedMs: 0, updatedMs: 0))
        try await index.commitJoin(generation: joined.generation, profile: profile)
        await index.close()
    }

    private func liveVaultItems(_ rig: Rig) throws -> Int {
        try (rig.keys.ids() + rig.push.ids()).filter { $0.realm == .live }.count
    }

    // MARK: Boot and restore

    func testLiveBootRestoresAJoinedWorkspaceOnTheSingleContextAndDoesNotWipe() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(joined, into: rig)
        let services = makeServices(rig)
        await services.boot()
        let runtime = try XCTUnwrap(services.runtime as? LiveRuntime)
        XCTAssertTrue(services.isLive && !services.isDemo)
        XCTAssertNil(services.liveBootError)
        XCTAssertEqual(services.live.count, 1)
        let ws = try XCTUnwrap(services.live.first)
        XCTAssertEqual(ws.info.id, joined.profile.ws)
        XCTAssertEqual(ws.generation, joined.generation)
        XCTAssertEqual(ws.info.name, joined.profile.name)
        XCTAssertEqual(ws.info.scopes, Mapping.scopes(joined.profile.scopes))
        XCTAssertTrue(runtime.context.isCurrent && runtime.skipped.isEmpty)
        // The realm and its capabilities are the runtime's: nothing optional is on.
        XCTAssertEqual(services.realm, .live)
        XCTAssertEqual(services.capabilities, RealmCapabilities(drop: false, share: false, push: false, demoControls: false))
        XCTAssertNil(ws.drop)
        XCTAssertFalse(services.eligibleShareDestination(ws.info.id))
        XCTAssertNil(services.demo)
        // Another launch restores the same workspace again: a Live boot never wipes.
        services.retire(); await services.waitForRetire()
        XCTAssertFalse(runtime.context.isCurrent)
        let second = makeServices(rig)
        await second.boot()
        XCTAssertEqual(second.live.map(\.info.id), [joined.profile.ws])
        second.resetThisiPhone(); await second.waitForReset()
    }

    func testRetireOfAGraphWithLiveSessionsStopsThemAndWipesNothing() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(joined, into: rig)
        let services = makeServices(rig)
        await services.boot()
        let runtime = try XCTUnwrap(services.runtime as? LiveRuntime)
        let ws = try XCTUnwrap(services.live.first)
        services.retire()
        XCTAssertFalse(runtime.context.isCurrent)                    // synchronous
        await services.waitForRetire()                               // sessions and consumers stopped
        XCTAssertNil(ws.eventTask)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.storage.layout.indexURL.path))
        XCTAssertGreaterThan(try liveVaultItems(rig), 0)             // retire is not a wipe
        let again = makeServices(rig)
        await again.boot()
        again.resetThisiPhone(); await again.waitForReset()
    }

    func testMissingKeychainFailsClosedWithoutAnyFallbackAndKeepsLiveData() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let services = LiveServices(options: options, resetFlags: rig.flags)
        services.liveStorage = { throw LiveError.keychainUnavailable }
        await services.boot()
        XCTAssertNil(services.runtime)
        XCTAssertFalse(services.isLive)
        XCTAssertNotNil(services.liveBootError)
        XCTAssertTrue(rig.install.exists)                              // the install record is not touched by a failed start
        XCTAssertFalse(services.wantsDemo)
    }

    func testForegroundRetriesALiveStartThatCouldNotEvenBuildItsRuntime() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(joined, into: rig)
        let services = LiveServices(options: options, resetFlags: rig.flags)
        var available = false
        services.liveStorage = { if available { return rig.storage }; throw LiveError.keychainUnavailable }
        await services.boot()
        XCTAssertNil(services.runtime)
        XCTAssertNotNil(services.liveBootError)
        available = true
        services.setActive(true)
        for _ in 0..<2000 where services.live.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(services.isLive)
        XCTAssertNil(services.liveBootError)
        XCTAssertEqual(services.live.count, 1)
        services.resetThisiPhone(); await services.waitForReset()
    }

    func testRuntimeRefusesAForeignTransportAndABadInstall() throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        var other = rig.storage
        other.makeTransport = { _ in
            let foreign = try RealmContext.live(origin: "https://relay.example.org")
            return try LiveTransport.testingTransport(context: foreign, sender: DownSender(origin: foreign.origin))
        }
        XCTAssertThrowsError(try LiveRuntime(install: LiveInstall(origin: origin, owner: nil), storage: other))
        XCTAssertThrowsError(try LiveRuntime(install: LiveInstall(origin: "https://relay.demo.invalid", owner: nil), storage: rig.storage))
        XCTAssertThrowsError(try LiveRuntime(install: LiveInstall(origin: "http://relay.example.org", owner: nil), storage: rig.storage))
        XCTAssertThrowsError(try LiveRuntime(install: LiveInstall(origin: origin, owner: "not-a-key"), storage: rig.storage))
    }

    // MARK: Teardown during a boot (M3)

    func testTeardownDuringABootInvalidatesItAndTheLeaveWipesTheRealm() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(joined, into: rig)
        let gate = BootGate("recover")
        let services = makeServices(rig)
        services.liveBootGate = { await gate.hit($0) }
        let boot = Task { await services.boot() }
        await gate.waitEntered()
        let runtime = try XCTUnwrap(services.runtime as? LiveRuntime)       // reachable before the boot finished
        XCTAssertTrue(runtime.context.isCurrent)
        services.teardown()
        XCTAssertFalse(runtime.context.isCurrent)                             // the boot in progress was invalidated synchronously
        XCTAssertTrue(rig.flags.bool(forKey: "orch.live.resetPending"))
        await gate.release()
        await boot.value
        await services.waitForReset()
        XCTAssertFalse(services.resetIncomplete)
        XCTAssertTrue(services.live.isEmpty)                                  // the interrupted boot adopted nothing
        XCTAssertNil(services.runtime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.storage.layout.realmDir.path))
        XCTAssertEqual(try liveVaultItems(rig), 0)
        XCTAssertEqual(rig.storage.makeCustody().status(realm: .live), .missing)
        XCTAssertFalse(rig.install.exists)
        XCTAssertFalse(rig.flags.bool(forKey: "orch.live.resetPending"))
    }

    // MARK: Leave Live

    func testLeaveWipesTheWholeRealmIncludingStagedItemsNoIndexRowNames() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(joined, into: rig)
        let services = makeServices(rig)
        await services.boot()
        XCTAssertEqual(services.live.count, 1)
        // What an invalidated join leaves behind AFTER the boot (boot recovery would sweep strays of an earlier launch):
        let staged = ID16.random().hex
        try rig.keys.put(Data("pairing".utf8), for: SecretID(realm: .live, ws: staged, purpose: "pairing"))
        try rig.push.put(Data("push".utf8), for: SecretID(realm: .live, ws: staged, purpose: "push"))
        let demoItem = try SecretID(realm: .demo, ws: staged, purpose: "other-realm")
        try rig.keys.put(Data("demo".utf8), for: demoItem)
        let layout = rig.storage.layout
        let stateDir = try layout.pushStateDir(staged), stagedDir = try layout.stagedJobsDir(staged), quarantine = try layout.quarantineDir(staged)
        for dir in [stateDir, stagedDir, quarantine] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        // Before the reset the staged items exist.
        XCTAssertTrue(try rig.keys.contains(SecretID(realm: .live, ws: staged, purpose: "pairing")))
        XCTAssertTrue(try rig.push.contains(SecretID(realm: .live, ws: staged, purpose: "push")))
        for dir in [stateDir, stagedDir, quarantine] { XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), dir.path) }
        services.resetThisiPhone()                                            // Leave Live
        XCTAssertFalse(services.lifetime.isActive)
        await services.waitForReset()
        XCTAssertFalse(services.resetIncomplete)
        XCTAssertEqual(try liveVaultItems(rig), 0)
        XCTAssertTrue(try rig.keys.contains(demoItem))                        // another realm is never addressed
        for dir in [layout.realmDir, stateDir, stagedDir, quarantine] { XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), dir.path) }
        XCTAssertEqual(rig.storage.makeCustody().status(realm: .live), .missing)
        XCTAssertFalse(rig.install.exists)
        XCTAssertFalse(rig.flags.bool(forKey: "orch.live.resetPending"))
        XCTAssertEqual(services.capabilities, .none)
    }

    func testALaunchWithTheGateSetCompletesTheWipeBeforeLiveStarts() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(joined, into: rig)
        rig.flags.set(true, forKey: "orch.live.resetPending")                 // the persisted gate an interrupted Leave leaves
        XCTAssertGreaterThan(try liveVaultItems(rig), 0)                       // there is Live data for the wipe to find
        let services = makeServices(rig)
        await services.boot()
        XCTAssertNil(services.runtime)                                         // no Live successor started
        XCTAssertTrue(services.live.isEmpty)
        XCTAssertFalse(services.resetIncomplete)
        XCTAssertFalse(rig.flags.bool(forKey: "orch.live.resetPending"))
        XCTAssertFalse(rig.install.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.storage.layout.realmDir.path))
        XCTAssertEqual(try liveVaultItems(rig), 0)
    }

    func testAWipeThatFailsAtLaunchBlocksLiveAndKeepsEverythingForTheRetry() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(joined, into: rig)
        rig.flags.set(true, forKey: "orch.live.resetPending")
        let services = makeServices(rig)
        var attempts = 0
        services.finishInterruptedLiveReset = { storage in
            attempts += 1
            if attempts == 1 { throw ViewError.offline }
            try await LiveRuntime.finishInterruptedReset(storage: storage)
        }
        await services.boot()
        XCTAssertTrue(services.resetIncomplete)
        XCTAssertNil(services.runtime)                                         // Live did not start next to unwiped data
        XCTAssertTrue(rig.flags.bool(forKey: "orch.live.resetPending"))
        XCTAssertTrue(rig.install.exists)
        XCTAssertTrue(services.live.isEmpty)
        services.resetThisiPhone(); await services.waitForReset()             // Retry
        XCTAssertFalse(services.resetIncomplete)
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(rig.flags.bool(forKey: "orch.live.resetPending"))
        XCTAssertFalse(rig.install.exists)
    }

    func testPendingServerCleanupsAreClearedOnlyAfterTheWipeSucceeded() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let runtime = try LiveRuntime(install: LiveInstall(origin: origin, owner: nil), storage: rig.storage)
        let store = ServerCleanupStore(defaults: rig.flags, realm: .live)
        store.add(PendingServerCleanup(ws: String(repeating: "a", count: 32), generation: 1, since: Date()))
        let services = LiveServices(options: options, runtime: runtime, resetFlags: rig.flags)
        XCTAssertEqual(services.pendingServerCleanups.count, 1)
        var attempts = 0
        services.resetRuntime = { retained in
            attempts += 1
            XCTAssertEqual(store.load().count, 1, "still pending while the wipe has not succeeded")
            if attempts == 1 { throw ViewError.offline }
            try await retained.shutdown()
        }
        services.resetThisiPhone(); await services.waitForReset()
        XCTAssertTrue(services.resetIncomplete)
        XCTAssertEqual(store.load().count, 1)                                  // a failed wipe keeps them
        XCTAssertTrue(rig.flags.bool(forKey: "orch.live.resetPending"))
        services.resetThisiPhone(); await services.waitForReset()
        XCTAssertFalse(services.resetIncomplete)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(services.pendingServerCleanups.isEmpty)
    }

    // MARK: Controller

    func testRetryAfterAFailedResetGoesWhereTheFailedOneWasGoing() async throws {
        let controller = RealmController(options: options)
        var attempts = 0
        let base = controller.makeServices
        controller.makeServices = { options, defaults in
            let services = base(options, defaults)
            services.resetRuntime = { runtime in
                attempts += 1
                if attempts == 1 { throw ViewError.offline }
                try await runtime.shutdown()
            }
            return services
        }
        await controller.boot()
        controller.realmEnterDemo(); await controller.waitForTransition()
        controller.realmLeave(thenDemo: true)                                   // "Reset Demo data"
        await controller.waitForTransition()
        XCTAssertEqual(controller.state, .recoveryRequired)
        controller.realmLeave(thenDemo: false)                                  // the screen's "Try again"
        await controller.waitForTransition()
        XCTAssertEqual(controller.state, .demo)                                 // N1: Demo, not Welcome
        XCTAssertEqual(attempts, 2)
        controller.realmLeave(thenDemo: false); await controller.waitForTransition()
        XCTAssertEqual(controller.state, .welcome)                              // a fresh leave is not affected
    }

    func testControllerRestoresLiveOnRelaunchAndLeavingLiveReturnsToWelcome() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(joined, into: rig)
        let controller = RealmController(options: options, resetFlags: rig.flags)
        controller.services.liveStorage = { rig.storage }
        let base = controller.makeServices
        controller.makeServices = { options, defaults in
            let services = base(options, defaults)
            services.liveStorage = { rig.storage }
            return services
        }
        await controller.boot()
        XCTAssertEqual(controller.state, .live)
        XCTAssertTrue(controller.services.isLive)
        XCTAssertEqual(controller.services.live.count, 1)
        controller.realmEnterDemo()                                             // never silently next to Live
        XCTAssertEqual(controller.state, .live)
        controller.realmLeave(thenDemo: false)
        await controller.waitForTransition()
        XCTAssertEqual(controller.state, .welcome)
        XCTAssertFalse(controller.services.isLive)
        XCTAssertFalse(rig.install.exists)
        XCTAssertEqual(try liveVaultItems(rig), 0)
    }

    func testANoRealmBootRetiresDemoDestinationsButKeepsLiveOnes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let area = ShareArea(shareGroupRoot: root)
        let live = ShareTarget(realm: "live", ws: String(repeating: "a", count: 32), name: "Mac", hue: 0, generation: 1)
        let demo = ShareTarget(realm: "demo", ws: String(repeating: "b", count: 32), name: "Laptop", hue: 0, generation: 1)
        try ShareTargetIndex.publish([live, demo], to: area)
        let controller = RealmController(options: options)
        controller.shareArea = area
        await controller.boot()                                                 // no realm: Welcome
        XCTAssertEqual(controller.state, .welcome)
        XCTAssertEqual(try ShareTargetIndex.persisted(from: area), [live])
        // A Live that failed to start is a no-realm boot too: its destinations stay.
        let rig = try makeRig(); defer { rig.cleanup() }
        let failing = RealmController(options: options, resetFlags: rig.flags)
        failing.shareArea = area
        failing.services.liveStorage = { throw LiveError.keychainUnavailable }
        await failing.boot()
        XCTAssertEqual(failing.state, .live)
        XCTAssertNotNil(failing.notice)
        XCTAssertEqual(try ShareTargetIndex.persisted(from: area), [live])
    }

    // MARK: Capabilities and the fence on Live writes

    func testLiveHasNoApnsNoLiveDropAndNoShareBridge() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let runtime = try LiveRuntime(install: LiveInstall(origin: origin, owner: nil), storage: rig.storage)
        let services = LiveServices(options: options, runtime: runtime, resetFlags: rig.flags)
        var reads = 0, registrations = 0
        services.currentPermission = { reads += 1; return .authorized }
        services.registerForAPNs = { registrations += 1 }
        await services.refreshNotificationStatus()
        XCTAssertEqual(reads + registrations, 0)
        XCTAssertNil(ShareBridge.make(world: services, override: FileManager.default.temporaryDirectory))      // no Live share without the capability
        // Even a Live runtime offering share would need the fence: the bridge runs inside it (it exists only for a fenced Live).
        runtime.capabilities = RealmCapabilities(drop: false, share: true, push: false, demoControls: false)
        XCTAssertNotNil(ShareBridge.make(world: services, override: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        runtime.invalidate()
        services.retire()
    }

    func testPushMaterialAndTheDraftFileGoThroughTheRealmFence() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let runtime = try LiveRuntime(install: LiveInstall(origin: origin, owner: nil), storage: rig.storage)
        let sink = runtime.makePushSink()
        try sink.put(Data("m".utf8), realm: "live", ws: String(repeating: "c", count: 32), purpose: "push-material")
        XCTAssertThrowsError(try sink.put(Data("m".utf8), realm: "demo", ws: String(repeating: "c", count: 32), purpose: "push-material"))
        // The draft: written inside the fence, never without one in Live.
        let services = LiveServices(options: options, runtime: runtime, resetFlags: rig.flags)
        let id = SystemEntropy().id16()
        let draftDir = FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: draftDir) }
        let api = DraftStub()
        let info = WorkspaceInfo(id: id.hex, name: "Test", host: "Mac", hue: 0, hostedBy: nil, clientHosted: false,
                                 scopes: [.look, .operate, .decide], connection: .online, primaryLabel: "Mac", notificationsOn: false)
        let ws = LiveWorkspace(workspaceID: id, generation: 1, api: api, info: info)
        services.register(ws)
        ws.draftURL = draftDir.appendingPathComponent("ticket-draft.json")
        ws.requiresDraftFence = true
        var result = await ws.createTicket(title: "t", body: "b")             // no fence at all: refused before anything is written
        guard case .failed(let missing) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(missing.contains("draft"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftDir.appendingPathComponent("ticket-draft.json").path))
        ws.draftFence = runtime.writeFence
        result = await ws.createTicket(title: "t", body: "b")                 // fenced and current: saved, then sent (and the reply is lost)
        guard case .failed(let unconfirmed) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(unconfirmed.contains("not confirmed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftDir.appendingPathComponent("ticket-draft.json").path))
        try FileManager.default.removeItem(at: draftDir.appendingPathComponent("ticket-draft.json"))
        runtime.invalidate()                                                  // the realm ended: a late write is refused
        result = await ws.createTicket(title: "t2", body: "b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftDir.appendingPathComponent("ticket-draft.json").path))
        XCTAssertThrowsError(try sink.put(Data("m".utf8), realm: "live", ws: String(repeating: "c", count: 32), purpose: "push-material"))
    }

    func testAStaleRealmEndsAPairingAsCancelledNotAsABadLink() {
        XCTAssertEqual(LivePairingModel.state(forRealm: .staleGeneration), .entry)
        XCTAssertEqual(LivePairingModel.state(forRealm: .externalOrigin), .refused(.invalidLink))
    }
}
