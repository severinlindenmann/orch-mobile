import XCTest
import OrchClient
import OrchCoordination
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchShareStaging
import AVFoundation
import OrchStore
#if DEBUG // uses DEBUG-only seams (LiveTransport.testingTransport, liveBootGate); the Release flag check compiles all tests
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
        if installed { try rig.install.save(LiveInstall(origin: origin, owner: nil)) }
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
        XCTAssertEqual(services.capabilities, RealmCapabilities(drop: false, share: false, push: false, demoControls: false, writes: false))
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
        runtime.capabilities = RealmCapabilities(drop: false, share: true, push: false, demoControls: false, writes: false)
        XCTAssertNotNil(ShareBridge.make(world: services, override: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        runtime.invalidate()
        services.retire()
    }

    // MARK: relay push (P3-D40): Live lifecycle with the capability on

    private func pushServices(_ rig: Rig, push: FakePush? = nil) throws -> (LiveServices, LiveRuntime, LiveWorkspace, FakePush) {
        let runtime = try LiveRuntime(install: LiveInstall(origin: origin, owner: nil), storage: rig.storage)
        runtime.capabilities = RealmCapabilities(drop: false, share: false, push: true, demoControls: false, writes: false)
        let services = LiveServices(options: options, runtime: runtime, resetFlags: rig.flags)
        services.pushEnvironment = { .sandbox }
        services.pushToken = { B64U.encode(Data(repeating: 5, count: 32)) }
        services.wipeWorkspace = { _, _ in }
        services.beginWorkspaceWipe = { _, _ in }
        services.resetRuntime = { _ in }
        let id = SystemEntropy().id16()
        let info = WorkspaceInfo(id: id.hex, name: "Test", host: "Mac", hue: 0, hostedBy: nil, clientHosted: false,
                                 scopes: [.look, .operate, .decide], connection: .online, primaryLabel: "Mac", notificationsOn: false)
        let ws = LiveWorkspace(workspaceID: id, generation: 1, api: DraftStub(), info: info)
        services.register(ws)
        let fake = push ?? FakePush(id)
        ws.push = fake
        services.pushUnregister = { [weak ws] _ in await (ws?.push as? FakePush)?.unregisterAll() ?? .removed }
        _ = services.pushCoordinatorForLive()
        return (services, runtime, ws, fake)
    }

    func testLiveLeaveRemovesTheRelayRegistrationBeforeTheWipeAndOwesNothingWhenItWorked() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let (services, _, ws, push) = try pushServices(rig)
        let report = await services.leave(workspaceID: ws.info.id, simulateOffline: false)
        XCTAssertEqual(push.unregisterCalls, 1)
        XCTAssertEqual(report.server, .finishOnMac)
        XCTAssertTrue(services.pendingServerCleanups.isEmpty)
        services.retire()
    }

    func testOfflineLiveLeaveRecordsTheOwedPushCleanupAndRetryClearsIt() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let (services, _, ws, _) = try pushServices(rig, push: nil)
        let offline = FakePush(ws.workspaceID, unregister: [.failed("offline")])
        ws.push = offline
        let report = await services.leave(workspaceID: ws.info.id, simulateOffline: false)
        XCTAssertFalse(report.incomplete)                                      // the local wipe is not affected
        XCTAssertEqual(services.pendingServerCleanups.map(\.ws), [ws.workspaceID.hex])
        var cleaned: [String] = []
        services.serverCleanup = { cleaned.append($0.ws) }
        await services.retryServerCleanup()
        XCTAssertEqual(cleaned, [ws.workspaceID.hex]); XCTAssertTrue(services.pendingServerCleanups.isEmpty)
        services.retire()
    }

    func testLeaveLiveUnregistersEveryWorkspaceBeforeTheRealmIsInvalidated() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let (services, _, ws, push) = try pushServices(rig)
        push.unregisterDelay = 0.3
        services.leaveLive(thenDemo: false)
        XCTAssertTrue(services.lifetime.isActive, "the realm is still alive while the registration is removed")
        for _ in 0..<200 where services.runtime != nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNil(services.runtime)
        XCTAssertEqual(push.unregisterCalls, 1)
        XCTAssertFalse(services.lifetime.isActive)
        _ = ws
        await services.waitForReset()
    }

    func testLeaveLiveIsNotHeldByAWedgedRelay() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let (services, _, _, push) = try pushServices(rig)
        push.unregisterDelay = 60
        let started = Date()
        services.leaveLive(thenDemo: false)
        for _ in 0..<400 where services.runtime != nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNil(services.runtime)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "bounded: a few seconds, then the wipe proceeds")
        await services.waitForReset()
    }

    func testKillDuringTheUnregisterWindowStillCompletesTheLeaveAtRelaunch() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let (services, runtime, _, push) = try pushServices(rig)
        push.unregisterDelay = 5
        services.leaveLive(thenDemo: false)
        // inside the window: the intent is already durable, the realm is cut off from use but not yet invalidated
        XCTAssertTrue(rig.flags.bool(forKey: "orch.live.resetPending"))
        XCTAssertTrue(services.leavingRealm)
        XCTAssertEqual(services.pushCoordinator?.closing, true)
        XCTAssertTrue(services.live.allSatisfy { services.state(for: $0.info.id) == .removing })
        XCTAssertTrue(services.live.allSatisfy { !services.canUse($0.info.id) })
        XCTAssertTrue(runtime.context.isCurrent)
        XCTAssertTrue(rig.install.exists)
        // the process is killed here: a fresh launch finds the gate, skips the relay and completes the wipe
        services.retire()
        let relaunched = makeServices(rig)
        await relaunched.boot()
        XCTAssertFalse(relaunched.resetIncomplete)
        XCTAssertFalse(rig.flags.bool(forKey: "orch.live.resetPending"))
        XCTAssertFalse(rig.install.exists)
        XCTAssertNil(relaunched.pushCoordinator)
        XCTAssertLessThanOrEqual(push.unregisterCalls, 1, "at most the first process asked; the relaunch never contacts the relay")
        relaunched.retire()
    }

    func testLeaveWorkspaceWritesTheWipeIntentBeforeTheUnregisterAndOwesIfItCannot() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let (services, _, ws, push) = try pushServices(rig)
        var order: [String] = []
        services.beginWorkspaceWipe = { _, _ in order.append("tombstone") }
        services.pushUnregister = { _ in order.append("unregister"); return .removed }
        _ = await services.leave(workspaceID: ws.info.id, simulateOffline: false)
        XCTAssertEqual(order, ["tombstone", "unregister"])
        XCTAssertTrue(services.pendingServerCleanups.isEmpty)
        // a tombstone that cannot be written leaves the cleanup owed, and the wipe still runs
        let (services2, _, ws2, _) = try pushServices(rig)
        services2.beginWorkspaceWipe = { _, _ in throw ViewError.offline }
        let report = await services2.leave(workspaceID: ws2.info.id, simulateOffline: false)
        XCTAssertFalse(report.incomplete)
        XCTAssertEqual(services2.pendingServerCleanups.map(\.ws), [ws2.workspaceID.hex])
        _ = push
        services.retire(); services2.retire()
    }

    func testLeaveWorkspaceMakesTheCleanupDurableBeforeTheWindowAndClearsItOnlyWhenDone() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let (services, _, ws, _) = try pushServices(rig)
        var inWindow: [String] = []
        var beforeTombstone: [String] = [], retried: [String] = []
        services.beginWorkspaceWipe = { _, _ in beforeTombstone = services.cleanupStore?.load().map(\.ws) ?? [] }
        services.serverCleanup = { retried.append($0.ws) }
        services.pushUnregister = { _ in
            inWindow = services.cleanupStore?.load().map(\.ws) ?? []
            await services.retryServerCleanup()               // a retry mid-window neither sends nor drops the Leave's own item
            XCTAssertEqual(services.cleanupStore?.load().map(\.ws), [ws.workspaceID.hex], "still owed after the retry")
            return .removed
        }
        _ = await services.leave(workspaceID: ws.info.id, simulateOffline: false)
        XCTAssertEqual(beforeTombstone, [], "nothing is owed before the tombstone is durable")
        XCTAssertEqual(inWindow, [ws.workspaceID.hex], "a kill inside the window finds the owed cleanup")
        XCTAssertEqual(retried, [])
        XCTAssertTrue(services.cleanupStore?.load().isEmpty == true, "removed on done")
        let (services2, _, ws2, _) = try pushServices(rig)
        services2.pushUnregister = { _ in .failed("offline") }
        _ = await services2.leave(workspaceID: ws2.info.id, simulateOffline: false)
        XCTAssertEqual(services2.cleanupStore?.load().map(\.ws), [ws2.workspaceID.hex], "owed stays")
        services.retire(); services2.retire()
    }

    #if DEBUG
    func testBeginLeaveCancelsReconcileTasks() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let (services, _, ws, _) = try pushServices(rig)
        services.startReconcile(workspace: ws, decisionID: SystemEntropy().id16())
        XCTAssertEqual(services.reconcileTaskCount, 1)
        XCTAssertTrue(services.beginLeave())
        // ordering: everything below holds right after the synchronous call, before any await
        XCTAssertTrue(rig.flags.bool(forKey: "orch.live.resetPending"))
        XCTAssertEqual(services.pushCoordinator?.closing, true)
        XCTAssertEqual(services.state(for: ws.info.id), .removing)
        XCTAssertEqual(services.reconcileTaskCount, 0)
        await services.drainPushRegistrations()
        services.retire()
    }
    #endif

    #if DEBUG
    func testTheDrainHasOneBoundIncludingTheSessionStops() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let (services, _, _, push) = try pushServices(rig)
        services.drainBound = 0.3
        services.drainBeforeStop = { try? await Task.sleep(for: .seconds(30)) }
        XCTAssertTrue(services.beginLeave())
        let started = Date()
        await services.drainPushRegistrations()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertFalse(services.leavingRealm)
        _ = push
        services.retire()
    }
    #endif

    func testOwedCleanupsDoNotDelayRegistrationBeyondTheirBound() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let (services, _, ws, _) = try pushServices(rig)
        let sleeper = Task { try? await Task.sleep(for: .seconds(30)) }
        defer { sleeper.cancel() }
        services.serverCleanup = { _ in await sleeper.value; throw ViewError.offline }
        services.cleanupStore?.add(PendingServerCleanup(ws: SystemEntropy().id16().hex, generation: 1, since: Date()))
        let started = Date()
        await services.retryServerCleanup(within: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(services.cleanupStore?.load().count, 1)
        _ = ws
        services.retire()
    }

    func testAFailedWipeKeepsTheOwedCleanupAndARetryNeitherSendsNorDropsIt() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let (services, _, ws, _) = try pushServices(rig)
        services.pushUnregister = { _ in .failed("offline") }
        services.wipeWorkspace = { _, _ in throw ViewError.offline }
        let report = await services.leave(workspaceID: ws.info.id, simulateOffline: false)
        XCTAssertTrue(report.incomplete)
        XCTAssertEqual(services.state(for: ws.info.id), .removalIncomplete)
        var cleaned: [String] = []
        services.serverCleanup = { cleaned.append($0.ws) }
        await services.retryServerCleanup()
        XCTAssertTrue(cleaned.isEmpty)
        XCTAssertEqual(services.cleanupStore?.load().map(\.ws), [ws.workspaceID.hex])
        services.retire()
    }

    func testTheRetryPathUsesTheLeaveClassifier() async throws {
        for (outcome, owed) in [(PushRegistrationOutcome.refused("malformed"), true), (.refused("bad_reply"), true), (.refused("revoked"), false),
                                (.refused("not_eligible"), false), (.removed, false), (.pushOff, false), (.rateLimited(retryAfter: nil), true),
                                (.failed("x"), true), (.registered(SystemEntropy().id16()), true)] {
            XCTAssertEqual(PushRegistrationCoordinator.removal(for: outcome) == .owed, owed, "\(outcome)")
            if owed { XCTAssertThrowsError(try LiveRuntime.requireDone(outcome), "\(outcome)") } else { XCTAssertNoThrow(try LiveRuntime.requireDone(outcome)) }
        }
    }

    func testAnOwedCleanupNeverReachesAReJoinedWorkspaceAndOldOnesAreDropped() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let (services, _, ws, _) = try pushServices(rig)
        var cleaned: [String] = []
        services.serverCleanup = { cleaned.append($0.ws) }
        let store = try XCTUnwrap(services.cleanupStore)
        store.add(PendingServerCleanup(ws: ws.workspaceID.hex, generation: 0, since: Date()))          // the same workspace is joined again
        let stale = SystemEntropy().id16().hex
        store.add(PendingServerCleanup(ws: stale, generation: 1, since: Date().addingTimeInterval(-61 * 86_400)))
        await services.retryServerCleanup()
        XCTAssertTrue(cleaned.isEmpty)
        XCTAssertTrue(services.pendingServerCleanups.isEmpty)
        services.retire()
    }

    func testPushStaysOffInLiveByDefaultAndTheCoordinatorDoesNotExist() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let runtime = try LiveRuntime(install: LiveInstall(origin: origin, owner: nil), storage: rig.storage)
        XCTAssertFalse(runtime.capabilities.push)
        let services = LiveServices(options: options, runtime: runtime, resetFlags: rig.flags)
        XCTAssertNil(services.pushCoordinatorForLive())
        services.retire()
    }

    func testPushMaterialAndTheDraftFileGoThroughTheRealmFence() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let runtime = try LiveRuntime(install: LiveInstall(origin: origin, owner: nil), storage: rig.storage)
        let sink = try XCTUnwrap(runtime.makePushSink())
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

// MARK: - Live entry (B2b)

private final class SendCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

private struct CountingSender: RequestSender {
    let origin: String
    let counter: SendCounter
    func send(_ request: WireRequest) async throws -> WireReply { counter.hit(); throw TransportError.disconnected }
}

private func invitation(origin: String = "https://relay.example.org", orch: Bool = false) -> String {
    let id = String(repeating: "ab", count: 16)
    let pin = B64U.encode(Data(repeating: 7, count: 32))
    let fragment = "v2.\(id).\(id).\(pin).\(pin).\(pin)"
    if orch {
        let encoded = origin.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? origin
        return "orch://pair?relay=\(encoded)#\(fragment)"
    }
    return "\(origin)/app/pair#\(fragment)"
}

extension LiveRuntimeTests {
    private func parsed(_ text: String) throws -> PairingLink { try PairingLink.parse(text) }

    private func seedOrphans(_ rig: Rig) throws {
        let ws = ID16.random().hex
        try rig.keys.put(Data("k".utf8), for: SecretID(realm: .live, ws: ws, purpose: "pairing"))
        try rig.push.put(Data("p".utf8), for: SecretID(realm: .live, ws: ws, purpose: "push"))
        _ = try rig.storage.makeCustody().create(realm: .live)           // device keys that survived an uninstall
    }

    /// What exists on disk and in the keychain for Live right now.
    private struct Footprint: Equatable {
        var items: Int, custody: CustodyStatus, realmDir: Bool, install: Bool
    }
    private func footprint(_ rig: Rig) throws -> Footprint {
        Footprint(items: try liveVaultItems(rig), custody: rig.storage.makeCustody().status(realm: .live),
                  realmDir: FileManager.default.fileExists(atPath: rig.storage.layout.realmDir.path), install: rig.install.exists)
    }

    // MARK: Install-record ordering (Opus M2, Sonnet LOW 7)

    func testFreshEntryWipesOrphansThenPersistsTheRecordThenCreatesTheRuntime() async throws {
        let rig = try makeRig(installed: false); defer { rig.cleanup() }
        try seedOrphans(rig)
        XCTAssertGreaterThan(try footprint(rig).items, 0)
        let services = makeServices(rig)
        await services.boot()
        XCTAssertNil(services.runtime)
        var atSave: Footprint?
        services.persistInstall = { install in
            atSave = try self.footprint(rig)                 // what exists the moment the record is written
            try rig.install.save(install)
        }
        let runtime = try await services.liveRuntimeForPairing(origin: origin)
        // Before the record: no Live keychain item, no device keys, no index, no record.
        XCTAssertEqual(atSave, Footprint(items: 0, custody: .missing, realmDir: false, install: false))
        XCTAssertEqual(rig.install.load(), LiveInstall(origin: origin, owner: nil))
        XCTAssertTrue(runtime.booted && services.isLive && services.runtime === runtime)
        // A second Connect for the same origin reuses the running Live (a second workspace), another origin is refused.
        let again = try await services.liveRuntimeForPairing(origin: origin)
        XCTAssertTrue(again === runtime)
        services.resetThisiPhone(); await services.waitForReset()
        XCTAssertEqual(try footprint(rig), Footprint(items: 0, custody: .missing, realmDir: false, install: false))
    }

    func testAnInstallRecordThatCannotBeSavedFailsTheFlowAndLeavesNothing() async throws {
        let rig = try makeRig(installed: false); defer { rig.cleanup() }
        try seedOrphans(rig)
        let services = makeServices(rig)
        await services.boot()
        services.persistInstall = { _ in throw LiveError.installNotSaved }
        do { _ = try await services.liveRuntimeForPairing(origin: origin); XCTFail("must fail") }
        catch { XCTAssertEqual(error as? LiveError, .installNotSaved) }
        // The crash window: the orphan wipe ran, the record did not. Nothing is left, nothing is attached, no Live start next launch.
        XCTAssertEqual(try footprint(rig), Footprint(items: 0, custody: .missing, realmDir: false, install: false))
        XCTAssertNil(services.runtime)
        XCTAssertFalse(services.hasLiveInstall)
        let next = makeServices(rig)
        await next.boot()
        XCTAssertNil(next.runtime)
        XCTAssertFalse(next.isLive)
        // And the person can simply try again.
        services.persistInstall = nil
        let runtime = try await services.liveRuntimeForPairing(origin: origin)
        XCTAssertTrue(runtime.booted)
        services.resetThisiPhone(); await services.waitForReset()
    }

    func testTheInstallStoreThrowsWhenItCannotEncodeOrReadBack() throws {
        let rig = try makeRig(installed: false); defer { rig.cleanup() }
        try rig.install.save(LiveInstall(origin: origin, owner: nil))
        XCTAssertEqual(rig.install.load()?.origin, origin)
        XCTAssertThrowsError(try LiveInstallStore(defaults: ReadBackFailsDefaults()).save(LiveInstall(origin: origin, owner: nil)))
    }

    // MARK: One origin per install, https only, decided before any network access

    func testAnOtherOriginAndInsecureOriginsAreRefusedBeforeAnyNetworkAccess() async throws {
        let counter = SendCounter()
        let rig = try makeRig(); defer { rig.cleanup() }
        var storage = rig.storage
        storage.makeTransport = { try LiveTransport.testingTransport(context: $0, sender: CountingSender(origin: $0.origin, counter: counter)) }
        let services = LiveServices(options: options, resetFlags: rig.flags)
        services.liveStorage = { storage }
        await services.boot()
        let runtime = try XCTUnwrap(services.runtime as? LiveRuntime)
        for (offered, expected) in [("https://other.example.org", LiveError.differentOrigin), ("http://127.0.0.1:8080", .unsupportedOrigin),
                                    ("https://relay.demo.invalid", .unsupportedOrigin), ("http://relay.example.org", .unsupportedOrigin)] {
            do { _ = try await services.liveRuntimeForPairing(origin: offered); XCTFail("\(offered) must be refused") }
            catch { XCTAssertEqual(error as? LiveError, expected, offered) }
        }
        XCTAssertEqual(counter.count, 0)
        XCTAssertTrue(services.runtime === runtime)
        XCTAssertEqual(rig.install.load()?.origin, origin)            // never retargeted
        XCTAssertFalse(LiveServices.isLiveOrigin("http://127.0.0.1:1234"))
        XCTAssertTrue(LiveServices.isLiveOrigin("https://relay.example.org"))
        let again = try await services.liveRuntimeForPairing(origin: origin)
        XCTAssertTrue(again === runtime)
        services.resetThisiPhone(); await services.waitForReset()
    }

    func testLiveEntryIsRefusedOverDemoAndWhileAnyWipeIsUnfinished() async throws {
        let rig = try makeRig(installed: false); defer { rig.cleanup() }
        rig.flags.set(true, forKey: "orch.live.resetPending")
        let services = makeServices(rig)
        var attempts = 0
        services.finishInterruptedLiveReset = { _ in attempts += 1; throw ViewError.offline }
        await services.boot()
        XCTAssertTrue(services.resetIncomplete)
        do { _ = try await services.liveRuntimeForPairing(origin: origin); XCTFail("must be refused") }
        catch { XCTAssertEqual(error as? LiveError, .entryUnavailable) }
        XCTAssertFalse(rig.install.exists)
    }

    // MARK: Owner pin (Opus M1)

    func testTheOwnerPinIsDerivedFromTheCommittedProfileAtBootAndRecorded() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }                  // an install record WITHOUT an owner: a crash after commitJoin
        try await commit(joined, into: rig)
        XCTAssertNil(rig.install.load()?.owner)
        let services = makeServices(rig)
        await services.boot()
        let runtime = try XCTUnwrap(services.runtime as? LiveRuntime)
        XCTAssertEqual(runtime.derivedOwner, joined.profile.pkPub)
        XCTAssertEqual(rig.install.load()?.owner, joined.profile.pkPub)   // recorded with a throwing save
        XCTAssertEqual(runtime.recordedOwner, joined.profile.pkPub)
        XCTAssertEqual(services.live.count, 1)
        XCTAssertNil(services.liveNotice)
        services.retire(); await services.waitForRetire()
        // The next launch is pinned from the record: the context refuses another owner's certificate.
        let second = makeServices(rig)
        await second.boot()
        let pinned = try XCTUnwrap(second.runtime as? LiveRuntime)
        XCTAssertNotNil(pinned.context.pinnedOwner)
        XCTAssertNil(pinned.derivedOwner)
        second.resetThisiPhone(); await second.waitForReset()
    }

    func testAFailedOwnerWriteIsVisibleAndTheJoinSurvives() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(joined, into: rig)
        let services = makeServices(rig)
        services.persistInstall = { _ in throw LiveError.installNotSaved }
        await services.boot()
        XCTAssertEqual(services.live.count, 1)                            // the committed workspace is not undone
        XCTAssertNotNil(services.liveNotice)
        XCTAssertNil(rig.install.load()?.owner)                           // and the next boot derives it again
        services.resetThisiPhone(); await services.waitForReset()
    }

    func testTwoOwnersInOneInstallRefuseTheBootAndRebuildNothing() async throws {
        let first = try await demoJoin(), second = try await demoJoin()
        XCTAssertNotEqual(first.profile.pkPub, second.profile.pkPub)
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(first, into: rig)
        let index = try await WorkspaceIndex(layout: rig.storage.layout)
        var profile = second.profile
        profile.origin = origin
        try await index.savePairing(PairingRow(ws: profile.ws, offer: String(repeating: "1", count: 32), generation: 1, origin: origin,
                                               phase: "joining", startedMs: 0, updatedMs: 0))
        try await index.commitJoin(generation: 1, profile: profile)
        await index.close()
        let services = makeServices(rig)
        await services.boot()
        XCTAssertTrue(services.live.isEmpty)
        XCTAssertNotNil(services.liveBootError)
        XCTAssertEqual((services.runtime as? LiveRuntime)?.booted, false)
        XCTAssertNil(rig.install.load()?.owner)                           // nothing was pinned from a contradictory store
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.storage.layout.indexURL.path))    // and nothing was erased
        services.resetThisiPhone(); await services.waitForReset()         // Leave Live is the way out
        XCTAssertFalse(services.resetIncomplete)
        XCTAssertFalse(rig.install.exists)
    }

    func testAWorkspaceOfAnotherOwnerThanThePinIsNotRebuiltAndIsSurfaced() async throws {
        let first = try await demoJoin(), other = try await demoJoin()
        let rig = try makeRig(installed: false); defer { rig.cleanup() }
        try rig.install.save(LiveInstall(origin: origin, owner: other.profile.pkPub))
        try await commit(first, into: rig)
        let services = makeServices(rig)
        await services.boot()
        XCTAssertTrue(services.live.isEmpty)
        XCTAssertEqual((services.runtime as? LiveRuntime)?.skipped.map(\.reason), ["owner"])
        XCTAssertEqual(services.skippedWorkspaceCount, 1)                 // Live Home shows "1 workspace couldn't be verified"
        services.resetThisiPhone(); await services.waitForReset()
    }

    // MARK: Retired graphs, stuck wipes

    func testARetiredGraphDoesNotStartLive() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let services = makeServices(rig)
        services.retire()
        await services.boot()
        XCTAssertNil(services.runtime)                                     // guard !retired in startLive (Opus L1)
        let other = makeServices(rig)
        await other.boot()
        other.resetThisiPhone(); await other.waitForReset()
    }

    func testTheForceEraseEscapeRemovesLiveFilesWithoutTheKeychainAndTheNextEntryCleansTheKeychain() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(joined, into: rig)
        rig.flags.set(true, forKey: "orch.live.resetPending")
        let services = makeServices(rig)
        services.finishInterruptedLiveReset = { _ in throw ViewError.offline }
        services.removeLiveFiles = { try LiveStorage.removeLiveFiles(layout: rig.storage.layout) }
        await services.boot()
        XCTAssertTrue(services.resetIncomplete)
        try await services.forceEraseLive()
        XCTAssertFalse(services.resetIncomplete)
        XCTAssertFalse(rig.install.exists)
        XCTAssertFalse(rig.flags.bool(forKey: "orch.live.resetPending"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.storage.layout.realmDir.path))
        XCTAssertGreaterThan(try liveVaultItems(rig), 0)                  // the keychain was not touched (it may be what is unavailable)
        // The orphans go before the next install record exists.
        let next = makeServices(rig)
        await next.boot()
        var itemsAtSave = -1
        next.persistInstall = { install in itemsAtSave = try self.liveVaultItems(rig); try rig.install.save(install) }
        _ = try await next.liveRuntimeForPairing(origin: origin)
        XCTAssertEqual(itemsAtSave, 0)
        next.resetThisiPhone(); await next.waitForReset()
    }

    // MARK: Intake (scan, paste, orch://) and the controller

    private func makeController(_ rig: Rig, demo: Bool = false) -> RealmController {
        let opts = LaunchOptions.parse(arguments: ["--ui-testing"] + (demo ? ["--demo"] : []), debug: true)
        let controller = RealmController(options: opts, resetFlags: rig.flags)
        controller.shareArea = nil
        controller.services.liveStorage = { rig.storage }
        controller.makeServices = { o, d in
            let s = LiveServices(options: o, resetFlags: d)
            s.liveStorage = { rig.storage }
            return s
        }
        return controller
    }

    func testAnOpenedOrchLinkAlwaysLandsOnAReviewScreenAndNeverConnects() async throws {
        let rig = try makeRig(installed: false); defer { rig.cleanup() }
        let counter = SendCounter()
        let controller = makeController(rig)
        let intake = LiveIntake(realm: controller)
        // Cold launch: the URL arrives before the realm booted and is held.
        intake.handle(url: try XCTUnwrap(URL(string: invitation(orch: true))))
        XCTAssertNil(intake.screen)
        await controller.boot()
        intake.realmBooted()
        guard case .review(let link)? = intake.screen else { return XCTFail("\(String(describing: intake.screen))") }
        XCTAssertEqual(link.reviewedOrigin, "https://relay.example.org")
        XCTAssertEqual(controller.state, .welcome)                         // no connection, no install, no realm change
        XCTAssertFalse(controller.services.hasLiveInstall)
        XCTAssertNil(controller.services.runtime)
        XCTAssertEqual(counter.count, 0)
        // Only the orch scheme is ours; text that is not a pairing link is not a review.
        intake.dismiss()
        intake.handle(url: try XCTUnwrap(URL(string: "https://example.org/")))
        XCTAssertNil(intake.screen)
        intake.handle(text: "not a link")
        XCTAssertEqual(intake.screen, .refused(.invalidLink))
        intake.dismiss()
        // https paste form, and loopback http / Demo origins never reach the review.
        intake.handle(text: invitation())
        guard case .review? = intake.screen else { return XCTFail("paste form") }
        intake.dismiss()
        intake.handle(text: invitation(origin: "http://127.0.0.1:8080"))
        XCTAssertEqual(intake.screen, .refused(.unsupportedOrigin("http://127.0.0.1:8080")))
        intake.dismiss()
        intake.handle(text: invitation(origin: "https://relay.demo.invalid"))
        XCTAssertEqual(intake.screen, .refused(.unsupportedOrigin("https://relay.demo.invalid")))
    }

    func testALiveLinkDuringDemoIsHeldAndOffersTheSwitchButNeverSwitches() async throws {
        let rig = try makeRig(installed: false); defer { rig.cleanup() }
        let controller = makeController(rig, demo: true)
        await controller.boot()
        XCTAssertEqual(controller.state, .demo)
        let intake = LiveIntake(realm: controller)
        intake.realmBooted()
        intake.handle(text: invitation(orch: true))
        guard case .switchOffer(let link)? = intake.screen else { return XCTFail("\(String(describing: intake.screen))") }
        XCTAssertEqual(intake.held, link)
        XCTAssertEqual(controller.state, .demo)                            // still Demo: nothing switched
        XCTAssertTrue(controller.services.isDemo)
        XCTAssertFalse(controller.services.hasLiveInstall)
        // Connect from the switch offer is impossible: only the explicit, confirmed leave moves on, and it lands on the REVIEW.
        intake.connect(link)
        XCTAssertEqual(intake.screen, .switchOffer(link))
        intake.leaveDemoAndPair()
        intake.handle(text: invitation(origin: "https://other.example.org"))      // ignored while Demo is being left
        XCTAssertEqual(intake.screen, .leavingDemo)
        XCTAssertNotNil(intake.notice)
        await controller.waitForTransition()
        for _ in 0..<400 where intake.screen == .leavingDemo { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.state, .welcome)
        XCTAssertEqual(intake.screen, .review(link))
        XCTAssertFalse(controller.services.hasLiveInstall)                 // reviewing is not connecting
    }

    func testAnInvitationForAnotherOriginIsRefusedOnAnExistingLiveInstall() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let controller = makeController(rig)
        await controller.boot()
        XCTAssertEqual(controller.state, .live)
        let intake = LiveIntake(realm: controller)
        intake.realmBooted()
        intake.handle(text: invitation(origin: "https://other.example.org"))
        XCTAssertEqual(intake.screen, .refused(.differentOrigin(existing: origin, offered: "https://other.example.org")))
        intake.handle(text: invitation())
        guard case .review? = intake.screen else { return XCTFail("same origin reviews") }
        controller.realmLeave(thenDemo: false); await controller.waitForTransition()
    }

    func testEnteringLiveFromWelcomeMovesTheControllerAndLeaveReturnsToWelcomeTruthfully() async throws {
        let rig = try makeRig(installed: false); defer { rig.cleanup() }
        let controller = makeController(rig)
        await controller.boot()
        XCTAssertEqual(controller.state, .welcome)
        _ = try await controller.services.liveRuntimeForPairing(origin: origin)
        XCTAssertEqual(controller.state, .live)
        XCTAssertTrue(controller.services.isLive)
        controller.realmLeave(thenDemo: false)
        await controller.waitForTransition()
        XCTAssertEqual(controller.state, .welcome)
        XCTAssertFalse(rig.install.exists)
        XCTAssertEqual(try liveVaultItems(rig), 0)
        // No join ever happened: nothing to finish on the Mac.
        XCTAssertEqual(controller.notice, "Removed from this iPhone.")
    }

    func testTheLeaveNoticeMentionsTheMacOnlyAfterAJoin() {
        XCTAssertEqual(RealmController.leftLiveNotice(hadJoin: true), "Removed from this iPhone; finish removing it on your Mac.")
        XCTAssertEqual(RealmController.leftLiveNotice(hadJoin: false), "Removed from this iPhone.")
    }

    func testALateOwnerRecordAfterALeaveDoesNotUndoIt() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(joined, into: rig)
        let services = makeServices(rig)
        await services.boot()
        let runtime = try XCTUnwrap(services.runtime as? LiveRuntime)
        XCTAssertTrue(services.liveHadJoin)
        services.resetThisiPhone(); await services.waitForReset()
        XCTAssertFalse(rig.install.exists)
        runtime.recordedOwner = nil                                           // the post-join task of a pairing that outlived the Leave
        services.recordOwner(joined.profile.pkPub, runtime: runtime)
        XCTAssertFalse(rig.install.exists)                                    // the install record is not resurrected
        // And a runtime other than the attached one is refused too.
        let live = makeServices(rig)
        try rig.install.save(LiveInstall(origin: origin, owner: nil))
        await live.boot()
        runtime.recordedOwner = nil
        live.recordOwner(joined.profile.pkPub, runtime: runtime)
        XCTAssertNil(rig.install.load()?.owner)
        live.resetThisiPhone(); await live.waitForReset()
    }

    func testAnUndecodableOwnerKeyIsNeverUsedAsAPin() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(joined, into: rig)
        let index = try await WorkspaceIndex(layout: rig.storage.layout)
        var p = joined.profile
        p.pkPub = "not-a-key"
        p.ws = ID16.random().hex
        try await index.savePairing(PairingRow(ws: p.ws, offer: String(repeating: "2", count: 32), generation: 1, origin: origin, phase: "joining", startedMs: 0, updatedMs: 0))
        try await index.commitJoin(generation: 1, profile: p)
        do { _ = try await LiveRuntime.agreedOwner(index: index, pinned: nil); XCTFail("must refuse") }
        catch { XCTAssertEqual(error as? LiveError, .invalidInstall) }
        await index.close()
    }

    func testTwoOwnersShowTheirOwnCopy() async throws {
        let first = try await demoJoin(), second = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(first, into: rig)
        let index = try await WorkspaceIndex(layout: rig.storage.layout)
        var profile = second.profile
        profile.origin = origin
        try await index.savePairing(PairingRow(ws: profile.ws, offer: String(repeating: "1", count: 32), generation: 1, origin: origin,
                                               phase: "joining", startedMs: 0, updatedMs: 0))
        try await index.commitJoin(generation: 1, profile: profile)
        await index.close()
        let services = makeServices(rig)
        await services.boot()
        XCTAssertTrue(try XCTUnwrap(services.liveBootError).contains("two different owners"))
        services.resetThisiPhone(); await services.waitForReset()
    }

    func testAnUnbootedLiveInstallLeavesWithTheMacStep() async throws {
        let first = try await demoJoin(), second = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(first, into: rig)
        let index = try await WorkspaceIndex(layout: rig.storage.layout)
        var profile = second.profile
        profile.origin = origin
        try await index.savePairing(PairingRow(ws: profile.ws, offer: String(repeating: "1", count: 32), generation: 1, origin: origin,
                                               phase: "joining", startedMs: 0, updatedMs: 0))
        try await index.commitJoin(generation: 1, profile: profile)
        await index.close()
        let controller = makeController(rig)
        await controller.boot()
        XCTAssertNotNil(controller.services.liveBootError)               // ownerDisagreement: no runtime booted, nothing in memory
        XCTAssertTrue(controller.services.liveHadJoin)                   // unknown counts as "a join may exist"
        controller.realmLeave(thenDemo: false); await controller.waitForTransition()
        XCTAssertEqual(controller.notice, "Removed from this iPhone; finish removing it on your Mac.")
    }

    func testAPairingThatReachedTheHostIsRememberedEvenWithoutACommit() async throws {
        let rig = try makeRig(installed: false); defer { rig.cleanup() }
        let services = makeServices(rig)
        await services.boot()
        _ = try await services.liveRuntimeForPairing(origin: origin)
        XCTAssertFalse(services.liveHadJoin)
        services.notePairingProgress()
        XCTAssertTrue(services.liveHadJoin)
        services.resetThisiPhone(); await services.waitForReset()
        XCTAssertFalse(services.liveHadJoin)                            // the flag goes with the install
    }

    func testAPinnedBootSkipsAnUndecodableRowInsteadOfRefusingTheBoot() async throws {
        let joined = try await demoJoin()
        let rig = try makeRig(); defer { rig.cleanup() }
        try await commit(joined, into: rig)
        let index = try await WorkspaceIndex(layout: rig.storage.layout)
        var p = joined.profile
        p.pkPub = "not-a-key"
        p.ws = ID16.random().hex
        try await index.savePairing(PairingRow(ws: p.ws, offer: String(repeating: "2", count: 32), generation: 1, origin: origin, phase: "joining", startedMs: 0, updatedMs: 0))
        try await index.commitJoin(generation: 1, profile: p)
        let owner = try await LiveRuntime.agreedOwner(index: index, pinned: joined.profile.pkPub)   // pinned: no throw, nothing recorded
        XCTAssertNil(owner)
        await index.close()
    }

    func testASecondInvitationNeverSwapsTheOneUnderReviewAndInputIsIgnoredWhileLeavingDemo() async throws {
        let rig = try makeRig(installed: false); defer { rig.cleanup() }
        let controller = makeController(rig)
        await controller.boot()
        let intake = LiveIntake(realm: controller)
        intake.realmBooted()
        intake.handle(text: invitation(orch: true), source: .otherApp)
        guard case .review(let first)? = intake.screen else { return XCTFail("review") }
        XCTAssertEqual(intake.source, .otherApp)
        // Another invitation (another relay) while one is under review: refused with a visible notice; the reviewed origin is unchanged.
        intake.handle(text: invitation(origin: "https://other.example.org"), source: .scanned)
        XCTAssertEqual(intake.screen, .review(first))
        XCTAssertEqual(intake.source, .otherApp)
        XCTAssertNotNil(intake.notice)
        intake.clearNotice()
        XCTAssertNil(intake.notice)
        intake.dismiss()
        XCTAssertNil(intake.notice)
        intake.handle(text: invitation(), source: .scanned)
        XCTAssertEqual(intake.source, .scanned)
    }

    // MARK: Live pairing model

    func testALivePairingPausesAndHidesCodesInTheBackground() async throws {
        let rig = try makeRig(installed: false); defer { rig.cleanup() }
        let services = makeServices(rig)
        await services.boot()
        let model = LivePairingModel(services: services, link: try parsed(invitation()))
        XCTAssertEqual(model.state, .connecting)
        XCTAssertFalse(model.isDemo)
        XCTAssertEqual(model.hostLabel, "your Mac")
        model.setActive(false)
        XCTAssertTrue(model.obscured)
        model.setActive(true)
        XCTAssertFalse(model.obscured)
        model.cancel()
        try await Task.sleep(for: .milliseconds(300))
        services.resetThisiPhone(); await services.waitForReset()
    }

    func testEntryFailuresMapToRefusalsAndARealmEndedPairingIsACancel() {
        XCTAssertEqual(LivePairingModel.refusal(forEntry: LiveError.differentOrigin), .refused(.originRefused))
        XCTAssertEqual(LivePairingModel.refusal(forEntry: LiveError.unsupportedOrigin), .refused(.originRefused))
        XCTAssertEqual(LivePairingModel.refusal(forEntry: LiveError.installNotSaved), .refused(.liveNotPrepared))
        XCTAssertEqual(LivePairingModel.refusal(forEntry: LiveError.keychainUnavailable), .refused(.liveNotPrepared))
    }

    // MARK: Scanner

    func testTheScannerReportsWhyItCannotRun() {
        typealias A = ScannerAvailability
        XCTAssertEqual(A.resolve(isSupported: false, isAvailable: false, authorization: .authorized), .noCamera)
        XCTAssertEqual(A.resolve(isSupported: false, isAvailable: true, authorization: .notDetermined), .noCamera)
        // Not asked yet: the permission prompt comes first, "camera off" is never shown for it.
        XCTAssertEqual(A.resolve(isSupported: true, isAvailable: false, authorization: .notDetermined), .undetermined)
        XCTAssertEqual(A.resolve(isSupported: true, isAvailable: true, authorization: .notDetermined), .undetermined)
        XCTAssertEqual(A.resolve(isSupported: true, isAvailable: false, authorization: .denied), .notAllowed)
        XCTAssertEqual(A.resolve(isSupported: true, isAvailable: true, authorization: .restricted), .notAllowed)
        XCTAssertEqual(A.resolve(isSupported: true, isAvailable: false, authorization: .authorized), .notAllowed)
        XCTAssertEqual(A.resolve(isSupported: true, isAvailable: true, authorization: .authorized), .available)
        XCTAssertFalse(ScannerAvailability.noCamera.explanation.isEmpty)
        XCTAssertTrue(ScannerAvailability.notAllowed.explanation.contains("Paste") || ScannerAvailability.notAllowed.explanation.contains("paste"))
    }
}

/// A `UserDefaults` whose writes never read back (a full or protected store).
private final class ReadBackFailsDefaults: UserDefaults, @unchecked Sendable {
    init() { super.init(suiteName: "orch.tests.readback.\(UUID().uuidString)")! }
    override func set(_ value: Any?, forKey defaultName: String) {}
}
#endif
