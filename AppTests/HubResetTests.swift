import XCTest
import OrchClient
import OrchCustody
import OrchPush
@testable import Orch

/// Reset this iPhone removes the hub pairing and the hub's cache as part of the resumable reset (B6; L2-B1d-1, L2-B2-4).
@MainActor
final class HubResetTests: XCTestCase {
    private let hub = String(repeating: "ab", count: 16)

    private struct Stores {
        let backend = InMemoryVaultBackend()
        let cache = InMemoryHubCache()
        let journal = InMemoryHubWipeJournal()
        var custody: HubKeyCustody {
            HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        }
        func wipe(steps: [HubWipeStep] = []) -> HubWipe { HubWipe(custody: custody, cache: cache, journal: journal, steps: steps) }
    }

    private func pairedStores() throws -> Stores {
        let s = Stores()
        _ = try s.custody.createChannelKey(hubID: hub)
        _ = try s.custody.createPushKey(hubID: hub)
        try s.custody.putSessionToken("tok", hubID: hub)
        try s.custody.putRecord(Data("r".utf8), hubID: hub)
        try s.cache.write(Data("{}".utf8), hubID: hub)
        return s
    }

    private func services(_ wipe: HubWipe, flags given: UserDefaults? = nil) throws -> LiveServices {
        let flags = try given ?? XCTUnwrap(UserDefaults(suiteName: "orch.tests.hubreset." + UUID().uuidString))
        let s = LiveServices(options: .parse(arguments: ["--ui-testing"], debug: true), resetFlags: flags)
        s.hubWipe = wipe
        return s
    }

    func testResetWipesTheHubKeysTokenRecordAndCache() async throws {
        let st = try pairedStores()
        let s = try services(st.wipe())
        s.resetThisiPhone()
        XCTAssertTrue(st.journal.read() != nil, "the intent is durable before anything is awaited")
        await s.waitForReset()
        XCTAssertFalse(s.resetIncomplete)
        XCTAssertTrue(try st.custody.pairedHubs().isEmpty)
        XCTAssertTrue(try SecretVault(group: .keys, backend: st.backend).ids().isEmpty && SecretVault(group: .push, backend: st.backend).ids().isEmpty)
        XCTAssertTrue(st.cache.hubIDs.isEmpty)
        XCTAssertNil(st.journal.read())
    }

    func testAHubWipeThatFailsLeavesTheResetIncompleteAndTheNextLaunchFinishesIt() async throws {
        let st = try pairedStores()
        let failing = HubWipeStepOnce()
        let s = try services(st.wipe(steps: [{ _ in try failing.run() }]))
        s.resetThisiPhone()
        await s.waitForReset()
        XCTAssertTrue(s.resetIncomplete, "a reset whose hub wipe did not finish is not reported as done")
        XCTAssertNotNil(st.journal.read())
        // the next launch (a new process: new wipe object, same journal and stores) finishes it before any realm starts
        let next = try services(st.wipe())
        await next.boot()
        XCTAssertFalse(next.resetIncomplete)
        XCTAssertTrue(try st.custody.pairedHubs().isEmpty && st.cache.hubIDs.isEmpty)
        XCTAssertNil(st.journal.read())
    }

    func testAFailedIntentWriteIsNeverReportedAsAFinishedReset() async throws {
        let st = try pairedStores()
        let journal = FlakyJournal(failures: 2)            // the Reset's own begin AND the reset task's retry fail
        let flaky = HubWipe(custody: st.custody, cache: st.cache, journal: journal)
        let s = try services(flaky)
        s.resetThisiPhone()
        await s.waitForReset()
        XCTAssertTrue(s.resetIncomplete, "no intent, no wipe: not a finished Reset")
        XCTAssertEqual(try st.custody.pairedHubs(), [hub], "the keys survived, and the app says so")
        // the sticky flag makes the next launch run the wipe (a journal that works now)
        let next = try services(st.wipe(), flags: s.cleanupDefaults)
        await next.boot()
        XCTAssertFalse(next.resetIncomplete)
        XCTAssertTrue(try st.custody.pairedHubs().isEmpty && SecretVault(group: .keys, backend: st.backend).ids().isEmpty)
        XCTAssertTrue(st.cache.hubIDs.isEmpty)
    }

    func testAFailedHubOnlyWipeAtLaunchNeverLocksTheDirectRealms() async throws {
        let st = try pairedStores()
        try st.journal.write(HubWipeIntent(scope: .hub(hub), phase: 0))
        let s = try services(st.wipe(steps: [{ _ in throw CocoaError(.fileWriteUnknown) }]))
        await s.boot()
        XCTAssertFalse(s.resetIncomplete)
        XCTAssertNotNil(st.journal.read(), "still pending for the hub home to retry")
    }

    func testOnlyTheFixedHubHintLinesAreRemovedFromDeliveredNotifications() {
        XCTAssertTrue(HubStorage.isHubHint(body: "A signature request is waiting"))
        XCTAssertTrue(HubStorage.isHubHint(body: "Something needs you"))
        XCTAssertFalse(HubStorage.isHubHint(body: "Alice replied on PLAT-12"))
    }

    func testResetStepsClearTheHubReplayFolderAndTheCounter() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hubreset-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = dir.appendingPathComponent("state/hub/\(hub)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: state.appendingPathComponent("replay.0.json"))
        let st = try pairedStores()
        try st.custody.putPushState(HubPushState(issuedMs: 5, keyRegistered: true), hubID: hub)
        let wipe = st.wipe(steps: [{ _ in HubPushIntake(pushDir: dir).purgeAll() }])
        try await wipe.wipe(.everything)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("state/hub").path))
        XCTAssertNil(try st.custody.pushState(hubID: hub))
    }

    func testALaunchWithNothingPendingTouchesNothing() async throws {
        let st = try pairedStores()
        let s = try services(st.wipe())
        await s.boot()
        XCTAssertFalse(s.resetIncomplete)
        XCTAssertEqual(try st.custody.pairedHubs(), [hub])
        XCTAssertEqual(st.cache.hubIDs, [hub])
    }
}

private final class HubWipeStepOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run() throws {
        let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
        if first { throw CocoaError(.fileWriteUnknown) }
    }
}

private final class FlakyJournal: HubWipeJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Int
    private var intent: HubWipeIntent?
    init(failures: Int) { self.failures = failures }
    func read() -> HubWipeIntent? { lock.withLock { intent } }
    func write(_ i: HubWipeIntent) throws {
        try lock.withLock {
            if failures > 0 { failures -= 1; throw CocoaError(.fileWriteUnknown) }
            intent = i
        }
    }
    func clear() { lock.withLock { intent = nil } }
}
