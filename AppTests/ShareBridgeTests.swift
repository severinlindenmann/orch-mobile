import XCTest
import OrchCoordination
import OrchShareStaging
@testable import Orch

@MainActor
final class ShareBridgeTests: XCTestCase {
    private func make() throws -> (PreviewWorld, ShareBridge, ShareArea) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let world = PreviewWorld(demo: true)
        let bridge = try XCTUnwrap(ShareBridge.make(world: world, override: root, publishDemo: true))
        return (world, bridge, ShareArea(shareGroupRoot: root))
    }

    private func stageText(_ area: ShareArea, to id: String, generation: Int64 = 1) throws {
        let t = ShareTarget(realm: "demo", ws: ShareBridge.wsHex(id), name: id, hue: 0, generation: generation)
        let s = try StagingSession(area: area, target: t)
        try s.add(.text("hello")); try s.commit(note: "n")
    }

    func testTemporaryScopeLossDoesNotTombstoneAndPreservesRecovery() async throws {
        let (world, bridge, area) = try make()
        bridge.publishTargets()
        try stageText(area, to: "laptop")
        let destination = LiveDestination(realm: "demo", ws: ShareBridge.wsHex("laptop"), generation: 1)
        _ = ShareInbox(area: area).claim(live: [destination])
        let index = try XCTUnwrap(world.workspaces.firstIndex { $0.id == "laptop" })
        world.workspaces[index].scopes.remove(.operate)
        bridge.refresh(); await bridge.waitForRefresh()
        XCTAssertTrue(try area.coordination.records().isEmpty)
        XCTAssertEqual(ShareInbox(area: area).peekReady().count, 1)
        XCTAssertTrue(ShareInbox(area: area).quarantined().isEmpty)
        world.workspaces[index].scopes.insert(.operate)
        bridge.refresh(); await bridge.waitForRefresh()
        XCTAssertTrue(ShareInbox(area: area).peekReady().isEmpty)
        XCTAssertEqual(world.items(.sending).filter { $0.id.hasPrefix("share-") }.count, 2)
    }

    func testPublishedTargetsAreMinimalAndReadable() throws {
        let (_, bridge, area) = try make()
        bridge.publishTargets()
        let targets = try ShareTargetIndex.load(from: area)
        XCTAssertEqual(Set(targets.map(\.name)), ["Laptop"])
        XCTAssertTrue(targets.allSatisfy { $0.realm == "demo" && $0.generation == 1 })
    }

    func testClaimImportsIntoSendingAndDeletesPlaintext() async throws {
        let (world, bridge, area) = try make()
        bridge.publishTargets()
        try stageText(area, to: "laptop")
        bridge.refresh(); await bridge.waitForRefresh()
        let sent = world.items(.sending).filter { $0.id.hasPrefix("share-") }
        XCTAssertEqual(sent.count, 2)  // the text item and the note
        XCTAssertTrue(sent.allSatisfy { $0.workspaceID == "laptop" })
        XCTAssertEqual(sent.first { $0.kind == .note && $0.name == "Note" && $0.text == "n" } != nil, true)
        XCTAssertTrue(sent.allSatisfy { $0.id.count > "share-".count + 36 })   // keyed by the full job id
        XCTAssertTrue(ShareInbox(area: area).peekReady().isEmpty)
        bridge.refresh(); await bridge.waitForRefresh()  // idempotent
        XCTAssertEqual(world.items(.sending).filter { $0.id.hasPrefix("share-") }.count, 2)
    }

    func testLeavingAWorkspaceTombstonesAndPurgesItsJobs() async throws {
        let (world, bridge, area) = try make()
        bridge.publishTargets()
        try stageText(area, to: "client-vm")
        _ = await world.leave(workspaceID: "client-vm", simulateOffline: false)
        bridge.publishTargets()
        XCTAssertTrue(ShareInbox(area: area).peekReady().isEmpty)
        // A late writer for the removed generation is refused; the index no longer lists it.
        XCTAssertThrowsError(try StagingSession(area: area, target: ShareTarget(realm: "demo", ws: ShareBridge.wsHex("client-vm"), name: "x", hue: 0, generation: 1)).add(.text("late")))
        XCTAssertEqual(try ShareTargetIndex.load(from: area).map(\.name), ["Laptop"])
    }

    func testRemovedDestinationIsQuarantinedThenRedirectedByChoice() async throws {
        let (world, bridge, area) = try make()
        bridge.publishTargets()
        try stageText(area, to: "gone")
        bridge.refresh(); await bridge.waitForRefresh()
        let q = try XCTUnwrap(world.items(.sending).first { $0.quarantineJob != nil })
        XCTAssertTrue(world.items(.sending).filter { $0.id.hasPrefix("share-") && $0.quarantineJob == nil }.isEmpty)
        world.redirectQuarantined(id: q.id, to: "laptop")
        await bridge.waitForRefresh()
        XCTAssertNil(world.items(.sending).first { $0.quarantineJob != nil })
        XCTAssertTrue(world.items(.sending).contains { $0.id.hasPrefix("share-") && $0.workspaceID == "laptop" })
    }

    func testDemoWorkspacesAreOfferedAndNeverClaimedByALiveApp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        let world = PreviewWorld(demo: true)
        let bridge = try XCTUnwrap(ShareBridge.make(world: world, override: root))
        bridge.publishTargets()
        let offered = try ShareTargetIndex.load(from: ShareArea(shareGroupRoot: root))
        XCTAssertFalse(offered.isEmpty)
        XCTAssertTrue(offered.allSatisfy { $0.realm == "demo" })
        let withheld = try XCTUnwrap(ShareBridge.make(world: PreviewWorld(demo: true), override: root.appendingPathComponent("w"), publishDemo: false))
        withheld.publishTargets()
        XCTAssertThrowsError(try ShareTargetIndex.load(from: ShareArea(shareGroupRoot: root.appendingPathComponent("w"))))
        // A Demo-realm job staged anyway is neither claimed nor quarantined by a live-realm app; the stale Demo
        // destinations are retired (tombstoned), so the job is left unclaimed and nothing is imported.
        let live = PreviewWorld(demo: false)
        let liveBridge = try XCTUnwrap(ShareBridge.make(world: live, override: root))
        let area = ShareArea(shareGroupRoot: root)
        let t = ShareTarget(realm: "demo", ws: ShareBridge.wsHex("laptop"), name: "x", hue: 0, generation: 1)
        let s = try StagingSession(area: area, target: t)
        try s.add(.text("x")); try s.commit(note: nil)
        liveBridge.refresh(); await liveBridge.waitForRefresh()
        XCTAssertTrue(live.items(.sending).isEmpty)
        XCTAssertTrue(ShareInbox(area: area).quarantined().isEmpty)
        let tombstones = try area.coordination.records()
        XCTAssertTrue(tombstones.contains { $0.realm == "demo" && $0.ws == ShareBridge.wsHex("laptop") })
        XCTAssertFalse(tombstones.contains { $0.realm == "live" })
    }

    /// B1: live -> Demo -> live must keep the live destination (never tombstoned by Demo) and its staged job.
    func testDemoNeverTombstonesLiveDestinations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        let area = ShareArea(shareGroupRoot: root)
        let liveTarget = ShareTarget(realm: "live", ws: String(repeating: "a", count: 32), name: "Mac", hue: 1, generation: 4)
        try ShareTargetIndex.publish([liveTarget], to: area)
        let s = try StagingSession(area: area, target: liveTarget)
        try s.add(.text("keep me")); try s.commit(note: nil)
        // Demo cold start.
        let demo = try XCTUnwrap(ShareBridge.make(world: PreviewWorld(demo: true), override: root))
        demo.publishTargets()
        let offered = try ShareTargetIndex.load(from: area)
        XCTAssertTrue(offered.contains(liveTarget), "live destinations stay visible while Demo is active")
        XCTAssertTrue(offered.contains { $0.realm == "demo" })
        XCTAssertFalse(try area.coordination.records().contains { $0.realm == "live" })
        XCTAssertEqual(ShareInbox(area: area).peekReady().count, 1)
        // Back to live: the destination is still valid at its generation and the staged job survives.
        XCTAssertNotNil(try area.coordination.ifNotRemoved(realm: "live", ws: liveTarget.ws, generation: 4) { true })
        XCTAssertEqual(ShareInbox(area: area).peekReady().count, 1)
    }

    /// B5: the activation rule matches 1...5 items of data/url/text and not 6.
    func testActivationRuleBoundsItemCount() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let info = try XCTUnwrap(NSDictionary(contentsOf: plugins.appendingPathComponent("OrchShare.appex/Info.plist")))
        let rule = try XCTUnwrap(((info["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any])?["NSExtensionActivationRule"] as? String)
        let predicate = NSPredicate(format: rule)
        func items(_ types: [[String]]) -> NSDictionary {
            ["extensionItems": [["attachments": types.map { ["registeredTypeIdentifiers": $0] }]]]
        }
        XCTAssertTrue(predicate.evaluate(with: items([["public.jpeg", "public.image"]])))      // Photos image
        XCTAssertTrue(predicate.evaluate(with: items([["public.url"]])))                       // Safari link
        XCTAssertTrue(predicate.evaluate(with: items([["public.plain-text"]])))
        XCTAssertTrue(predicate.evaluate(with: items(Array(repeating: ["public.jpeg"], count: 5))))
        XCTAssertFalse(predicate.evaluate(with: items(Array(repeating: ["public.jpeg"], count: 6))))
        XCTAssertFalse(predicate.evaluate(with: items([])))
    }

    /// C2: tombstoning must succeed before a target stops being tracked.
    func testFailedTombstoneKeepsTheTargetAndRetries() async throws {
        let (world, bridge, area) = try make()
        bridge.publishTargets()
        let file = area.shareDir.appendingPathComponent("tombstones.json")
        try Data("{broken".utf8).write(to: file)   // the write now throws .corrupt
        _ = await world.leave(workspaceID: "client-vm", simulateOffline: false)
        // Leave itself must journal the unoffered workspace before the tombstone write fails.
        XCTAssertEqual(try bridge.inbox.pendingRemovals(), [
            TombstoneRecord(realm: "demo", ws: ShareBridge.wsHex("client-vm"), generation: 1)
        ])
        bridge.publishTargets()
        XCTAssertEqual(bridge.unfinishedRemovals, 1)
        XCTAssertTrue(world.workspaces.contains { $0.id == "client-vm" })
        // The failed removal is durable; unreadable coordination fails closed.
        XCTAssertFalse(((try? ShareTargetIndex.load(from: area)) ?? []).contains { $0.name == "Client VM" })
        try? FileManager.default.removeItem(at: file)
        let restarted = ShareBridge(area: area, world: world, publishDemo: true)
        restarted.publishTargets()
        XCTAssertEqual(restarted.unfinishedRemovals, 0)
        let records = try area.coordination.records()
        XCTAssertTrue(records.contains { $0.ws == ShareBridge.wsHex("client-vm") })
    }

    func testJournalFailureKeepsWorkspaceAndPersistedDestination() async throws {
        let (world, bridge, area) = try make()
        bridge.publishTargets()
        let indexBefore = try Data(contentsOf: area.targetsURL)
        try FileManager.default.createDirectory(at: area.shareDir.appendingPathComponent("pending-removals.json"),
                                                withIntermediateDirectories: false)
        _ = await world.leave(workspaceID: "client-vm", simulateOffline: false)
        bridge.publishTargets()
        XCTAssertTrue(world.workspaces.contains { $0.id == "client-vm" })
        XCTAssertEqual(try Data(contentsOf: area.targetsURL), indexBefore)
        XCTAssertTrue(try area.coordination.records().isEmpty)
    }

    /// C2: a failed purge is retried (the tombstone is the persisted cleanup record).
    func testFailedPurgeIsRetriedOnTheNextPass() async throws {
        let (world, bridge, area) = try make()
        bridge.publishTargets()
        try stageText(area, to: "client-vm")
        let wsDir = try area.stagingDir(realm: "demo", ws: ShareBridge.wsHex("client-vm"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: wsDir.path)
        _ = await world.leave(workspaceID: "client-vm", simulateOffline: false)
        bridge.publishTargets()
        XCTAssertEqual(bridge.unfinishedRemovals, 1)
        // The undeletable job directory is still there (its contents are already gone, so it is not importable).
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: wsDir.path))?.count, 1)
        XCTAssertTrue(ShareInbox(area: area).peekReady().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wsDir.path)
        bridge.publishTargets()
        XCTAssertEqual(bridge.lastPurge.failed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wsDir.path))
    }

    func testRecoveryReissuesAClaimedJobOnlyOnTheFirstPass() async throws {
        let (world, bridge, area) = try make()
        bridge.publishTargets()
        try stageText(area, to: "laptop")
        // Simulate a crash after the rename but before the import.
        let live: Set = [LiveDestination(realm: "demo", ws: ShareBridge.wsHex("laptop"), generation: 1)]
        XCTAssertEqual(ShareInbox(area: area).claim(live: live, realm: "demo").claimed.count, 1)
        bridge.refresh(); await bridge.waitForRefresh()   // first pass after launch: recovery imports it
        XCTAssertEqual(world.items(.sending).filter { $0.id.hasPrefix("share-") }.count, 2)
        XCTAssertTrue(ShareInbox(area: area).peekReady().isEmpty)
    }
}
