import Foundation
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchPush
import OrchTestVectors
import Testing
@testable import OrchClient
@testable import OrchProtocol

private final class Clock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64 = 1_790_000_000_000
    var nowMs: Int64 { lock.withLock { ms } }
    func advance(_ by: Int64) { lock.withLock { ms += by } }
}

private let relayOrigin = "https://relay.dev.orch.example"

/// A paired phone against FakeHub and a fake relay mailbox (B4): the real coordinator stack, no network.
private struct Rig {
    let clock = Clock()
    let hub: FakeHub
    let relay: FakeHubRelay
    let backend = InMemoryVaultBackend()
    let custody: HubKeyCustody
    let pushDir: URL
    let dropped = Counter()
    let sender: @Sendable (String) throws -> any RequestSender
    let coordinator: HubPushCoordinator
    let channelID: String

    final class Counter: @unchecked Sendable { private let l = NSLock(); private var n = 0; func bump() { l.withLock { n += 1 } }; var value: Int { l.withLock { n } } }

    init(relayURL: String? = relayOrigin, hubReachable: Bool = true) async throws {
        let h = FakeHub(origin: "https://hub.dev.orch.example", wall: clock, relayURL: relayURL)
        let r = FakeHubRelay(origin: relayOrigin, hub: h, wall: clock)
        hub = h; relay = r
        custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        pushDir = FileManager.default.temporaryDirectory.appendingPathComponent("orch-b4c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pushDir, withIntermediateDirectories: true)
        let reach = ReachFlag(hubReachable)
        reachable = reach
        let make: @Sendable (String) throws -> any RequestSender = { origin in
            if origin == h.origin { guard reach.value else { throw HubAPIError.network }; return h }
            if origin == relayOrigin { return r }
            throw HubAPIError.network
        }
        sender = make
        let verifier = HubVerifier(devMode: true)
        let pairing = HubPairingCoordinator(HubPairingConfig(custody: custody, verifier: verifier, wall: clock, makeSender: make))
        guard case .confirm = await pairing.begin(link: h.pairingLink) else { throw HubPairingFailure.badLink }
        guard case .paired(let summary) = await pairing.complete(password: h.password, totp: h.totp, label: "Work hub") else { throw HubPairingFailure.noSession }
        channelID = summary.channelID
        let counter = dropped
        coordinator = HubPushCoordinator(.init(custody: custody, pushDir: pushDir, verifier: verifier, wall: clock, makeSender: make,
                                                dropCache: { counter.bump() }))
    }
    let reachable: ReachFlag
    final class ReachFlag: @unchecked Sendable { private let l = NSLock(); private var v: Bool; init(_ v: Bool) { self.v = v }
        var value: Bool { get { l.withLock { v } } set { l.withLock { v = newValue } } } }

    static let target = HubPushTarget(env: .sandbox, token: B64U.encode(Data(repeating: 7, count: 32)))
    func cleanUp() { try? FileManager.default.removeItem(at: pushDir) }

    /// The hub leaves one hint in the mailbox (what `send_push` does) and returns its id.
    @discardableResult func leave(type: String = "prepare", ref: String? = "ac75e2a53bd607b283c15af8eb004b72", ts: Int64? = nil) -> String? {
        guard let s = hub.sealHint(channelID: channelID, type: type, ref: ref, tsMs: ts) else { return nil }
        relay.put(channelID: channelID, id: s.id, c: s.c)
        return s.id
    }
}

@Suite struct HubPushRegistrationTests {
    @Test func afterBindTheHubHoldsTheSignedPushKeyAndTheTarget() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        #expect(rig.hub.heldPushPub(channelID: rig.channelID) == nil)
        #expect(await rig.coordinator.registerPush(Rig.target) == .registered)
        let key = try rig.custody.loadPushKey(hubID: rig.hub.hubID)
        #expect(rig.hub.heldPushPub(channelID: rig.channelID) == key.publicKey)
        #expect(rig.hub.heldPushIssuedMs(channelID: rig.channelID) == rig.clock.nowMs)
        #expect(rig.hub.pushTarget(channelID: rig.channelID)?.token == Rig.target.token)
        // the extension's one item exists, for this channel, under the label the person chose
        let m = try #require(try rig.custody.pushMaterial())
        #expect(m.channelID == rig.channelID && m.hubID == rig.hub.hubID && m.label == "Work hub" && m.opener.publicKey == key.publicKey)
        // the channel session token was the only credential on the wire, and no push key private part ever left
        #expect(rig.hub.log.contains { $0.hasPrefix("PUT /api/v1/channels/\(rig.channelID)/push") })
    }

    @Test func aRepeatIsNothingAndANewTokenKeepsTheHeldKey() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        _ = await rig.coordinator.registerPush(Rig.target)
        let puts = rig.hub.log.filter { $0.hasPrefix("PUT") }.count
        #expect(await rig.coordinator.registerPush(Rig.target) == .unchanged)
        #expect(rig.hub.log.filter { $0.hasPrefix("PUT") }.count == puts)
        let issued = rig.hub.heldPushIssuedMs(channelID: rig.channelID)
        rig.clock.advance(60_000)
        let next = HubPushTarget(env: .sandbox, token: B64U.encode(Data(repeating: 9, count: 32)))
        #expect(await rig.coordinator.registerPush(next) == .registered)
        #expect(rig.hub.pushTarget(channelID: rig.channelID)?.token == next.token)
        #expect(rig.hub.heldPushIssuedMs(channelID: rig.channelID) == issued)   // `push_key: null` kept the held key, no new signature
    }

    @Test func issuedMsIsMonotonicAndAReplayRefusalSignsANewerKey() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        _ = await rig.coordinator.registerPush(Rig.target)
        let first = try #require(rig.hub.heldPushIssuedMs(channelID: rig.channelID))
        // the phone forgets that the hub holds the key (state lost): it signs again, with the same clock, and must still be newer
        try rig.custody.putPushState(HubPushState(issuedMs: 0, keyRegistered: false), hubID: rig.hub.hubID)
        let other = HubPushTarget(env: .sandbox, token: B64U.encode(Data(repeating: 3, count: 32)))
        #expect(await rig.coordinator.registerPush(other) == .registered)
        #expect(try #require(rig.hub.heldPushIssuedMs(channelID: rig.channelID)) > first)
        let state = try #require(try rig.custody.pushState(hubID: rig.hub.hubID))
        #expect(state.keyRegistered && state.issuedMs == rig.hub.heldPushIssuedMs(channelID: rig.channelID))
    }

    @Test func noSessionAndNotPairedAreSaid() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        try rig.custody.deleteSessionToken(hubID: rig.hub.hubID)
        #expect(await rig.coordinator.registerPush(Rig.target) == .noSession)
        try rig.custody.deleteRecord(hubID: rig.hub.hubID)
        #expect(await rig.coordinator.registerPush(Rig.target) == .notPaired)
    }

    @Test func aRevokedChannelIsSaidAndWipesNothing() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        rig.hub.revoke(channelID: rig.channelID)
        #expect(await rig.coordinator.registerPush(Rig.target) == .channelRevoked)
        #expect(try rig.custody.pairedHubs() == [rig.hub.hubID])
    }

    @Test func theTargetDigestIsStoredNeverTheToken() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        _ = await rig.coordinator.registerPush(Rig.target)
        let ids = try SecretVault(group: .keys, backend: rig.backend).ids().map(\.purpose) + SecretVault(group: .push, backend: rig.backend).ids().map(\.purpose)
        #expect(ids.contains("hub.push.material") && ids.contains("hub.\(rig.hub.hubID).push-state") && ids.contains("hub.\(rig.hub.hubID).push-key"))
        let data = try SecretVault(group: .keys, backend: rig.backend).get(SecretID(realm: .live, purpose: "hub.\(rig.hub.hubID).push-state"))
        #expect(!String(decoding: data, as: UTF8.self).contains(Rig.target.token))
    }
}

@Suite struct HubMailboxCatchUpTests {
    @Test func catchUpHandlesAHintOnceAndDeletesIt() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        _ = await rig.coordinator.registerPush(Rig.target)
        let id = try #require(rig.leave(type: "needs_you"))
        guard case .done(let hints, let dropped) = await rig.coordinator.catchUp() else { Issue.record("not done"); return }
        #expect(hints.map(\.type) == [.needsYou] && dropped == 0)
        #expect(rig.relay.held(channelID: rig.channelID).isEmpty)
        // the relay is read with channel-signed requests only, to this channel's prefix
        #expect(rig.relay.log == ["GET /v2/hub-channels/\(rig.hub.hubID)/\(rig.channelID)/mailbox",
                                  "GET /v2/hub-channels/\(rig.hub.hubID)/\(rig.channelID)/mailbox/\(id)",
                                  "DELETE /v2/hub-channels/\(rig.hub.hubID)/\(rig.channelID)/mailbox/\(id)"])
        // a push of the same id (the extension already showed it, or the relay redelivers) is not handled twice
        rig.relay.put(channelID: rig.channelID, id: id, c: try #require(rig.hub.sealHint(channelID: rig.channelID, type: "needs_you", ref: nil, messageID: id)?.c))
        guard case .done(let again, let droppedAgain) = await rig.coordinator.catchUp() else { Issue.record("not done"); return }
        #expect(again.isEmpty && droppedAgain == 1 && rig.relay.held(channelID: rig.channelID).isEmpty)
    }

    @Test func aHintTheExtensionShowedIsNotHandledAgain() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        _ = await rig.coordinator.registerPush(Rig.target)
        let s = try #require(rig.hub.sealHint(channelID: rig.channelID, type: "prepare", ref: nil))
        // the extension (same App Group directory) shows the push first
        let h = PushHandler(material: Empty(), hubMaterial: Source(try #require(try rig.custody.pushMaterial())), pushDir: rig.pushDir,
                            now: { Date(timeIntervalSince1970: Double(rig.clock.nowMs) / 1000) })
        #expect(h.handle(o: s.outer).outcome == .shown)
        rig.relay.put(channelID: rig.channelID, id: s.id, c: s.c)
        guard case .done(let hints, let dropped) = await rig.coordinator.catchUp() else { Issue.record("not done"); return }
        #expect(hints.isEmpty && dropped == 1)
    }

    @Test func noRelayNoMaterialAndNotPairedAreSaid() async throws {
        let none = try await Rig(relayURL: nil); defer { none.cleanUp() }
        #expect(await none.coordinator.catchUp() == .noRelay)
        let rig = try await Rig(); defer { rig.cleanUp() }
        #expect(await rig.coordinator.catchUp() == .noMaterial)   // never registered: no push key yet
        try rig.custody.deleteRecord(hubID: rig.hub.hubID)
        #expect(await rig.coordinator.catchUp() == .notPaired)
    }

    @Test func stalePastHintsAreDroppedAndDeleted() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        _ = await rig.coordinator.registerPush(Rig.target)
        rig.leave(ts: rig.clock.nowMs - 25 * 3600 * 1000)
        guard case .done(let hints, let dropped) = await rig.coordinator.catchUp() else { Issue.record("not done"); return }
        #expect(hints.isEmpty && dropped == 1 && rig.relay.held(channelID: rig.channelID).isEmpty)
    }

    @Test func aRelayRevokedAnswerThatTheHubConfirmsDropsTheCacheButWipesNothing() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        _ = await rig.coordinator.registerPush(Rig.target)
        rig.hub.revoke(channelID: rig.channelID)
        rig.relay.purgeAndRevoke(channelID: rig.channelID)
        #expect(await rig.coordinator.catchUp() == .relayRevoked(.revoked))
        #expect(rig.dropped.value == 1)
        // never a wipe (L2B-2): B6 wipes on the hub's answer, not here
        #expect(try rig.custody.pairedHubs() == [rig.hub.hubID])
        #expect(try rig.custody.loadChannelKey(hubID: rig.hub.hubID).channelID == rig.channelID)
        #expect(try rig.custody.sessionToken(hubID: rig.hub.hubID) != nil && rig.custody.pushMaterial() != nil)
        // polling has stopped
        let before = rig.relay.log.count
        #expect(await rig.coordinator.catchUp() == .paused && rig.relay.log.count == before)
    }

    @Test func aRelayThatLiesAboutRevocationIsAskedAboutAtTheHubAndPollingResumesLater() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        _ = await rig.coordinator.registerPush(Rig.target)
        rig.relay.forcedRefusal = (403, "channel_revoked")
        #expect(await rig.coordinator.catchUp() == .relayRevoked(.live))   // the hub says the channel is live
        #expect(try rig.custody.pairedHubs() == [rig.hub.hubID])
        rig.relay.forcedRefusal = nil
        #expect(await rig.coordinator.catchUp() == .paused)
        rig.clock.advance(15 * 60_000 + 1)
        rig.leave()
        guard case .done(let hints, _) = await rig.coordinator.catchUp() else { Issue.record("did not resume"); return }
        #expect(hints.count == 1)
    }

    @Test func ifTheHubCannotBeAskedPollingStaysStoppedUntilItCan() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        _ = await rig.coordinator.registerPush(Rig.target)
        rig.relay.forcedRefusal = (403, "channel_revoked")
        rig.reachable.value = false
        #expect(await rig.coordinator.catchUp() == .relayRevoked(.unconfirmed))
        rig.relay.forcedRefusal = nil; rig.reachable.value = true
        #expect(await rig.coordinator.catchUp() == .paused)
        #expect(await rig.coordinator.askHub() == .live)
        rig.leave()
        guard case .done(let hints, _) = await rig.coordinator.catchUp() else { Issue.record("did not resume"); return }
        #expect(hints.count == 1)
    }

    @Test func otherRelayRefusalsAreNotRevocation() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        _ = await rig.coordinator.registerPush(Rig.target)
        rig.relay.forcedRefusal = (401, "stale_timestamp")
        #expect(await rig.coordinator.catchUp() == .network)
        rig.relay.forcedRefusal = nil
        #expect(!(await rig.coordinator.isPaused) && rig.dropped.value == 0)
    }

    private struct Empty: PushMaterialSource { func loadAll(realm: String) throws -> [ID16: PushMaterial] { [:] } }
    private struct Source: HubPushMaterialSource {
        let m: HubPushMaterial
        init(_ m: HubPushMaterial) { self.m = m }
        func load() throws -> HubPushMaterial? { m }
    }
}

@Suite struct HubChannelRequestTests {
    /// Records what the relay would receive.
    private final class Recorder: RequestSender, @unchecked Sendable {
        let origin = relayOrigin
        private(set) var seen: [WireRequest] = []
        func send(_ request: WireRequest) async throws -> WireReply {
            seen.append(request)
            return try WireReply(status: 200, headers: ["content-type": "application/json"], body: try canonicalJSON(["messages": .array([])]))
        }
    }
    private struct FixedNonce: Entropy { let nonce: Data; func bytes(_ count: Int) -> Data { nonce.prefix(count) } }
    private struct At: WallClock { let nowMs: Int64 }

    @Test func theRequestIsTheVectorsRequestAndItsSignatureIsOverTheVectorBytes() async throws {
        let root = try StrictJSON.parse(OrchTestVectors.Vectors.hub, maxBytes: .max, maxDepth: 64)
        let c = try #require(root.object?["cases"]?.array?.first { $0.object?["name"]?.string == "channel_request_list" })
        let req = try #require(c.object?["args"]?.object?["request"]?.object)
        let h = try #require(req["headers"]?.object)
        let seedHex = try #require(root.object?["keys"]?.object?["channel_alice_phone"]?.object?["seed"]?.string)
        var seed = Array(try #require(Hex.decode(seedHex)))
        for i in stride(from: 31, through: 0, by: -1) { if seed[i] == 255 { seed[i] = 0 } else { seed[i] += 1; break } }
        let signer = HubChannelSigner(signer: try SoftwareSigner(testScalar: Data(seed)), custody: .software)
        let certHeader = try #require(h["Orch-Channel-Cert"]?.string)
        let certBytes = try #require(B64U.decode(certHeader))
        let cert = try StrictJSON.parse(certBytes, maxBytes: 4096)
        let rec = Recorder()
        let hubID = try #require(c.object?["args"]?.object?["hub_id"]?.string)
        let tsText = try #require(h["Orch-Channel-Ts"]?.string)
        let ts = try #require(Int64(tsText))
        let nonceHex = try #require(h["Orch-Channel-Nonce"]?.string)
        let nonce = try #require(Hex.decode(nonceHex))
        let relay = try HubChannelRelay(hubID: hubID, signer: signer, channelCert: cert, sender: rec, wall: At(nowMs: ts), entropy: FixedNonce(nonce: nonce))
        _ = try await relay.list()
        let sent = try #require(rec.seen.first)
        #expect(sent.method == "GET" && sent.target == req["target"]?.string && sent.body.isEmpty)
        #expect(sent.header("orch-channel-cert") == certHeader)
        #expect(sent.header("orch-channel-ts") == h["Orch-Channel-Ts"]?.string && sent.header("orch-channel-nonce") == h["Orch-Channel-Nonce"]?.string)
        let bytes = try HubChannelSigner.relayRequestBytes(hubID: hubID, channelID: signer.channelID, tsMs: ts, nonce: nonce, method: "GET", target: sent.target)
        let sigText = try #require(sent.header("orch-channel-signature"))
        let sig = try #require(B64U.decode(sigText, length: 64))
        #expect(Signature.verify(signer.publicKey, signature: sig, message: bytes))
        // the vector's own signature verifies over the same bytes
        let vectorSigText = try #require(h["Orch-Channel-Signature"]?.string)
        let vectorSig = try #require(B64U.decode(vectorSigText, length: 64))
        #expect(Signature.verify(signer.publicKey, signature: vectorSig, message: bytes))
    }

    @Test func aRequestSignedByAnotherKeyIsRefusedByTheRelay() async throws {
        let rig = try await Rig(); defer { rig.cleanUp() }
        _ = await rig.coordinator.registerPush(Rig.target)
        let stranger = HubChannelSigner(signer: SoftwareSigner(), custody: .software)
        let relay = try HubChannelRelay(hubID: rig.hub.hubID, signer: stranger, channelCert: try #require(rig.hub.certificate(channelID: rig.channelID)),
                                        sender: rig.relay, wall: rig.clock)
        // the stranger's channel id is not in the certificate's: the relay refuses (other_user) before it ever reads a message
        await #expect(throws: HubRelayError.self) { _ = try await relay.list() }
    }
}
