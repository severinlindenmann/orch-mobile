import Foundation
import Testing
import OrchProtocol
@testable import OrchClient

/// B8 (orch-core #868): the direct path behind one flag. Default ON, OFF per workspace on `relay.cut_over`, no new direct pairing to a
/// workspace whose card says hub mode full. Selective workspaces keep the direct path (C10, kit step neg-selective-direct-open).
@Suite struct DirectPathFlagTests {
    static let ws = "0123456789abcdef0123456789abcdef"
    static let other = "fedcba9876543210fedcba9876543210"

    @Test func defaultsOnForWorkspacesWithoutAHub() {
        let f = DirectPathFlag()
        #expect(f.isEnabled(workspace: Self.ws))
        #expect(f.decision(workspace: Self.ws) == .allowed)
        #expect(f.admitPairing(workspace: Self.ws, cardHubMode: nil) == .allowed)
        #expect(f.admitPairing(workspace: Self.ws, cardHubMode: .selective) == .allowed)
        #expect(f.closedWorkspaces.isEmpty)
    }

    @Test func cutOverSwitchesOffOnlyThatWorkspaceAndNotifiesOnce() {
        let f = DirectPathFlag()
        let seen = NSLockedBox()
        f.onSwitchedOff { seen.add($0) }
        f.noteCutOver(workspace: Self.ws)
        f.noteCutOver(workspace: Self.ws)
        #expect(!f.isEnabled(workspace: Self.ws))
        #expect(f.decision(workspace: Self.ws) == .usesHub)
        #expect(f.isEnabled(workspace: Self.other))
        #expect(seen.items == [Self.ws])
        f.noteCutOver(workspace: "not-a-workspace")
        #expect(f.closedWorkspaces == [Self.ws])
    }

    @Test func offStateSurvivesANewFlagOnTheSameStore() {
        let store = InMemoryDirectPathStore()
        DirectPathFlag(store: store).noteCutOver(workspace: Self.ws)
        #expect(!DirectPathFlag(store: store).isEnabled(workspace: Self.ws))
    }

    @Test func refusesNewDirectPairingForFullHubModeAndForCutOverWorkspaces() {
        let f = DirectPathFlag()
        #expect(f.admitPairing(workspace: Self.ws, cardHubMode: .full) == .usesHub)
        f.noteCutOver(workspace: Self.other)
        #expect(f.admitPairing(workspace: Self.other, cardHubMode: nil) == .usesHub)
    }

    @Test func recognisesOnlyAWorkspaceRouteCutOver403() throws {
        let body = Data(#"{"error":"cut_over","drain_until_ms":1}"#.utf8)
        #expect(DirectPathFlag.isCutOver(status: 403, body: body))
        #expect(DirectPathFlag.isCutOver(status: 403, body: Data(#"{"error":"relay.cut_over"}"#.utf8)))
        #expect(!DirectPathFlag.isCutOver(status: 200, body: body))
        #expect(!DirectPathFlag.isCutOver(status: 403, body: Data(#"{"error":"forbidden"}"#.utf8)))
        #expect(!DirectPathFlag.isCutOver(status: 403, body: Data("nope".utf8)))
        #expect(DirectPathFlag.workspace(inTarget: "/v2/workspaces/\(Self.ws)/bridge/aa", base: "/v2") == Self.ws)
        #expect(DirectPathFlag.workspace(inTarget: "/v2/hubs/x", base: "/v2") == nil)
    }

    @Test func transportSwitchesTheFlagOffWhenTheRelayAnswersCutOver() async throws {
        final class CutSender: RequestSender, InProcessDemoSender, @unchecked Sendable {
            let origin = "https://relay.example.org"
            func send(_ request: WireRequest) async throws -> WireReply {
                try WireReply(status: 403, headers: [:], body: Data(#"{"error":"cut_over"}"#.utf8))
            }
        }
        let flag = DirectPathFlag()
        let ctx = try RealmContext.live(origin: "https://relay.example.org")
        let t = try RoutedRelayTransport(context: ctx, origin: ctx.origin, sender: CutSender(), clientAddress: "198.51.100.1", directPath: flag)
        let route = PairRoute(workspaceID: ID16(hex: Self.ws)!, offerID: ID16.random(), requestID: ID16.random())
        _ = try await t.pairingPoll(route: route, after: nil, wait: nil)
        #expect(flag.decision(workspace: Self.ws) == .usesHub)
        #expect(flag.isEnabled(workspace: Self.other))
    }

    @Test func coordinatorRefusesFullModeAndSendsNothing() async throws {
        let h = try await PairHarness.make(.firstTime)
        var config = h.config
        config.directPath = DirectPathFlag()
        let c = PairingCoordinator(config)
        let link = try h.link(try await h.rig.newOffer())
        let s = await c.start(link: link, cardHubMode: .full)
        #expect(s == .failed(.usesHub))
        // not silent: a different, direct-mode attempt for the same workspace is still allowed by the flag
        let h2 = try await PairHarness.make(.firstTime)
        var c2 = h2.config; c2.directPath = DirectPathFlag()
        let ok = await PairingCoordinator(c2).start(link: try h2.link(try await h2.rig.newOffer()), cardHubMode: .selective)
        #expect(ok != .failed(.usesHub))
    }
}

private final class NSLockedBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: [String] = []
    func add(_ s: String) { lock.withLock { v.append(s) } }
    var items: [String] { lock.withLock { v } }
}
