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

    @Test func cutOverSwitchesOffOnlyThatWorkspaceAndNotifiesOnce() async {
        let f = Self.flag(paired: [Self.ws, Self.other])
        let seen = NSLockedBox()
        f.onSwitchedOff { seen.add($0) }
        await f.noteCutOver(workspace: Self.ws)
        await f.noteCutOver(workspace: Self.ws)
        #expect(!f.isEnabled(workspace: Self.ws))
        #expect(f.decision(workspace: Self.ws) == .usesHub)
        #expect(f.isEnabled(workspace: Self.other))
        #expect(seen.items == [Self.ws])
        await f.noteCutOver(workspace: "not-a-workspace")
        #expect(f.closedWorkspaces == [Self.ws])
    }

    static func flag(paired: Set<String>, store: any DirectPathStore = InMemoryDirectPathStore()) -> DirectPathFlag {
        let f = DirectPathFlag(store: store)
        f.setPairedCheck { paired.contains($0) }
        return f
    }

    @Test func onlyPairedWorkspacesCanBeSwitchedOffAndTheSetIsBounded() async {
        let none = DirectPathFlag()                                  // no paired check: fail closed
        await none.noteCutOver(workspace: Self.ws)
        #expect(none.closedWorkspaces.isEmpty)
        let f = Self.flag(paired: [Self.ws])
        await f.noteCutOver(workspace: Self.other)                   // a hostile relay names a workspace this phone does not have
        #expect(f.closedWorkspaces.isEmpty)
        let many = DirectPathFlag(); many.setPairedCheck { _ in true }
        for i in 0..<(DirectPathFlag.maxClosed + 20) { await many.noteCutOver(workspace: String(format: "%032x", i)) }
        #expect(many.closedWorkspaces.count == DirectPathFlag.maxClosed)
    }

    @Test func reenableTurnsItBackOnAndTheNextCutOverSwitchesItOffAgain() async {
        let f = Self.flag(paired: [Self.ws])
        await f.noteCutOver(workspace: Self.ws)
        f.reenable(workspace: Self.ws)
        #expect(f.isEnabled(workspace: Self.ws))
        await f.noteCutOver(workspace: Self.ws)
        #expect(!f.isEnabled(workspace: Self.ws))
    }

    @Test func offStateSurvivesARestartWithTheRealUserDefaultsStore() async throws {
        let name = "orch.test.directpath." + UUID().uuidString
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        let f = Self.flag(paired: [Self.ws], store: UserDefaultsDirectPathStore(defaults: d))
        await f.noteCutOver(workspace: Self.ws)
        let restarted = DirectPathFlag(store: UserDefaultsDirectPathStore(defaults: UserDefaults(suiteName: name)!))
        #expect(!restarted.isEnabled(workspace: Self.ws))
        #expect(restarted.isEnabled(workspace: Self.other))
        restarted.reenable(workspace: Self.ws)
        #expect(DirectPathFlag(store: UserDefaultsDirectPathStore(defaults: UserDefaults(suiteName: name)!)).isEnabled(workspace: Self.ws))
    }

    @Test func refusesNewDirectPairingForFullHubModeAndForCutOverWorkspaces() async {
        let f = Self.flag(paired: [Self.other])
        #expect(f.admitPairing(workspace: Self.ws, cardHubMode: .full) == .usesHub)
        await f.noteCutOver(workspace: Self.other)
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

    final class FixedSender: RequestSender, InProcessDemoSender, @unchecked Sendable {
        let origin: String
        let status: Int
        private let lock = NSLock(); private var n = 0
        init(origin: String, status: Int) { self.origin = origin; self.status = status }
        var count: Int { lock.withLock { n } }
        func send(_ request: WireRequest) async throws -> WireReply {
            lock.withLock { n += 1 }
            return try WireReply(status: status, headers: [:], body: Data(#"{"error":"cut_over"}"#.utf8))
        }
    }

    @Test func transportSwitchesTheFlagOffOnA403CutOverOfAnyWorkspaceRoute() async throws {
        let flag = Self.flag(paired: [Self.ws, Self.other])
        let ctx = try RealmContext.live(origin: "https://relay.example.org")
        let t = try RoutedRelayTransport(context: ctx, origin: ctx.origin, sender: FixedSender(origin: ctx.origin, status: 403),
                                         clientAddress: "198.51.100.1", directPath: flag)
        let route = PairRoute(workspaceID: ID16(hex: Self.ws)!, offerID: ID16.random(), requestID: ID16.random())
        _ = try await t.pairingPoll(route: route, after: nil, wait: nil)
        #expect(flag.decision(workspace: Self.ws) == .usesHub)
        #expect(flag.isEnabled(workspace: Self.other))
        // a non-poll route (a bridge post) is gated the same way
        let bridge = BridgeRoute(workspaceID: ID16(hex: Self.other)!, requestID: ID16.random())
        _ = try await t.bridgePost(Data([1]), route: bridge, session: RelaySession(token: "tok"))
        #expect(flag.decision(workspace: Self.other) == .usesHub)
    }

    @Test func aNon403OrUnpairedWorkspaceDoesNotSwitchOff() async throws {
        let flag = Self.flag(paired: [Self.ws])
        let ctx = try RealmContext.live(origin: "https://relay.example.org")
        let t200 = try RoutedRelayTransport(context: ctx, origin: ctx.origin, sender: FixedSender(origin: ctx.origin, status: 409),
                                            clientAddress: "a", directPath: flag)
        let route = PairRoute(workspaceID: ID16(hex: Self.ws)!, offerID: ID16.random(), requestID: ID16.random())
        _ = try await t200.pairingPoll(route: route, after: nil, wait: nil)
        #expect(flag.isEnabled(workspace: Self.ws))
    }

    @Test func coordinatorRefusesFullModeAndSendsZeroRequests() async throws {
        let h = try await PairHarness.make(.firstTime)
        let link = try h.link(try await h.rig.newOffer())
        let counting = FixedSender(origin: h.relay.origin, status: 200)
        var config = h.config
        config.transport = try RoutedRelayTransport(context: h.env.context, origin: h.relay.origin, sender: counting, clientAddress: "p")
        config.directPath = DirectPathFlag()
        let s = await PairingCoordinator(config).start(link: link, cardHubMode: .full)
        #expect(s == .failed(.usesHub))
        #expect(counting.count == 0)
        #expect(try await config.index.pairing(ws: link.workspace.hex) == nil)
        // a cut-over workspace (known to the flag) is refused the same way without a card mode
        let flag = Self.flag(paired: [link.workspace.hex])
        await flag.noteCutOver(workspace: link.workspace.hex)
        config.directPath = flag
        #expect(await PairingCoordinator(config).start(link: link) == .failed(.usesHub))
        #expect(counting.count == 0)
        // direct mode (selective / no hub) is not refused by the flag
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
