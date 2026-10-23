import Foundation
import OrchCustody
import OrchFakeHost
import OrchProtocol
import Testing
@testable import OrchClient

private struct FixedWall: WallClock { let nowMs: Int64 = 1_790_000_000_000 }

/// Routes a hub origin to a sender (the fake hub, possibly under another host name: a phishing relay of the real hub's answers).
private struct AliasSender: RequestSender {
    let origin: String
    let inner: FakeHub
    func send(_ request: WireRequest) async throws -> WireReply { try await inner.send(request) }
}

/// Fails the n-th request (counting from 1) with a transport error.
private final class FlakySender: RequestSender, @unchecked Sendable {
    let inner: FakeHub
    let failAt: Int
    private let lock = NSLock()
    private var n = 0
    var origin: String { inner.origin }
    init(_ inner: FakeHub, failAt: Int) { self.inner = inner; self.failAt = failAt }
    func send(_ request: WireRequest) async throws -> WireReply {
        let k = lock.withLock { n += 1; return n }
        if k == failAt { throw TransportError.disconnected }
        return try await inner.send(request)
    }
}

private struct Rig {
    let hub: FakeHub
    let backend = InMemoryVaultBackend()
    let custody: HubKeyCustody
    let coordinator: HubPairingCoordinator

    init(verifier: HubVerifier = HubVerifier(devMode: true), sender: (@Sendable (FakeHub) -> (@Sendable (String) throws -> any RequestSender))? = nil,
         faults: FakeHub.Faults = FakeHub.Faults()) {
        let h = FakeHub(origin: "https://hub.dev.orch.example", wall: FixedWall())
        h.faults = faults
        hub = h
        custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        let make = sender?(h) ?? { @Sendable origin in
            guard origin == h.origin else { throw TransportError.disconnected }
            return h
        }
        coordinator = HubPairingCoordinator(HubPairingConfig(custody: custody, verifier: verifier, wall: FixedWall(), makeSender: make, wipe: HubWipe(custody: custody, cache: InMemoryHubCache())))
    }

    var stored: [String] {
        ((try? SecretVault(group: .keys, backend: backend).ids()) ?? []).map(\.purpose)
            + ((try? SecretVault(group: .push, backend: backend).ids()) ?? []).map(\.purpose)
    }

    func confirm() async -> HubPairingPreview? {
        if case .confirm(let p) = await coordinator.begin(link: hub.pairingLink) { return p }
        return nil
    }
}

/// Holds the n-th request until released.
private final class GateSender: RequestSender, @unchecked Sendable {
    let inner: FakeHub
    let holdAt: Int
    private let lock = NSLock()
    private var n = 0
    private var cont: CheckedContinuation<Void, Never>?
    private var released = false
    var origin: String { inner.origin }
    init(_ inner: FakeHub, holdAt: Int) { self.inner = inner; self.holdAt = holdAt }
    func release() {
        let c: CheckedContinuation<Void, Never>? = lock.withLock { released = true; let c = cont; cont = nil; return c }
        c?.resume()
    }
    func send(_ request: WireRequest) async throws -> WireReply {
        let k = lock.withLock { n += 1; return n }
        if k == holdAt { await withCheckedContinuation { c in
            let go = lock.withLock { () -> Bool in if released { return true }; cont = c; return false }
            if go { c.resume() }
        } }
        return try await inner.send(request)
    }
}

@Suite struct HubPairingTests {
    @Test func aCancelledAttemptThatWakesLaterTouchesNothingOfItsSuccessor() async throws {
        let hub = FakeHub(origin: "https://hub.dev.orch.example", wall: FixedWall())
        let backend = InMemoryVaultBackend()
        let custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        // request 3 = register/begin of the FIRST complete; it is held while the second attempt runs
        let gate = GateSender(hub, holdAt: 3)
        let co = HubPairingCoordinator(HubPairingConfig(custody: custody, verifier: HubVerifier(devMode: true), wall: FixedWall(), makeSender: { _ in gate }, wipe: HubWipe(custody: custody, cache: InMemoryHubCache())))
        guard case .confirm = await co.begin(link: hub.pairingLink) else { Issue.record("no confirm"); return }
        let first = Task { await co.complete(password: hub.password, totp: hub.totp, label: "One") }
        try await Task.sleep(for: .milliseconds(200))
        await co.cancel()
        guard case .confirm = await co.begin(link: hub.pairingLink) else { Issue.record("no second confirm"); return }
        guard case .paired(let s) = await co.complete(password: hub.password, totp: hub.totp, label: "Two") else { Issue.record("second not paired"); return }
        gate.release()
        _ = await first.value
        // the second attempt's key, token and record are all still there
        let hubID = hub.hubID
        #expect(try custody.loadChannelKey(hubID: hubID).channelID == s.channelID)
        #expect(try custody.sessionToken(hubID: hubID) != nil && custody.record(hubID: hubID) != nil)
    }

    @Test func pairsEndToEndAndKeepsOnlyTheVerifiedOrigin() async throws {
        let rig = Rig()
        let preview = try #require(await rig.confirm())
        #expect(preview.hubID == rig.hub.hubID && preview.host == "hub.dev.orch.example")
        #expect(preview.fingerprint == HubIdentifiers.fingerprint(hubID: rig.hub.hubID))
        #expect(rig.stored.isEmpty, "nothing is kept before the person signs in")
        let state = await rig.coordinator.complete(password: rig.hub.password, totp: rig.hub.totp, label: "Dev hub")
        guard case .paired(let summary) = state else { Issue.record("not paired: \(state)"); return }
        #expect(summary.hubID == rig.hub.hubID && summary.userID == rig.hub.userID && summary.label == "Dev hub")
        // order: the card is read and verified before any password is sent
        #expect(rig.hub.log == ["GET /api/v1/hub/card", "POST /api/v1/session", "POST /api/v1/channels/register/begin",
                                "POST /api/v1/channels/register/complete", "POST /api/v1/session/channel"])
        // committed: key, session token, record
        let hubID = rig.hub.hubID
        #expect(rig.stored.sorted() == ["hub.\(hubID).channel-key", "hub.\(hubID).record", "hub.\(hubID).session"])
        let record = try #require(try HubPairingRecord.load(custody: rig.custody, hubID: hubID, verifier: HubVerifier(devMode: true), nowMs: FixedWall().nowMs))
        #expect(record.origin == "https://hub.dev.orch.example" && record.channelID == summary.channelID)
        #expect(rig.hub.registeredChannels == [record.channelID])
        #expect(try rig.custody.loadChannelKey(hubID: hubID).channelID == record.channelID)
        #expect(try rig.custody.sessionToken(hubID: hubID)?.hasPrefix("FAKE-HUB-CHANNEL-") == true)
        // the pairing session token never reaches storage
        #expect(try rig.custody.sessionToken(hubID: hubID)?.contains("PAIRING") == false)
        // every later client is built from the record: the stored origin, nowhere else
        let api = try record.api { origin in
            #expect(origin == record.origin); return rig.hub
        }
        #expect(api.origin == "https://hub.dev.orch.example")
        #expect(throws: HubAPIError.badReply) { try HubAPI(origin: "https://other.example", sender: rig.hub) }
        // one hub per install: a second link is refused before any request
        let before = rig.hub.log.count
        #expect(await rig.coordinator.begin(link: rig.hub.pairingLink) == .failed(.alreadyPaired))
        #expect(rig.hub.log.count == before)
    }

    @Test func aPhishingLinkWithTheRealHubIDFailsBeforeAnyPassword() async {
        // the attacker's host relays the real hub's card and signed origin, which name the REAL origin
        let rig = Rig(sender: { hub in { @Sendable origin in AliasSender(origin: origin, inner: hub) } })
        let phishing = "orch://hub-pair/hub-login.evil.example#h1.\(rig.hub.hubID).\(rig.hub.userID).ab12-cd34-ef56"
        #expect(await rig.coordinator.begin(link: phishing) == .failed(.otherOrigin))
        #expect(rig.hub.log == ["GET /api/v1/hub/card"])
        #expect(rig.stored.isEmpty)
    }

    @Test func aCardOfAnotherHubIsRefusedAndNeverRepinned() async {
        let rig = Rig(faults: { var f = FakeHub.Faults(); f.rogueHubCard = true; return f }())
        #expect(await rig.coordinator.begin(link: rig.hub.pairingLink) == .failed(.otherHub))
        #expect(rig.hub.log == ["GET /api/v1/hub/card"])
        #expect(rig.stored.isEmpty)
    }

    @Test func aSignedOriginThatIsNotTheLinksIsRefused() async {
        let rig = Rig(faults: { var f = FakeHub.Faults(); f.signedOrigin = "https://hub.dev.orch.example:8443"; return f }())
        #expect(await rig.coordinator.begin(link: rig.hub.pairingLink) == .failed(.otherOrigin))
        #expect(rig.hub.log == ["GET /api/v1/hub/card"])
    }

    @Test func aReleaseBuildRefusesADevHub() async {
        let rig = Rig(verifier: HubVerifier(devMode: false))
        #expect(await rig.coordinator.begin(link: rig.hub.pairingLink) == .failed(.cardRefused("dev_refused")))
        #expect(rig.hub.log == ["GET /api/v1/hub/card"])
        // and a loopback link is not even parsed
        #expect(await rig.coordinator.begin(link: "orch://hub-pair/127.0.0.1:8443#h1.\(rig.hub.hubID).\(rig.hub.userID).ab12-cd34-ef56") == .failed(.badLink))
    }

    @Test func badLinksNeverTouchTheNetwork() async {
        let rig = Rig()
        for l in ["", "https://hub.dev.orch.example/pair", "orch://hub-pair/Hub.example#h1.x.y.z",
                  "orch://hub-pair/hub.dev.orch.example#h1.\(rig.hub.hubID).\(rig.hub.userID).AB12-cd34-ef56"] {
            #expect(await rig.coordinator.begin(link: l) == .failed(.badLink), "\(l)")
        }
        #expect(rig.hub.log.isEmpty)
    }

    @Test func wrongCredentialsLeaveNothing() async throws {
        let rig = Rig()
        _ = try #require(await rig.confirm())
        #expect(await rig.coordinator.complete(password: "nope", totp: rig.hub.totp, label: "Dev hub") == .failed(.badCredentials))
        #expect(rig.stored.isEmpty && rig.hub.registeredChannels.isEmpty)
    }

    @Test func aWrongPairingCodeDeletesTheKeyAndSignsOut() async throws {
        let rig = Rig()
        let link = "orch://hub-pair/hub.dev.orch.example#h1.\(rig.hub.hubID).\(rig.hub.userID).0000-0000-0000"
        guard case .confirm = await rig.coordinator.begin(link: link) else { Issue.record("no confirm"); return }
        #expect(await rig.coordinator.complete(password: rig.hub.password, totp: rig.hub.totp, label: "Dev hub") == .failed(.pairingCodeRejected))
        #expect(rig.stored.isEmpty)
        #expect(rig.hub.log.last == "DELETE /api/v1/session")
    }

    @Test(arguments: [
        ("factor", "factor_mismatch"), ("cert_other_key", "cert_invalid"), ("challenge_user", "other_user"),
        ("challenge_expiry", "challenge_invalid"), ("long_session", "malformed"),
    ])
    func aHubThatMisbehavesIsRefusedAndNothingIsKept(fault: String, expected: String) async throws {
        var f = FakeHub.Faults()
        switch fault {
        case "factor": f.certFactor = "password+totp"
        case "cert_other_key": f.certForOtherKey = true
        case "challenge_user": f.challengeUser = String(repeating: "a", count: 32)
        case "challenge_expiry": f.challengeExpiryMs = FixedWall().nowMs + 3_600_000
        default: f.longSession = true
        }
        let rig = Rig(faults: f)
        _ = try #require(await rig.confirm())
        #expect(await rig.coordinator.complete(password: rig.hub.password, totp: rig.hub.totp, label: "Dev hub") == .failed(.verification(expected)))
        #expect(rig.stored.isEmpty, "\(fault): nothing kept")
        if fault == "challenge_user" || fault == "challenge_expiry" { #expect(rig.hub.registeredChannels.isEmpty, "the key signed nothing") }
        #expect(rig.hub.log.last == "DELETE /api/v1/session" || fault == "long_session")
    }

    @Test(.timeLimit(.minutes(2)), arguments: 1...5)
    func aNetworkFailureAtAnyStepLeavesNothing(step: Int) async {
        let rig = Rig(sender: { hub in { @Sendable _ in FlakySender(hub, failAt: step) } })
        let first = await rig.coordinator.begin(link: rig.hub.pairingLink)
        if step == 1 { #expect(first == .failed(.network)); return }
        guard case .confirm = first else { Issue.record("no confirm"); return }
        let r = await rig.coordinator.complete(password: rig.hub.password, totp: rig.hub.totp, label: "Dev hub")
        #expect(r == .failed(.network), "step \(step)")
        #expect(rig.stored.isEmpty, "step \(step)")
    }

    /// The five failure steps, many pairings at once (L2-B6e-1: CI hung in this test on the B6 branch; every pairing now also takes the wipe
    /// barrier, and its rollback revokes at the hub). Each case must finish, leave nothing, and never block another.
    @Test(.timeLimit(.minutes(2))) func theFailureStepsRunConcurrentlyAndAllFinish() async {
        await withTaskGroup(of: Bool.self) { group in
            for round in 0..<200 {
                group.addTask {
                    let step = round % 5 + 1
                    let rig = Rig(sender: { hub in { @Sendable _ in FlakySender(hub, failAt: step) } })
                    let first = await rig.coordinator.begin(link: rig.hub.pairingLink)
                    if step == 1 { return first == .failed(.network) }
                    guard case .confirm = first else { return false }
                    let r = await rig.coordinator.complete(password: rig.hub.password, totp: rig.hub.totp, label: "Dev hub")
                    return r == .failed(.network) && rig.stored.isEmpty
                }
            }
            var ok = 0
            for await good in group where good { ok += 1 }
            #expect(ok == 200)
        }
    }

    @Test func cancelForgetsTheStagedPairing() async throws {
        let rig = Rig()
        _ = try #require(await rig.confirm())
        await rig.coordinator.cancel()
        #expect(await rig.coordinator.state == .idle)
        #expect(await rig.coordinator.complete(password: rig.hub.password, totp: rig.hub.totp, label: "Dev hub") == .idle)
        #expect(rig.stored.isEmpty && rig.hub.log == ["GET /api/v1/hub/card"])
    }

    @Test func aLeftoverKeyOfAnInterruptedPairingIsReplaced() async throws {
        let rig = Rig()
        let old = try rig.custody.createChannelKey(hubID: rig.hub.hubID, work: .unguarded)
        _ = try #require(await rig.confirm())
        guard case .paired(let s) = await rig.coordinator.complete(password: rig.hub.password, totp: rig.hub.totp, label: "Dev hub") else {
            Issue.record("not paired"); return
        }
        #expect(s.channelID != old.channelID)
    }

    @Test func secretsNeverAppearInStatesDescriptionsOrTheRecord() async throws {
        let rig = Rig()
        _ = try #require(await rig.confirm())
        let state = await rig.coordinator.complete(password: rig.hub.password, totp: rig.hub.totp, label: "Dev hub")
        let text = "\(state) \(String(reflecting: state)) \(HubBearer("tok-123")) \(String(reflecting: HubBearer("tok-123")))"
        #expect(!text.contains(rig.hub.password) && !text.contains("tok-123") && !text.contains("ab12-cd34-ef56"))
        let record = try #require(try rig.custody.record(hubID: rig.hub.hubID))
        let recordText = String(decoding: record, as: UTF8.self)
        #expect(!recordText.contains("ab12-cd34-ef56") && !recordText.contains(rig.hub.password) && !recordText.contains("FAKE-HUB"))
    }

    @Test func aBadLabelIsRefusedBeforeAnyKeyExists() async throws {
        let rig = Rig()
        _ = try #require(await rig.confirm())
        #expect(await rig.coordinator.complete(password: rig.hub.password, totp: rig.hub.totp, label: "") == .failed(.verification("label")))
        #expect(rig.stored.isEmpty && rig.hub.log == ["GET /api/v1/hub/card"])
    }
}
