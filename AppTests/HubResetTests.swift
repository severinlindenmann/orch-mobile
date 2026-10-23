import XCTest
import OrchClient
import OrchCustody
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

    private func services(_ wipe: HubWipe) throws -> LiveServices {
        let flags = try XCTUnwrap(UserDefaults(suiteName: "orch.tests.hubreset." + UUID().uuidString))
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
