#if DEBUG
import XCTest
import OrchClient
import OrchFakeHost
@testable import Orch

/// The DEBUG hub home's model over the in-process fake hub (the checks themselves are in OrchKit: HubHomeTests).
@MainActor
final class HubHomeModelTests: XCTestCase {
    private func opened() async throws -> (HubHomeModel, HubRuntime, FakeHub) {
        let rt = HubRuntime.fake()
        await rt.pairFake()
        let m = HubHomeModel(runtime: rt)
        await m.open()
        return (m, rt, try XCTUnwrap(rt.fake))
    }

    func testOpenShowsTheHubsListsAndTheSwitcherNarrowsThem() async throws {
        let (m, _, _) = try await opened()
        XCTAssertTrue(m.isLive)
        XCTAssertEqual(m.snapshot?.workspaces.count, 3)
        XCTAssertEqual(m.rows.count, 5)
        m.selected = FakeHub.wsPlatform
        XCTAssertEqual(m.rows.map(\.itemID), [FakeHub.q1Item, "g1", FakeHub.q2Item])
        XCTAssertEqual(m.selectedWorkspace?.name, "Platform")
        m.selected = FakeHub.wsShared
        XCTAssertEqual(m.rows.map(\.summaryOnly), [false, true])
    }

    func testSigningCanBeEnabledOnlyFromALiveAnswerForAnOnlineWorkspace() async throws {
        let (m, _, hub) = try await opened()
        let q = try XCTUnwrap(m.rows.first { $0.itemID == FakeHub.q1Item })
        XCTAssertTrue(m.signEnabled(q))
        // B5: a selective summary is never signable; a shared item is signable only when its own f1 names exactly one target
        hub.seedSelective()
        await m.refresh()
        XCTAssertFalse(m.signEnabled(try XCTUnwrap(m.rows.first { $0.itemID == "s2" })), "a summary is never signable")
        let shared = try XCTUnwrap(m.rows.first { $0.itemID == FakeHub.sharedQuestionItem })
        await m.load(shared)
        guard case .detail(let d) = m.item else { return XCTFail("no detail: \(m.item)") }
        XCTAssertNil(d.decision, "a shared question is answered where it lives")
        await m.load(try XCTUnwrap(m.rows.first { $0.itemID == FakeHub.sharedNoF1Item }))
        guard case .detail(let n) = m.item else { return XCTFail("no detail: \(m.item)") }
        XCTAssertNil(n.decision, "shared without f1: nothing to sign")
        hub.faults.down = true
        await m.refresh()
        XCTAssertFalse(m.isLive)
        XCTAssertEqual(m.snapshot?.workspaces.count, 3, "the cache is shown")
        XCTAssertFalse(m.signEnabled(q), "a cached row never enables signing")
        XCTAssertFalse(m.signEnabled(shared), "nor a cached shared item")
    }

    func testAnItemLoadsOnlyWhileTheHubAnswers() async throws {
        let (m, _, hub) = try await opened()
        let q = try XCTUnwrap(m.rows.first { $0.itemID == FakeHub.q1Item })
        await m.load(q)
        guard case .detail(let d) = m.item else { return XCTFail("no detail: \(m.item)") }
        XCTAssertEqual(d.row.itemID, FakeHub.q1Item)
        hub.faults.down = true
        await m.refresh()
        await m.load(q)
        XCTAssertEqual(m.item, .offline)
    }

    func testARevokeEndsTheViewAndKeepsNoRows() async throws {
        let (m, _, hub) = try await opened()
        hub.faults.channelAnswer = "channel_revoked"
        await m.refresh()
        XCTAssertEqual(m.state, .revoked)
        XCTAssertNil(m.snapshot)
        XCTAssertTrue(m.rows.isEmpty)
    }

    func testARevokeFromTheHubWipesThePairingAndPairAgainStartsClean() async throws {
        let (m, rt, hub) = try await opened()
        hub.faults.channelAnswer = "channel_revoked"
        await m.refresh()
        XCTAssertEqual(m.state, .revoked)
        XCTAssertTrue(try rt.custody.pairedHubs().isEmpty, "the hub's own answer wiped the pairing")
        XCTAssertFalse(rt.wipe.pending)
        let ready = await m.pairAgain()
        XCTAssertTrue(ready)
        XCTAssertEqual(m.state, .notPaired)
    }

    func testLeaveRevokesAtTheHubAndWipesThisPhone() async throws {
        let (m, rt, hub) = try await opened()
        await m.leave()
        XCTAssertEqual(m.state, .notPaired)
        XCTAssertEqual(hub.revokedChannels.count, 1)
        XCTAssertTrue(try rt.custody.pairedHubs().isEmpty)
        XCTAssertNil(m.snapshot)
        XCTAssertTrue(try XCTUnwrap(m.leaveNotice).contains("removed"))
    }

    func testLeaveWithTheHubDownStillWipesAndTellsThePersonToAskTheAdmin() async throws {
        let (m, rt, hub) = try await opened()
        hub.faults.down = true
        await m.leave()
        XCTAssertEqual(m.state, .notPaired)
        XCTAssertTrue(try rt.custody.pairedHubs().isEmpty)
        XCTAssertTrue(try XCTUnwrap(m.leaveNotice).contains("ask your hub admin"))
    }

    func testTheSelectionResetsWhenTheWorkspaceIsGone() async throws {
        let (m, _, hub) = try await opened()
        m.selected = FakeHub.wsShared
        hub.workspaceRows.removeLast()
        hub.needsYouRows.removeLast(2)
        await m.refresh()
        XCTAssertNil(m.selected)
    }
}
#endif
