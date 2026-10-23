import Foundation
import OrchCustody
import OrchFakeHost
import OrchProtocol
import Testing
@testable import OrchClient

/// B6: Leave, a revoke the hub itself confirmed, Reset this iPhone, and the resumable wipe under all three (design-b-phone.md B6, L2B-2, R3).

private struct WipeRig {
    let rig: HomeRig
    let journal = InMemoryHubWipeJournal()
    let wipe: HubWipe
    let home: HubHomeCoordinator
    var hub: FakeHub { rig.hub }
    var custody: HubKeyCustody { rig.custody }

    init(failingStep: (@Sendable (HubWipeScope) async throws -> Void)? = nil) async {
        let journal = self.journal
        let holder = Holder()
        let r = await HomeRig(paired: true, seed: true, home: { c, cache, clock, h in
            let w = HubWipe(custody: c, cache: cache, journal: journal, steps: failingStep.map { [$0] } ?? [])
            holder.wipe = w
            return HubHomeCoordinator(custody: c, cache: cache, verifier: HubVerifier(devMode: true), wall: clock,
                                      makeSender: { o in guard o == h.origin else { throw TransportError.disconnected }; return h }, wipe: w)
        })
        rig = r; wipe = holder.wipe!
        home = r.home
    }

    final class Holder: @unchecked Sendable { var wipe: HubWipe? }

    /// Nothing of any hub is left in either keychain group.
    func vaultEmpty() throws -> Bool {
        try SecretVault(group: .keys, backend: rig.backend).ids().isEmpty && SecretVault(group: .push, backend: rig.backend).ids().isEmpty
    }

    /// A push key, as B4 stores it after the pairing, so the wipe has the whole set to remove.
    func addPushKey() throws { _ = try custody.createPushKey(hubID: hub.hubID) }
}

private func live(_ s: HubHomeState) -> HubSnapshot? { if case .live(let x) = s { return x }; return nil }

@Suite struct HubWipeTests {
    // MARK: Leave

    @Test func leaveRevokesAtTheHubFirstThenWipesEverything() async throws {
        let r = await WipeRig()
        try r.addPushKey()
        _ = try #require(live(await r.home.refresh()))
        let channel = try #require(r.hub.registeredChannels.first)
        #expect(try r.vaultEmpty() == false && r.rig.cache.hubIDs.count == 1)
        #expect(await r.home.leave() == .left(revokedAtHub: true))
        #expect(r.hub.revokedChannels == [channel])
        #expect(r.hub.log.last == "POST /api/v1/channels/\(channel)/revoke")
        #expect(try r.vaultEmpty() && r.custody.pairedHubs().isEmpty)
        #expect(r.rig.cache.hubIDs.isEmpty && r.journal.read() == nil)
        #expect(await r.home.state == .notPaired)
        // the key is gone, so nothing can sign for that channel any more
        #expect(throws: CustodyError.missing) { try r.custody.loadChannelKey(hubID: r.hub.hubID) }
    }

    @Test(arguments: ["down", "refused", "pairing"]) func leaveWipesEvenWhenTheRevokeFails(why: String) async throws {
        let r = await WipeRig()
        _ = try #require(live(await r.home.refresh()))
        switch why {
        case "down": r.hub.faults.down = true
        case "refused": r.hub.faults.revokeAnswer = "unavailable"
        default: r.hub.faults.channelAnswer = "forbidden_role"
        }
        #expect(await r.home.leave() == .left(revokedAtHub: false))
        #expect(r.hub.revokedChannels.isEmpty)
        #expect(try r.vaultEmpty() && r.rig.cache.hubIDs.isEmpty && r.journal.read() == nil)
    }

    @Test func leaveWithoutAPairingDoesNothing() async throws {
        let r = await WipeRig()
        _ = await r.home.leave()
        let n = r.hub.log.count
        #expect(await r.home.leave() == .notPaired)
        #expect(r.hub.log.count == n)
    }

    @Test func leaveWithTheSessionOverStillWipesAndSaysItWasNotRevoked() async throws {
        let r = await WipeRig()
        _ = try #require(live(await r.home.refresh()))
        r.rig.clock.advance(hours: 13)             // the channel session is over: the hub answers no_session to a revoke
        #expect(await r.home.leave() == .left(revokedAtHub: false))
        #expect(try r.vaultEmpty())
    }

    // MARK: the hub's own answer (R3)

    @Test(arguments: ["channel_revoked", "cert_expired"]) func aRevokeTheHubConfirmsWipesEverythingIncludingTheCache(code: String) async throws {
        let r = await WipeRig()
        try r.addPushKey()
        _ = try #require(live(await r.home.refresh()))
        #expect(r.rig.cache.hubIDs.count == 1)
        r.hub.faults.channelAnswer = code
        #expect(await r.home.refresh() == .revoked)
        #expect(try r.vaultEmpty() && r.custody.pairedHubs().isEmpty)
        #expect(r.rig.cache.hubIDs.isEmpty && r.journal.read() == nil)
        // a new launch shows nothing of the old pairing and offers a new one
        #expect(await HomeRig.makeHome(r.custody, r.rig.cache, r.rig.clock, r.hub).restore() == .notPaired)
        #expect(await r.home.pairAgain() == .notPaired)
    }

    @Test func aRevokeAnsweredToAnItemFetchWipes() async throws {
        let r = await WipeRig()
        _ = try #require(live(await r.home.refresh()))
        r.hub.faults.channelAnswer = "channel_revoked"
        #expect(await r.home.item(workspaceID: FakeHub.wsPlatform, itemID: "q1") == .ended(.revoked))
        #expect(try r.vaultEmpty() && r.rig.cache.hubIDs.isEmpty)
    }

    @Test func aRevokeAnsweredToTheBindWipes() async throws {
        let r = await WipeRig()
        _ = await r.home.refresh()
        r.rig.clock.advance(hours: 13)
        r.hub.faults.bindAnswer = "channel_revoked"
        #expect(await r.home.signInAgain(password: r.hub.password, totp: r.hub.totp) == .revoked)
        #expect(try r.vaultEmpty() && r.rig.cache.hubIDs.isEmpty)
    }

    @Test func otherRefusalsAndNoSessionNeverWipe() async throws {
        let r = await WipeRig()
        _ = try #require(live(await r.home.refresh()))
        for code in ["no_session", "unavailable", "internal"] {
            r.hub.faults.channelAnswer = code
            _ = await r.home.refresh()
            #expect(try r.custody.pairedHubs().count == 1 && r.journal.read() == nil, "\(code)")
        }
    }

    @Test func aCertificateThatRanOutByThePhonesClockWipesOnlyWhenThePersonPairsAgain() async throws {
        let r = await WipeRig()
        _ = try #require(live(await r.home.refresh()))
        r.rig.clock.advance(hours: 24 * 32)        // past the 31-day certificate (no renewal in V3)
        #expect(await r.home.refresh() == .revoked)
        #expect(r.rig.cache.hubIDs.isEmpty)
        #expect(try r.custody.pairedHubs().count == 1)            // a clock is not the hub: nothing is wiped yet
        #expect(await r.home.pairAgain() == .notPaired)           // the person's own choice
        #expect(try r.vaultEmpty() && r.journal.read() == nil)
    }

    // MARK: the relay's word (L2B-2)

    @Test func aRelayRevokeNeverWipes() async throws {
        let r = await WipeRig()
        let snap = try #require(live(await r.home.refresh()))
        // the hub is unreachable: the cache is gone, the pairing and the key stay, nothing is journaled
        r.hub.faults.down = true
        #expect(await r.home.relayReportsRevoked() == .offline(nil))
        #expect(r.rig.cache.hubIDs.isEmpty && r.journal.read() == nil)
        #expect(try r.custody.pairedHubs().count == 1 && r.custody.loadChannelKey(hubID: r.hub.hubID).channelID.count == 32)
        // the hub answers and does not confirm: the lists are live again
        r.hub.faults.down = false
        #expect(try #require(live(await r.home.relayReportsRevoked())).workspaces == snap.workspaces)
        #expect(try r.custody.pairedHubs().count == 1)
        // only the hub's own answer wipes
        r.hub.faults.channelAnswer = "channel_revoked"
        #expect(await r.home.relayReportsRevoked() == .revoked)
        #expect(try r.vaultEmpty())
    }

    // MARK: the resumable wipe

    @Test func aWipeInterruptedAtAnyPhaseFinishesAtTheNextLaunch() async throws {
        // a step that fails once stands for a kill after the secrets were deleted and before the record was
        let fail = FailOnce()
        let r = await WipeRig(failingStep: { _ in try fail.maybeFail() })
        try r.addPushKey()
        _ = try #require(live(await r.home.refresh()))
        await #expect(throws: (any Error).self) { try await r.wipe.wipe(.hub(r.hub.hubID)) }
        #expect(r.journal.read()?.phase == HubWipe.Phase.secrets)
        // half-wiped: keys, token and push key are gone; the record still names the hub
        #expect(try r.custody.pairedHubs() == [r.hub.hubID])
        #expect(throws: CustodyError.missing) { try r.custody.loadChannelKey(hubID: r.hub.hubID) }
        #expect(try r.custody.sessionToken(hubID: r.hub.hubID) == nil)
        #expect(r.wipe.pending)
        // the next launch: a NEW wipe object over the same journal and stores resumes it (the home does so before it shows anything)
        let again = HubWipe(custody: r.custody, cache: r.rig.cache, journal: r.journal)
        let home = HubHomeCoordinator(custody: r.custody, cache: r.rig.cache, verifier: HubVerifier(devMode: true), wall: r.rig.clock,
                                      makeSender: { _ in r.hub }, wipe: again)
        #expect(await home.restore() == .notPaired)
        #expect(try r.vaultEmpty() && r.rig.cache.hubIDs.isEmpty && r.journal.read() == nil && !again.pending)
        // idempotent: nothing pending, nothing happens
        try await again.resume()
    }

    @Test func aWipeThatCannotFinishKeepsThePairingUnusableAndRetries() async throws {
        let fail = FailOnce()
        let r = await WipeRig(failingStep: { _ in try fail.maybeFail() })
        _ = try #require(live(await r.home.refresh()))
        r.hub.faults.channelAnswer = "channel_revoked"
        #expect(await r.home.refresh() == .revoked)               // the hub said so; the wipe failed once
        #expect(r.wipe.pending)
        // nothing is used while it is unfinished, and no pairing may start over it
        #expect(await r.home.refresh() == .notPaired)             // the retry inside refresh finished it
        #expect(try !r.wipe.pending && r.vaultEmpty())
    }

    @Test func anUnfinishedWipeBlocksANewPairing() async throws {
        let r = await WipeRig()
        _ = await r.home.leave()
        let fresh = FakeHub(origin: "https://hub.dev.orch.example", wall: r.rig.clock)
        try r.journal.write(HubWipeIntent(scope: .hub(fresh.hubID), phase: 0))
        let pairing = HubPairingCoordinator(HubPairingConfig(custody: r.custody, verifier: HubVerifier(devMode: true), wall: r.rig.clock,
                                                              makeSender: { _ in fresh }, wipe: r.wipe))
        #expect(await pairing.begin(link: fresh.pairingLink) == .failed(.custody))
        try await r.wipe.resume()
        guard case .confirm = await pairing.begin(link: fresh.pairingLink) else { Issue.record("pairing should start after the wipe"); return }
    }

    @Test func resetWipesEveryHubItemAndEveryCacheAndLeavesDirectItems() async throws {
        let r = await WipeRig()
        try r.addPushKey()
        _ = try #require(live(await r.home.refresh()))
        let keys = SecretVault(group: .keys, backend: r.rig.backend)
        let leftover = String(repeating: "ab", count: 16)
        try keys.put(Data("k".utf8), for: SecretID(realm: .live, purpose: "hub.\(leftover).channel-key"))   // an interrupted pairing's key
        try keys.put(Data("dk".utf8), for: SecretID(realm: .live, purpose: "dk_sig"))
        try r.rig.cache.write(Data("{}".utf8), hubID: leftover)                                              // another hub's cache
        try r.wipe.begin(.everything)
        #expect(r.wipe.pending)
        try await r.wipe.resume()                                  // what the launch (or the reset's own task) runs
        #expect(try keys.ids().map(\.purpose) == ["dk_sig"])
        #expect(try SecretVault(group: .push, backend: r.rig.backend).ids().isEmpty)
        #expect(r.rig.cache.hubIDs.isEmpty && r.journal.read() == nil)
    }

    @Test func aHubWipeWidensToResetWithoutLosingTheStricterScope() async throws {
        let r = await WipeRig()
        try r.wipe.begin(.hub(r.hub.hubID))
        try r.wipe.begin(.everything)
        #expect(r.journal.read() == HubWipeIntent(scope: .everything, phase: 0))
        try r.wipe.begin(.hub(r.hub.hubID))                       // a narrower request never narrows a pending one
        #expect(r.journal.read()?.scope == .everything)
        try await r.wipe.run()
        #expect(r.journal.read() == nil)
    }

    @Test func theLaterTasksCleanupStepsRunBeforeTheRecordGoes() async throws {
        let seen = Seen()
        let r = await WipeRig(failingStep: { s in await seen.add("\(s)") })
        try await r.wipe.wipe(.hub(r.hub.hubID))
        #expect(await seen.items == ["hub(\"\(r.hub.hubID)\")"])
    }

    @Test func quiesceRunsFirstAndAnInFlightRefreshDoesNotWriteTheCacheBack() async throws {
        let r0 = await WipeRig()
        _ = try #require(live(await r0.home.refresh()))
        r0.rig.cache.remove(hubID: r0.hub.hubID)
        // a refresh is in flight at the hub when a Reset wipe runs (it starts outside the home coordinator)
        let hold = HoldSender(r0.hub, path: "/api/v1/me/needs-you")
        let home = HubHomeCoordinator(custody: r0.custody, cache: r0.rig.cache, verifier: HubVerifier(devMode: true), wall: r0.rig.clock,
                                      makeSender: { _ in hold }, wipe: r0.wipe)
        let seen = Seen()
        let custody = r0.custody, hubID = r0.hub.hubID
        r0.wipe.onQuiesce { _ in await seen.add((try? custody.sessionToken(hubID: hubID)) == nil ? "gone" : "still-there") }
        async let refreshed = home.refresh()
        await hold.waitUntilHeld()
        try await r0.wipe.wipe(.everything)
        hold.release()
        _ = await refreshed
        #expect(await seen.items == ["still-there"])                 // quiesce ran before anything was deleted
        #expect(try r0.rig.cache.hubIDs.isEmpty && r0.vaultEmpty())
    }

    @Test func theWipeSweepsTheIssuedCounterAndThePushMaterial() async throws {
        let r = await WipeRig()
        try r.addPushKey()
        let hubID = r.hub.hubID
        try r.custody.putPushState(HubPushState(issuedMs: 1_790_000_000_123, keyRegistered: true, targetDigest: "ab"), hubID: hubID)
        try r.custody.publishPushMaterial(hubID: hubID, channelID: String(repeating: "cd", count: 16), label: "Dev hub")
        #expect(try r.custody.pushState(hubID: hubID)?.issuedMs == 1_790_000_000_123 && r.custody.pushMaterial() != nil)
        try await r.wipe.wipe(.hub(hubID))
        #expect(try r.custody.pushState(hubID: hubID) == nil && r.custody.pushMaterial() == nil && r.vaultEmpty())
    }

    @Test func aPushingCoordinatorDoesNothingWhileAWipeIsPending() async throws {
        let r = await WipeRig()
        let push = HubPushCoordinator(.init(custody: r.custody, pushDir: FileManager.default.temporaryDirectory, verifier: HubVerifier(devMode: true),
                                            wall: r.rig.clock, makeSender: { _ in r.hub }, wipe: r.wipe))
        try r.wipe.begin(.hub(r.hub.hubID))
        let n = r.hub.log.count
        #expect(await push.registerPush(HubPushTarget(env: .sandbox, token: "AAAA")) == .notPaired)
        #expect(try r.hub.log.count == n && r.custody.pushMaterial() == nil)
    }

    @Test func theJournalSurvivesInUserDefaults() throws {
        let suite = "orch.test.hubwipe." + UUID().uuidString
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let j = DefaultsHubWipeJournal(defaults: d)
        #expect(j.read() == nil)
        try j.write(HubWipeIntent(scope: .everything, phase: 2))
        #expect(DefaultsHubWipeJournal(defaults: d).read() == HubWipeIntent(scope: .everything, phase: 2))
        j.clear()
        #expect(j.read() == nil)
    }

    // MARK: a late pairing failure (L2-B1-3)

    @Test func aLateFailureAfterTheBindRevokesTheChannelAtTheHub() async throws {
        let r = await HomeRig(paired: false)
        r.hub.faults.longSession = true                  // the bind answer is refused locally (a session longer than 12 h)
        let pairing = HubPairingCoordinator(HomeRig.pairingConfig(r.custody, r.clock, r.hub))
        _ = await pairing.begin(link: r.hub.pairingLink)
        guard case .failed = await pairing.complete(password: r.hub.password, totp: r.hub.totp, label: "Dev hub") else { Issue.record("should fail"); return }
        #expect(Set(r.hub.revokedChannels) == Set(r.hub.registeredChannels) && r.hub.revokedChannels.count == 1)
        #expect(try r.custody.pairedHubs().isEmpty && SecretVault(group: .keys, backend: r.backend).ids().isEmpty)
    }

    @Test func aLateFailureBeforeTheBindBindsThenRevokesBecauseAPairingSessionMayNot() async throws {
        let r = await HomeRig(paired: false)
        r.hub.faults.certFactor = "se-locked"            // the certificate is refused before the bind
        let pairing = HubPairingCoordinator(HomeRig.pairingConfig(r.custody, r.clock, r.hub))
        _ = await pairing.begin(link: r.hub.pairingLink)
        guard case .failed = await pairing.complete(password: r.hub.password, totp: r.hub.totp, label: "Dev hub") else { Issue.record("should fail"); return }
        #expect(r.hub.revokedChannels.count == 1 && Set(r.hub.revokedChannels) == Set(r.hub.registeredChannels))
        #expect(try SecretVault(group: .keys, backend: r.backend).ids().isEmpty)
    }

    @Test func aFailureBeforeTheRegistrationRevokesNothing() async throws {
        let r = await HomeRig(paired: false)
        let pairing = HubPairingCoordinator(HomeRig.pairingConfig(r.custody, r.clock, r.hub))
        _ = await pairing.begin(link: r.hub.pairingLink)
        guard case .failed = await pairing.complete(password: "wrong", totp: r.hub.totp, label: "Dev hub") else { Issue.record("should fail"); return }
        #expect(r.hub.revokedChannels.isEmpty && !r.hub.log.contains { $0.hasSuffix("/revoke") })
    }
}

private final class FailOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func maybeFail() throws {
        let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
        if first { throw CocoaError(.fileWriteUnknown) }
    }
}

private actor Seen {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}
