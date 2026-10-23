import Foundation
import OrchCustody
import OrchFakeHost
import OrchProtocol
import Testing
@testable import OrchClient

private final class Clock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64 = 1_790_000_000_000
    var nowMs: Int64 { lock.withLock { ms } }
    func advance(hours: Int64) { lock.withLock { ms += hours * 3_600_000 } }
}

/// Holds the first request whose target equals `path` until released.
private final class HoldSender: RequestSender, @unchecked Sendable {
    let inner: FakeHub
    let path: String
    private let lock = NSLock()
    private var held: CheckedContinuation<Void, Never>?
    private var done = false
    private var arrived: CheckedContinuation<Void, Never>?
    private var hasArrived = false
    var origin: String { inner.origin }
    init(_ inner: FakeHub, path: String) { self.inner = inner; self.path = path }
    func waitUntilHeld() async {
        await withCheckedContinuation { c in
            let go = lock.withLock { () -> Bool in if hasArrived { return true }; arrived = c; return false }
            if go { c.resume() }
        }
    }
    func release() {
        let c: CheckedContinuation<Void, Never>? = lock.withLock { done = true; let c = held; held = nil; return c }
        c?.resume()
    }
    func send(_ request: WireRequest) async throws -> WireReply {
        if request.target == path {
            let first = lock.withLock { () -> Bool in if hasArrived { return false }; hasArrived = true; return true }
            if first {
                let a = lock.withLock { () -> CheckedContinuation<Void, Never>? in let a = arrived; arrived = nil; return a }
                a?.resume()
                await withCheckedContinuation { c in
                    let go = lock.withLock { () -> Bool in if done { return true }; held = c; return false }
                    if go { c.resume() }
                }
            }
        }
        return try await inner.send(request)
    }
}

private final class OriginLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ o: String) { lock.withLock { items.append(o) } }
    var all: [String] { lock.withLock { items } }
}

private struct Rig {
    let hub: FakeHub
    let clock = Clock()
    let backend = InMemoryVaultBackend()
    let custody: HubKeyCustody
    let cache = InMemoryHubCache()
    let home: HubHomeCoordinator

    init(paired: Bool = true, seed: Bool = true, home makeHome: ((HubKeyCustody, InMemoryHubCache, Clock, FakeHub) -> HubHomeCoordinator)? = nil) async {
        let clock = self.clock
        let h = FakeHub(origin: "https://hub.dev.orch.example", wall: clock)
        hub = h
        if seed { h.seedHome() }
        custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        home = makeHome?(custody, cache, clock, h) ?? Rig.makeHome(custody, cache, clock, h)
        if paired {
            let pairing = HubPairingCoordinator(Rig.pairingConfig(custody, clock, h))
            _ = await pairing.begin(link: h.pairingLink)
            let r = await pairing.complete(password: h.password, totp: h.totp, label: "Dev hub")
            guard case .paired = r else { fatalError("rig could not pair: \(r)") }
        }
    }

    static func pairingConfig(_ c: HubKeyCustody, _ clock: Clock, _ h: FakeHub) -> HubPairingConfig {
        HubPairingConfig(custody: c, verifier: HubVerifier(devMode: true), wall: clock, makeSender: { o in guard o == h.origin else { throw TransportError.disconnected }; return h })
    }

    static func makeHome(_ c: HubKeyCustody, _ cache: any HubCacheStore, _ clock: Clock, _ h: FakeHub) -> HubHomeCoordinator {
        HubHomeCoordinator(custody: c, cache: cache, verifier: HubVerifier(devMode: true), wall: clock,
                           makeSender: { o in guard o == h.origin else { throw TransportError.disconnected }; return h })
    }
}

private func live(_ s: HubHomeState) -> HubSnapshot? { if case .live(let x) = s { return x }; return nil }
private func offline(_ s: HubHomeState) -> HubSnapshot?? { if case .offline(let x) = s { return .some(x) }; return nil }

@Suite struct HubHomeTests {
    @Test func notPairedUntilThereIsARecord() async {
        let r = await Rig(paired: false)
        #expect(await r.home.refresh() == .notPaired)
        #expect(await r.home.restore() == .notPaired)
        #expect(r.hub.log.isEmpty)
    }

    @Test func liveListsComeFromTheHubThroughTheChannelSession() async throws {
        let r = await Rig()
        let before = r.hub.log.count
        let snap = try #require(live(await r.home.refresh()))
        #expect(snap.workspaces.map(\.name) == ["Platform", "Billing", "Acme (shared)"])
        #expect(snap.workspaces[1].online == false && snap.workspaces[2].mode == .selective && snap.workspaces[2].hubReads == "shared items and summaries")
        #expect(snap.needsYou.rows.count == 4 && snap.needsYou.offline == [FakeHub.wsBilling])
        #expect(Array(r.hub.log.dropFirst(before)) == ["GET /api/v1/me/workspaces", "GET /api/v1/me/needs-you"])
        // the bearer is the channel session's, and every request went to the hub the pairing named
        let auth = r.hub.seenAuthorizations.suffix(2)
        #expect(auth.allSatisfy { $0 == "Bearer FAKE-HUB-CHANNEL-3" || $0.hasPrefix("Bearer FAKE-HUB-CHANNEL-") })
        #expect(snap.rows(in: FakeHub.wsPlatform).count == 2)
        #expect(r.cache.hubIDs == [r.hub.hubID])
    }

    @Test func selectiveRowsAreNeverSignableAndNeedsYouIsSummaryOnly() async throws {
        let r = await Rig()
        r.hub.needsYouRows[2] = FakeHub.needsRow(ws: FakeHub.wsShared, mode: "selective", item: "s1", kind: "ticket", title: "x", signable: true)
        let snap = try #require(live(await r.home.refresh()))
        let shared = snap.rows(in: FakeHub.wsShared)
        #expect(shared.map(\.signable) == [false, false])
        #expect(shared.map(\.summaryOnly) == [false, true])
        // a needs_you row whose hub flag says "not summary" is still a summary on the phone
        r.hub.needsYouRows[3] = FakeHub.needsRow(ws: FakeHub.wsShared, mode: "selective", item: "s2", kind: "needs_you", title: "y", summaryOnly: false)
        let again = try #require(live(await r.home.refresh()))
        #expect(again.rows(in: FakeHub.wsShared)[1].summaryOnly)
    }

    @Test func aPausedWorkspaceIsNeverSignable() async throws {
        let r = await Rig()
        r.hub.needsYouRows.append(FakeHub.needsRow(ws: FakeHub.wsBilling, item: "b1", kind: "gate", title: "Approve", signable: true))
        let snap = try #require(live(await r.home.refresh()))
        #expect(snap.rows(in: FakeHub.wsBilling).map(\.signable) == [false])
        #expect(snap.rows(in: FakeHub.wsPlatform).map(\.signable) == [true, true])   // the hub's hint, enabling only
    }

    @Test func rowsOfUnknownWorkspacesOrOtherModesAreDropped() async throws {
        let r = await Rig()
        r.hub.needsYouRows.append(FakeHub.needsRow(ws: String(repeating: "dd", count: 16), item: "x1", kind: "question", title: "stranger"))
        r.hub.needsYouRows.append(FakeHub.needsRow(ws: FakeHub.wsPlatform, mode: "selective", item: "x2", kind: "ticket", title: "wrong mode"))
        r.hub.needsYouRows.append(FakeHub.needsRow(ws: FakeHub.wsShared, mode: "selective", item: "x3", kind: "gate", title: "not a shared kind"))
        let snap = try #require(live(await r.home.refresh()))
        #expect(snap.needsYou.rows.count == 4)
    }

    @Test func textFromTheHubIsRenderedAgain() async throws {
        let r = await Rig()
        r.hub.needsYouRows[0] = FakeHub.needsRow(ws: FakeHub.wsPlatform, item: "q1", kind: "question", title: "Approve \u{202E}payroll\u{202C} now")
        r.hub.workspaceRows[0] = FakeHub.workspaceRow(id: FakeHub.wsPlatform, name: "Plat\u{3164}form", mode: "full", role: "edit", online: true)
        let snap = try #require(live(await r.home.refresh()))
        #expect(snap.needsYou.rows[0].title == "Approve <U+202E>payroll<U+202C> now")
        #expect(snap.workspaces[0].name == "Plat<U+3164>form")
    }

    @Test func offlineShowsTheCacheReadOnlyAndNeverAsLive() async throws {
        let r = await Rig()
        let snap = try #require(live(await r.home.refresh()))
        r.hub.faults.down = true
        r.clock.advance(hours: 1)
        let s = await r.home.refresh()
        #expect(s == .offline(snap))
        #expect(live(s) == nil)
        // a fresh process (new coordinator, same cache) restores the same read-only view without asking the hub
        let again = Rig.makeHome(r.custody, r.cache, r.clock, r.hub)
        #expect(await again.restore() == .offline(snap))
        // an item is not shown from the cache
        #expect(await r.home.item(workspaceID: FakeHub.wsPlatform, itemID: "q1") == .offline)
    }

    @Test func offlineWithoutACacheIsEmptyAndReadOnly() async {
        let r = await Rig()
        r.hub.faults.down = true
        #expect(await r.home.refresh() == .offline(nil))
        #expect(await r.home.restore() == .offline(nil))
    }

    @Test func aGarbledAnswerKeepsTheCacheButIsNotLive() async throws {
        let r = await Rig()
        let snap = try #require(live(await r.home.refresh()))
        r.hub.faults.garbledLists = true
        #expect(await r.home.refresh() == .offline(snap))
        r.hub.faults.garbledLists = false
        r.hub.needsYouRows.append(.object(["workspace_id": .string(FakeHub.wsPlatform)]))
        #expect(await r.home.refresh() == .offline(snap))
    }

    @Test func anExpiredSessionDropsTheCacheAndAsksForASignIn() async throws {
        let r = await Rig()
        _ = try #require(live(await r.home.refresh()))
        #expect(r.cache.hubIDs.count == 1)
        r.clock.advance(hours: 13)
        r.hub.faults.down = true     // even with the hub unreachable: nothing is kept after the session ended
        #expect(await r.home.refresh() == .signedOut)
        #expect(r.cache.hubIDs.isEmpty)
        #expect(await Rig.makeHome(r.custody, r.cache, r.clock, r.hub).restore() == .signedOut)
    }

    @Test func noSessionFromTheHubDropsTheCache() async throws {
        let r = await Rig()
        _ = try #require(live(await r.home.refresh()))
        r.hub.faults.channelAnswer = "no_session"
        #expect(await r.home.refresh() == .signedOut)
        #expect(r.cache.hubIDs.isEmpty)
    }

    @Test(arguments: ["channel_revoked", "cert_expired"]) func aRevokeFromTheHubDropsTheCache(code: String) async throws {
        let r = await Rig()
        _ = try #require(live(await r.home.refresh()))
        r.hub.faults.channelAnswer = code
        #expect(await r.home.refresh() == .revoked)
        #expect(r.cache.hubIDs.isEmpty)
        // nothing was wiped here (that is B6): the pairing record is still there
        #expect(try r.custody.pairedHubs().count == 1)
    }

    @Test func otherRefusalsKeepTheCacheReadOnly() async throws {
        let r = await Rig()
        let snap = try #require(live(await r.home.refresh()))
        r.hub.faults.channelAnswer = "unavailable"
        #expect(await r.home.refresh() == .offline(snap))
    }

    // MARK: relay channel_revoked (L2B-2)

    @Test func aRelayRevokeDropsTheCacheAtOnceThenTheHubDecides() async throws {
        let r = await Rig()
        let snap = try #require(live(await r.home.refresh()))
        // hub unreachable: read-only and WITHOUT the cache; nothing is wiped
        r.hub.faults.down = true
        #expect(await r.home.relayReportsRevoked() == .offline(nil))
        #expect(r.cache.hubIDs.isEmpty)
        #expect(try r.custody.pairedHubs().count == 1)
        // the hub answers and says all is well: the relay's unsigned word does not stand, the lists are live again
        r.hub.faults.down = false
        let ok = try #require(live(await r.home.relayReportsRevoked()))
        #expect(ok.workspaces == snap.workspaces)
        // the hub confirms the revoke
        r.hub.faults.channelAnswer = "channel_revoked"
        #expect(await r.home.relayReportsRevoked() == .revoked)
        #expect(r.cache.hubIDs.isEmpty)
    }

    // MARK: single flight

    @Test func oneRefreshAtATime() async throws {
        let r0 = await Rig()
        let hold = HoldSender(r0.hub, path: "/api/v1/me/workspaces")
        let home = HubHomeCoordinator(custody: r0.custody, cache: r0.cache, verifier: HubVerifier(devMode: true), wall: r0.clock, makeSender: { _ in hold })
        let before = r0.hub.log.count
        async let a = home.refresh()
        await hold.waitUntilHeld()
        async let b = home.refresh()
        try await Task.sleep(nanoseconds: 50_000_000)
        hold.release()
        let (x, y) = await (a, b)
        #expect(x == y && live(x) != nil)
        #expect(r0.hub.log.dropFirst(before).filter { $0.hasSuffix("/me/workspaces") }.count == 1)
    }

    // MARK: items

    @Test func anItemComesFromTheHubAndIsFlattenedToLines() async throws {
        let r = await Rig()
        _ = await r.home.refresh()
        guard case .detail(let d) = await r.home.item(workspaceID: FakeHub.wsShared, itemID: "s1") else { Issue.record("no detail"); return }
        #expect(d.row.title == "Review the launch checklist" && d.row.signable == false)
        #expect(d.lines.map(\.label) == ["body", "title"])
        #expect(d.itemHash?.hasPrefix("sha256:") == true)
        guard case .detail(let q) = await r.home.item(workspaceID: FakeHub.wsPlatform, itemID: "q1") else { Issue.record("no detail"); return }
        #expect(q.lines.map(\.label) == ["options [1] / key", "options [1] / label", "options [2] / key", "options [2] / label", "question", "text"])
        // B3: the item offers a decision (display data; the hub's prepare and check_built are the authority)
        #expect(q.decision == HubItemDecision(log: "01J9ZP0000000000000000TKT1", hash: FakeHub.contentHash,
                                              kind: .question(id: "Q1", options: [.init(key: "eu-west", label: "EU West"), .init(key: "us-east", label: "US East")])))
        #expect(d.decision == nil)                       // a selective item is never decided on the phone
        #expect(await r.home.item(workspaceID: FakeHub.wsPlatform, itemID: "nope") == .refused(code: "unknown_item"))
    }

    @Test func itemIdsNeverChangeThePath() async {
        let r = await Rig()
        _ = await r.home.refresh()
        let n = r.hub.log.count
        for bad in ["../me/workspaces", "a/b", "a?x=1", "", String(repeating: "a", count: 65), "a b"] {
            #expect(await r.home.item(workspaceID: FakeHub.wsPlatform, itemID: bad) == .refused(code: "malformed"))
        }
        #expect(await r.home.item(workspaceID: "../x", itemID: "q1") == .refused(code: "malformed"))
        #expect(r.hub.log.count == n)
    }

    @Test func anItemOfAWorkspaceNotInTheListIsNotAsked() async {
        let r = await Rig()
        _ = await r.home.refresh()
        let n = r.hub.log.count
        #expect(await r.home.item(workspaceID: String(repeating: "ee", count: 16), itemID: "q1") == .refused(code: "unknown_workspace"))
        #expect(r.hub.log.count == n)
    }

    @Test func aRevokeDuringAnItemFetchEndsTheView() async throws {
        let r = await Rig()
        let s = await r.home.refresh()
        _ = try #require(live(s))
        r.hub.faults.channelAnswer = "channel_revoked"
        #expect(await r.home.item(workspaceID: FakeHub.wsPlatform, itemID: "q1") == .ended(.revoked))
        #expect(await r.home.state == .revoked && r.cache.hubIDs.isEmpty)
    }

    // MARK: cache hygiene

    @Test func aCacheOfAnotherPairingIsNotShown() async throws {
        let r = await Rig()
        _ = try #require(live(await r.home.refresh()))
        var e = try JSONDecoder().decode(HubCacheEntry.self, from: try #require(r.cache.read(hubID: r.hub.hubID)))
        e = HubCacheEntry(hubID: e.hubID, userID: e.userID, channelID: String(repeating: "0", count: 32), asOfMs: e.asOfMs, workspaces: e.workspaces, needsYou: e.needsYou)
        try r.cache.write(JSONEncoder().encode(e), hubID: r.hub.hubID)
        r.hub.faults.down = true
        #expect(await r.home.refresh() == .offline(nil))
        #expect(r.cache.hubIDs.isEmpty)
    }

    @Test func theFileCacheIsOneFilePerHubAndRejectsOtherNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hubcache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = FileHubCache(directory: dir)
        let id = String(repeating: "ab", count: 16)
        try c.write(Data("x".utf8), hubID: id)
        #expect(c.read(hubID: id) == Data("x".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [id + ".json"])
        #expect(throws: (any Error).self) { try c.write(Data(), hubID: "../x") }
        c.remove(hubID: id)
        #expect(c.read(hubID: id) == nil)
    }

    // MARK: sign in again

    @Test func signInAgainAfterTheSessionEndedBindsTheSameChannelAndGoesLive() async throws {
        let r = await Rig()
        _ = try #require(live(await r.home.refresh()))
        let before = try #require(try HubPairingRecord.load(custody: r.custody, hubID: r.hub.hubID, verifier: HubVerifier(devMode: true), nowMs: r.clock.nowMs))
        r.clock.advance(hours: 13)
        #expect(await r.home.refresh() == .signedOut)
        let n = r.hub.log.count
        let s = await r.home.signInAgain(password: r.hub.password, totp: r.hub.totp)
        #expect(live(s) != nil)
        #expect(Array(r.hub.log.dropFirst(n).prefix(2)) == ["POST /api/v1/session", "POST /api/v1/session/channel"])
        let after = try #require(try HubPairingRecord.load(custody: r.custody, hubID: r.hub.hubID, verifier: HubVerifier(devMode: true), nowMs: r.clock.nowMs))
        #expect(after.channelID == before.channelID && after.origin == before.origin && after.pairedMs == before.pairedMs)
        #expect(after.sessionExpiresMs > before.sessionExpiresMs && after.sessionExpiresMs > r.clock.nowMs)
        #expect(try r.custody.pairedHubs().count == 1)
        #expect(try r.custody.loadChannelKey(hubID: r.hub.hubID).channelID == before.channelID)   // the same key, no new channel
    }

    @Test func aFailedSignInAgainChangesNothing() async throws {
        let r = await Rig()
        _ = try #require(live(await r.home.refresh()))
        r.clock.advance(hours: 13)
        _ = await r.home.refresh()
        let token = try r.custody.sessionToken(hubID: r.hub.hubID)
        let rec = try r.custody.record(hubID: r.hub.hubID)
        #expect(await r.home.signInAgain(password: "wrong", totp: r.hub.totp) == .signInFailed(.badCredentials))
        r.hub.faults.longSession = true       // a session longer than 12 h is not accepted
        #expect(await r.home.signInAgain(password: r.hub.password, totp: r.hub.totp) == .signInFailed(.verification))
        r.hub.faults.longSession = false
        r.hub.faults.down = true
        #expect(await r.home.signInAgain(password: r.hub.password, totp: r.hub.totp) == .signInFailed(.network))
        #expect(try r.custody.sessionToken(hubID: r.hub.hubID) == token && (try r.custody.record(hubID: r.hub.hubID)) == rec)
        r.hub.faults.down = false
        #expect(await r.home.refresh() == .signedOut)
        #expect(r.cache.hubIDs.isEmpty)
    }

    @Test func aRevokedChannelCannotSignInAgain() async throws {
        let r = await Rig()
        _ = await r.home.refresh()
        r.clock.advance(hours: 13)
        r.hub.faults.bindAnswer = "channel_revoked"
        #expect(await r.home.signInAgain(password: r.hub.password, totp: r.hub.totp) == .revoked)
    }

    @Test func signInAgainGoesOnlyToTheStoredOrigin() async throws {
        let r = await Rig()
        _ = await r.home.refresh()
        r.clock.advance(hours: 13)
        let asked = OriginLog()
        let hub = r.hub
        let home = HubHomeCoordinator(custody: r.custody, cache: r.cache, verifier: HubVerifier(devMode: true), wall: r.clock,
                                      makeSender: { o in asked.add(o); return hub })
        #expect(live(await home.signInAgain(password: hub.password, totp: hub.totp)) != nil)
        #expect(Set(asked.all) == [hub.origin])
    }

    @Test func aWipeDuringTheBindIsNotUndoneBySignInAgain() async throws {
        let r = await Rig()
        _ = await r.home.refresh()
        r.clock.advance(hours: 13)
        let hold = HoldSender(r.hub, path: "/api/v1/session/channel")
        let hub = r.hub
        let home = HubHomeCoordinator(custody: r.custody, cache: r.cache, verifier: HubVerifier(devMode: true), wall: r.clock, makeSender: { _ in hold })
        async let result = home.signInAgain(password: hub.password, totp: hub.totp)
        await hold.waitUntilHeld()
        try r.custody.deleteAll(hubID: hub.hubID)          // Leave / wipe while the bind is in flight
        hold.release()
        #expect(await result == .signInFailed(.verification))
        #expect(try r.custody.pairedHubs().isEmpty && r.custody.sessionToken(hubID: hub.hubID) == nil)
    }

    @Test func theCacheIsExcludedFromBackups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hubcache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileHubCache(directory: dir).write(Data("x".utf8), hubID: String(repeating: "ab", count: 16))
        #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func dotOnlyItemIdsAreRefused() async {
        let r = await Rig()
        _ = await r.home.refresh()
        for bad in [".", ".."] { #expect(await r.home.item(workspaceID: FakeHub.wsPlatform, itemID: bad) == .refused(code: "malformed")) }
    }

    // MARK: one coordinator (L2-B1d-2)

    @Test func aSecondPairingCannotCommitOverTheKeyOfAnother() async throws {
        let clock = Clock()
        let h = FakeHub(origin: "https://hub.dev.orch.example", wall: clock)
        let backend = InMemoryVaultBackend()
        let custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        let hold = HoldSender(h, path: "/api/v1/session/channel")
        let xCfg = HubPairingConfig(custody: custody, verifier: HubVerifier(devMode: true), wall: clock, makeSender: { _ in hold })
        let x = HubPairingCoordinator(xCfg), y = HubPairingCoordinator(Rig.pairingConfig(custody, clock, h))
        _ = await x.begin(link: h.pairingLink)
        _ = await y.begin(link: h.pairingLink)
        async let xr = x.complete(password: h.password, totp: h.totp, label: "X")
        await hold.waitUntilHeld()
        // Y pairs completely while X waits at its bind: Y replaces X's key
        guard case .paired(let ys) = await y.complete(password: h.password, totp: h.totp, label: "Y") else { Issue.record("Y did not pair"); return }
        hold.release()
        #expect(await xr == .failed(.custody))
        let record = try #require(try HubPairingRecord.load(custody: custody, hubID: h.hubID, verifier: HubVerifier(devMode: true), nowMs: clock.nowMs))
        #expect(record.channelID == ys.channelID && record.label == "Y")
        #expect(try custody.loadChannelKey(hubID: h.hubID).channelID == ys.channelID)
    }
}
