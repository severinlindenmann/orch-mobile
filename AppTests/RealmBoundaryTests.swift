import XCTest
import OrchClient
import OrchCoordination
import OrchCustody
import OrchShareStaging
@testable import Orch

@MainActor
final class RealmBoundaryTests: XCTestCase {
    private let options = LaunchOptions.parse(arguments: ["--ui-testing"], debug: true)
    private let noOptionalSurfaces = RealmCapabilities(drop: false, share: false, push: false, demoControls: true)

    override func setUp() { PresentationGate.defaults = UserDefaults(suiteName: "orch.tests.gate.\(UUID().uuidString)")!; PresentationGate.markRebuilt() }
    override func tearDown() { PresentationGate.defaults = .standard; PresentationGate.markRebuilt() }

    /// Drives one Demo pairing to the end with the Demo humans' explicit approvals. `beforeApprovals` runs once the invitation exists.
    private func pair(_ services: LiveServices, beforeApprovals: (() -> Void)? = nil) async -> LivePairingModel {
        services.demo?.speed = 10
        let model = LivePairingModel(services: services, start: nil)
        model.useDemoInvitation()
        beforeApprovals?()
        let deadline = Date().addingTimeInterval(90)
        var done = false
        while !done, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            switch model.state {
            case .comparingHost where !model.demoHostCode.isEmpty: model.hostApprove()
            case .waitingPrimary: model.primaryOpenRequest()
            case .comparingPrimary where model.demoPrimaryHasChallenge: model.primaryApprove()
            case .ready, .refused, .alarm, .expired, .denied: done = true
            default: break
            }
        }
        services.demo?.speed = 1
        return model
    }

    // MARK: Capabilities

    func testDemoHasEveryCapabilityAndNoneHasNone() {
        let all = RealmCapabilities.demo
        XCTAssertTrue(all.drop && all.share && all.push && all.demoControls)
        let none = RealmCapabilities.none
        XCTAssertFalse(none.drop || none.share || none.push || none.demoControls)
        XCTAssertEqual(LiveServices(options: options).capabilities, .none)      // no realm attached: nothing is offered
        XCTAssertEqual(PreviewWorld(demo: true).capabilities, .demo)
    }

    func testWithoutDropCapabilityNoLiveDropIsBuiltAndNothingIsShareable() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        runtime.capabilities = noOptionalSurfaces
        let services = LiveServices(options: options, runtime: runtime)
        let model = await pair(services)
        guard case .ready = model.state else { return XCTFail("pairing did not finish: \(model.state)") }
        let ws = try XCTUnwrap(services.live.first)
        XCTAssertNil(ws.drop)
        XCTAssertTrue(services.dropItems.isEmpty)
        XCTAssertFalse(services.eligibleShareDestination(ws.info.id))
        XCTAssertFalse(services.canSend(to: ws.info.id))
        model.cancel()
        services.exitDemo(); await services.waitForReset()
    }

    func testDemoStillBuildsDropWhenCapable() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let services = LiveServices(options: options, runtime: runtime)
        let model = await pair(services)
        guard case .ready = model.state else { return XCTFail("pairing did not finish: \(model.state)") }
        XCTAssertNotNil(services.live.first?.drop)
        model.cancel()
        services.exitDemo(); await services.waitForReset()
    }

    func testWithoutPushCapabilityNeitherPermissionNorAPNsIsTouched() async {
        let services = LiveServices(options: options)     // no realm attached
        var reads = 0, registrations = 0
        services.currentPermission = { reads += 1; return .authorized }
        services.registerForAPNs = { registrations += 1 }
        await services.refreshNotificationStatus()
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(services.notificationStatus, .notAsked)
        XCTAssertEqual(services.pushDiagnostics, "")
    }

    func testShareBridgeOffersNoDestinationsWithoutShareCapability() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("realm-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let world = PreviewWorld(demo: true)
        let area = ShareArea(shareGroupRoot: root)
        let on = ShareBridge(area: area, world: world)
        on.publishTargets()
        XCTAssertFalse(try ShareTargetIndex.load(from: area).isEmpty)
        world.capabilities = noOptionalSurfaces
        on.publishTargets()
        // An empty index reads as "no workspaces" (what the extension explains to the user).
        XCTAssertThrowsError(try ShareTargetIndex.load(from: area))
    }

    // MARK: Late completion

    func testJoinCompletingAfterTheRealmWasLeftIsDropped() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let services = LiveServices(options: options, runtime: runtime)
        // The pairing starts in this realm; the realm is retired while it is still running, then the Demo humans finish it.
        let model = await pair(services) { services.retire() }
        guard case .ready = model.state else { return XCTFail("pairing did not finish: \(model.state)") }
        XCTAssertTrue(services.live.isEmpty)
        XCTAssertTrue(services.workspaces.isEmpty)
        model.cancel()
        services.exitDemo(); await services.waitForReset()
    }

    // MARK: Realm-scoped cleanup state

    func testServerCleanupIsSeparatedByRealmAndAdoptsTheLegacyListAsDemo() {
        let suite = "orch.cleanup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = [PendingServerCleanup(ws: "aa", generation: 1, since: Date())]
        defaults.set(try! JSONEncoder().encode(legacy), forKey: "orch.serverCleanup.pending")
        let demo = ServerCleanupStore(defaults: defaults, realm: .demo)
        XCTAssertEqual(demo.load().map(\.ws), ["aa"])
        XCTAssertNil(defaults.data(forKey: "orch.serverCleanup.pending"))
        let live = ServerCleanupStore(defaults: defaults, realm: .live)
        XCTAssertTrue(live.load().isEmpty)
        live.add(PendingServerCleanup(ws: "bb", generation: 2, since: Date()))
        XCTAssertEqual(demo.load().map(\.ws), ["aa"])
        demo.clear()
        XCTAssertEqual(live.load().map(\.ws), ["bb"])
    }

    // MARK: RealmController

    func testControllerReplacesTheServiceGraphOnEveryTransition() async throws {
        let controller = RealmController(options: options)
        await controller.boot()
        XCTAssertEqual(controller.state, .welcome)
        let welcome = controller.services
        let epoch0 = controller.epoch
        controller.realmEnterDemo()
        XCTAssertEqual(controller.state, .starting)
        await controller.waitForTransition()
        XCTAssertEqual(controller.state, .demo)
        let demo = controller.services
        XCTAssertFalse(demo === welcome)
        XCTAssertFalse(welcome.lifetime.isActive)
        XCTAssertTrue(demo.isDemo)
        XCTAssertGreaterThan(controller.epoch, epoch0)
        controller.realmLeave(thenDemo: false)
        XCTAssertEqual(controller.state, .leaving)
        XCTAssertFalse(demo.lifetime.isActive)
        await controller.waitForTransition()
        XCTAssertEqual(controller.state, .welcome)
        XCTAssertFalse(controller.services === demo)
        XCTAssertFalse(controller.services.isDemo)
    }

    func testFailedWipeParksInRecoveryUntilRetrySucceeds() async throws {
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
        controller.realmEnterDemo()
        await controller.waitForTransition()
        let demo = controller.services
        controller.realmLeave(thenDemo: false)
        await controller.waitForTransition()
        XCTAssertEqual(controller.state, .recoveryRequired)
        XCTAssertTrue(controller.services === demo)      // the destination realm was not activated
        XCTAssertTrue(demo.resetIncomplete)
        controller.realmLeave(thenDemo: false)
        await controller.waitForTransition()
        XCTAssertEqual(controller.state, .welcome)
        XCTAssertFalse(controller.services === demo)
        XCTAssertEqual(attempts, 2)
    }

    func testLeavingDemoLaunchedWithTheDemoFlagDoesNotReenterDemo() async {
        let flagged = LaunchOptions.parse(arguments: ["--ui-testing", "--demo"], debug: true)
        let controller = RealmController(options: flagged)
        await controller.boot()
        XCTAssertEqual(controller.state, .demo)
        controller.realmLeave(thenDemo: false)
        await controller.waitForTransition()
        XCTAssertEqual(controller.state, .welcome)
        XCTAssertFalse(controller.services.isDemo)
    }

    func testResetDemoDataKeepsTheDeviceLabelAndWaitsForTheSecondBoot() async {
        let controller = RealmController(options: options)
        await controller.boot()
        controller.realmEnterDemo()
        await controller.waitForTransition()
        controller.services.deviceLabel = "Severin's iPhone"
        let first = controller.services
        controller.realmLeave(thenDemo: true)
        await controller.waitForTransition()
        XCTAssertEqual(controller.state, .demo)          // the transition ended only after the second Demo boot
        XCTAssertFalse(controller.services === first)
        XCTAssertTrue(controller.services.isDemo)
        XCTAssertEqual(controller.services.deviceLabel, "Severin's iPhone")
        XCTAssertEqual(controller.services.demo?.deviceLabel, "Severin's iPhone")
    }

    func testLeaveRetiresShareTargetsSynchronouslyBeforeAnyAwait() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("realm-retire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let area = ShareArea(shareGroupRoot: root)
        let controller = RealmController(options: options)
        controller.shareArea = area
        await controller.boot()
        controller.realmEnterDemo()
        await controller.waitForTransition()
        try ShareTargetIndex.publish([ShareTarget(realm: "demo", ws: String(repeating: "a", count: 32), name: "Laptop", hue: 0, generation: 1)], to: area)
        XCTAssertEqual(try ShareTargetIndex.load(from: area).count, 1)
        controller.realmLeave(thenDemo: false)
        // No await has happened since the leave began: the extension already has no destination of the outgoing realm.
        XCTAssertThrowsError(try ShareTargetIndex.load(from: area))
        await controller.waitForTransition()
    }

    func testCapabilitiesAndRealmFollowTheAttachedRuntime() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let services = LiveServices(options: options, runtime: runtime)
        XCTAssertEqual(services.realm, .demo)
        XCTAssertTrue(services.isDemo)
        XCTAssertEqual(services.capabilities, .demo)
        services.exitDemo(); await services.waitForReset()
        XCTAssertNil(services.realm)
        XCTAssertFalse(services.isDemo)
        XCTAssertEqual(services.capabilities, .none)
    }
}
