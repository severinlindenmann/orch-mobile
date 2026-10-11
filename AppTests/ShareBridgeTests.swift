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

    func testDemoWorkspacesAreNotOfferedToTheExtensionByDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        let world = PreviewWorld(demo: true)
        let bridge = try XCTUnwrap(ShareBridge.make(world: world, override: root))
        bridge.publishTargets()
        XCTAssertThrowsError(try ShareTargetIndex.load(from: ShareArea(shareGroupRoot: root)))
        // A Demo-realm job staged anyway is neither claimed nor quarantined by a live-realm app.
        let live = PreviewWorld(demo: false)
        let liveBridge = try XCTUnwrap(ShareBridge.make(world: live, override: root))
        let t = ShareTarget(realm: "demo", ws: ShareBridge.wsHex("laptop"), name: "x", hue: 0, generation: 1)
        let s = try StagingSession(area: ShareArea(shareGroupRoot: root), target: t)
        try s.add(.text("x")); try s.commit(note: nil)
        liveBridge.refresh(); await liveBridge.waitForRefresh()
        XCTAssertEqual(ShareInbox(area: ShareArea(shareGroupRoot: root)).peekReady().count, 1)
        XCTAssertTrue(live.items(.sending).isEmpty)
    }

    /// C2: tombstoning must succeed before a target stops being tracked.
    func testFailedTombstoneKeepsTheTargetAndRetries() async throws {
        let (world, bridge, area) = try make()
        bridge.publishTargets()
        let file = area.shareDir.appendingPathComponent("tombstones.json")
        try Data("{broken".utf8).write(to: file)   // the write now throws .corrupt
        _ = await world.leave(workspaceID: "client-vm", simulateOffline: false)
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
