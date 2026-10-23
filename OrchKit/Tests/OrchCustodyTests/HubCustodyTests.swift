import CryptoKit
import Foundation
import OrchTestVectors
import Testing
@testable import OrchCustody
@testable import OrchProtocol

/// The hub channel signer and the hub key custody against orch-hub's vectors (`vectors_hub.json`, FAKE keys): the phone builds the
/// objects the hub checks, so its signed bytes must equal the vectors' bytes. ECDSA here is randomised, so equality is checked on the
/// object and by verifying under the vector key.
private enum HV {
    static let root: JSONValue = { try! StrictJSON.parse(OrchTestVectors.Vectors.hub, maxBytes: .max, maxDepth: 64) }()
    static var keys: JSONValue { root["keys"] }
    static var api: JSONValue { root["phase4"]["channel_api"] }
    static let now: Int64 = 1_790_000_000_000

    static func scalar(_ name: String) -> Data { scalarFromSeed(Hex.decode(keys[name]["seed"].str!)!) }
    static func signer(_ name: String) -> HubChannelSigner {
        HubChannelSigner(signer: try! SoftwareSigner(testScalar: scalar(name)), custody: .software)
    }
}

private extension JSONValue {
    subscript(_ k: String) -> JSONValue { object?[k] ?? .null }
    var items: [JSONValue] { array ?? [] }
    var str: String! { string }
    var pub: SigningPublicKey { try! SigningPublicKey(x963: B64U.decode(string!)!) }
}

/// `d = int(seed) mod (n-1) + 1` (the vectors' key derivation; the seeds used here are far below n-1).
private func scalarFromSeed(_ seed: Data) -> Data {
    var s = Array(seed)
    for i in stride(from: 31, through: 0, by: -1) { if s[i] == 255 { s[i] = 0 } else { s[i] += 1; break } }
    return Data(s)
}

@Suite struct HubChannelSignerTests {
    let alice = HV.signer("channel_alice_phone")

    @Test func theTestKeyIsTheVectorKey() {
        #expect(alice.publicKey == HV.keys["channel_alice_phone"]["pub"].pub)
        #expect(alice.channelID == HV.root["ids"]["channel_alice_phone"].str)
    }

    private func verify(_ signed: JSONValue, label: String, key: SigningPublicKey) throws {
        let sig = B64U.decode(signed["sig"].str, length: 64)!
        #expect(Signature.verify(key, signature: sig, label: label, message: try canonicalJSON(signed["o"])))
    }

    @Test func registerSignsTheChallengeTheVerifierAccepted() throws {
        let c = HV.root["cases"].items.first { $0["name"].str == "channel_register_phone_pairing" }!
        let expected = c["args"]["signed"]
        let v = HubVerifier(devMode: true)
        let ch = try v.checkRegistrationChallenge(expected["o"], challengeID: expected["o"]["nonce"].str, hubID: HV.root["ids"]["hub"].str,
                                                  userID: HV.root["ids"]["user_alice"].str, ownKey: alice.publicKey, nowMs: HV.now)
        let signed = try alice.register(ch)
        #expect(signed["o"] == expected["o"])
        try verify(signed, label: Label.sigHubChannelRegister, key: alice.publicKey)
        // the vector's own signature verifies over the same bytes, so our bytes are the hub's bytes
        try verify(expected, label: Label.sigHubChannelRegister, key: alice.publicKey)
    }

    @Test func registerRefusesAChallengeForAnotherKey() throws {
        let bob = HV.signer("channel_bob_browser")
        let o = HV.root["cases"].items.first { $0["name"].str == "channel_register_phone_pairing" }!["args"]["signed"]["o"]
        let ch = try HubVerifier(devMode: true).checkRegistrationChallenge(o, challengeID: o["nonce"].str, hubID: HV.root["ids"]["hub"].str,
                                                                          userID: HV.root["ids"]["user_alice"].str, ownKey: alice.publicKey, nowMs: HV.now)
        #expect(throws: Refusal.challengeInvalid) { try bob.register(ch) }
    }

    @Test func channelAuthMatchesTheVector() throws {
        let expected = HV.api["channel_auth"]
        let signed = try alice.channelAuth(hubID: HV.root["ids"]["hub"].str, userID: HV.root["ids"]["user_alice"].str,
                                           sessionToken: HV.api["session_ref"]["token"].str, nowMs: expected["o"]["ts_ms"].int!)
        #expect(signed["o"] == expected["o"])
        try verify(signed, label: Label.sigHubChannelAuth, key: alice.publicKey)
        try verify(expected, label: Label.sigHubChannelAuth, key: alice.publicKey)
    }

    @Test func channelAuthNamesTheSessionByHashNeverByToken() throws {
        let signed = try alice.channelAuth(hubID: HV.root["ids"]["hub"].str, userID: HV.root["ids"]["user_alice"].str,
                                           sessionToken: "SECRET-TOKEN-1", nowMs: HV.now)
        #expect(!String(decoding: try canonicalJSON(signed), as: UTF8.self).contains("SECRET-TOKEN"))
        #expect(throws: Refusal.malformed) { try alice.channelAuth(hubID: "zz", userID: HV.root["ids"]["user_alice"].str, sessionToken: "t", nowMs: 1) }
    }

    @Test func pushKeyMatchesTheVectorAndIsNeverTheChannelKey() throws {
        let expected = HV.api["channel_push"]
        let pushPub = try AgreementPublicKey(x963: B64U.decode(expected["o"]["push_pub"].str)!)
        let signed = try alice.pushKey(hubID: HV.root["ids"]["hub"].str, pushPub: pushPub, nowMs: expected["o"]["issued_ms"].int!)
        #expect(signed["o"] == expected["o"])
        try verify(signed, label: Label.sigHubChannelPush, key: alice.publicKey)
        try verify(expected, label: Label.sigHubChannelPush, key: alice.publicKey)
        let same = try AgreementPublicKey(x963: alice.publicKey.x963)
        #expect(throws: Refusal.malformed) { try alice.pushKey(hubID: HV.root["ids"]["hub"].str, pushPub: same, nowMs: 1) }
    }

    @Test func relayRequestBytesMatchTheVectors() throws {
        let hub = HV.root["ids"]["hub"].str!
        var seen = 0
        for c in HV.root["cases"].items where ["channel_request_list", "channel_request_get", "channel_request_delete"].contains(c["name"].str) {
            let r = c["args"]["request"], h = r["headers"]
            let nonce = Hex.decode(h["Orch-Channel-Nonce"].str)!, ts = Int64(h["Orch-Channel-Ts"].str)!
            let bytes = try HubChannelSigner.relayRequestBytes(hubID: hub, channelID: alice.channelID, tsMs: ts, nonce: nonce, method: r["method"].str, target: r["target"].str)
            // the vector's signature (made by the hub's reference over its bytes) verifies over OUR bytes
            #expect(Signature.verify(alice.publicKey, signature: B64U.decode(h["Orch-Channel-Signature"].str, length: 64)!, message: bytes), "\(c["name"].str)")
            let mine = try alice.relayRequest(hubID: hub, method: r["method"].str, target: r["target"].str, tsMs: ts, nonce: nonce)
            #expect(Signature.verify(alice.publicKey, signature: B64U.decode(mine, length: 64)!, message: bytes))
            seen += 1
        }
        #expect(seen == 3)
        #expect(HV.api["channel_request"]["signed_hex"].str == Hex.encode(try HubChannelSigner.relayRequestBytes(
            hubID: hub, channelID: alice.channelID, tsMs: 1_790_000_000_000, nonce: Hex.decode("7b0614dc2be801c01dffbb4f0336a4e8")!,
            method: "GET", target: "/v2/hub-channels/\(hub)/\(alice.channelID)/mailbox")))
    }

    @Test func relayRequestSignsOnlyThisChannelsMailbox() {
        let hub = HV.root["ids"]["hub"].str!, nonce = Data(count: 16), item = String(repeating: "a", count: 32)
        let own = "/v2/hub-channels/\(hub)/\(alice.channelID)/mailbox"
        let bobCh = HV.root["ids"]["channel_bob_browser"].str!
        for (m, t) in [("POST", own), ("DELETE", own), ("GET", own + "?x=1"), ("GET", own + "/"), ("GET", own + "/nothex"),
                       ("GET", "/v2/hub-channels/\(hub)/\(bobCh)/mailbox"), ("GET", "/v2/hubs/\(hub)/mailbox"),
                       ("GET", "/v2/hub-channels/\(HV.root["ids"]["hub_rogue"].str!)/\(alice.channelID)/mailbox"), ("GET", own + "/" + item + "/x"),
                       ("GET", "/v2/hub-channels/\(hub)/\(alice.channelID)/mailbox/../x")] {
            #expect(throws: Refusal.malformed, "\(m) \(t)") { try alice.relayRequest(hubID: hub, method: m, target: t, tsMs: 1, nonce: nonce) }
        }
        #expect(throws: Refusal.malformed) { try alice.relayRequest(hubID: hub, method: "GET", target: own, tsMs: 1, nonce: Data(count: 15)) }
        #expect((try? alice.relayRequest(hubID: hub, method: "DELETE", target: own + "/" + item, tsMs: 1, nonce: nonce)) != nil)
    }

    @Test func proofIsOverADigestComputedHere() throws {
        let p = HV.root["phase4"]["prepare"]
        let proof = try alice.proof(context: p["ctx"])
        #expect(Hex.encode(proof.digest) == p["digest_hex"].str)
        let signedBytes = Data(Label.sigHubChannelProof.utf8) + proof.digest
        #expect(Hex.encode(signedBytes) == HV.root["custodial"]["proof_signed_hex"].str)
        #expect(Signature.verify(alice.publicKey, signature: B64U.decode(proof.proof, length: 64)!, message: signedBytes))
        // a channel_proof inside the context is never part of the digest
        var ctx = p["ctx"].object!, event = ctx["event"]!.object!
        event["channel_proof"] = .string("x")
        ctx["event"] = .object(event)
        #expect(try alice.proof(context: .object(ctx)).digest == proof.digest)
        // the digest follows the context
        event["type"] = "gate.rejected"
        ctx["event"] = .object(event)
        #expect(try alice.proof(context: .object(ctx)).digest != proof.digest)
        #expect(throws: Refusal.malformed) { try alice.proof(context: .object(["contract": 1])) }
    }
}

@Suite struct HubKeyCustodyTests {
    let hub = HV.root["ids"]["hub"].str!

    func make() -> (HubKeyCustody, InMemoryVaultBackend) {
        let b = InMemoryVaultBackend()
        return (HubKeyCustody(keys: SecretVault(group: .keys, backend: b), push: SecretVault(group: .push, backend: b)), b)
    }

    @Test func channelKeyCreateLoadDelete() throws {
        let (c, _) = make()
        #expect(throws: CustodyError.missing) { try c.loadChannelKey(hubID: hub) }
        let s = try c.createChannelKey(hubID: hub)
        #expect(try c.loadChannelKey(hubID: hub).publicKey == s.publicKey)
        #expect(throws: CustodyError.alreadyExists) { try c.createChannelKey(hubID: hub) }
        try c.deleteChannelKey(hubID: hub)
        #expect(throws: CustodyError.missing) { try c.loadChannelKey(hubID: hub) }
        #expect(throws: CustodyError.vault(.badName)) { try c.createChannelKey(hubID: "not-a-hub-id") }
    }

    @Test func hubItemsLiveInTheirOwnNamespaceAndGroups() throws {
        let (c, b) = make()
        _ = try c.createChannelKey(hubID: hub); _ = try c.createPushKey(hubID: hub)
        try c.putSessionToken("tok", hubID: hub); try c.putRecord(Data("r".utf8), hubID: hub)
        let keyIDs = try SecretVault(group: .keys, backend: b).ids().map(\.purpose).sorted()
        let pushIDs = try SecretVault(group: .push, backend: b).ids().map(\.purpose)
        #expect(keyIDs == ["hub.\(hub).channel-key", "hub.\(hub).record", "hub.\(hub).session"])
        #expect(pushIDs == ["hub.\(hub).push-key"])
        // never workspace-scoped (so the workspace clean-up of direct pairings cannot touch it)
        #expect(try SecretVault(group: .keys, backend: b).ids().allSatisfy { $0.ws == nil && $0.realm == .live })
        #expect(try SecretVault(group: .keys, backend: b).wipeUnindexed(realm: .live, knownWorkspaces: []).isEmpty)
        #expect(try c.pairedHubs() == [hub])
        try c.deleteAll(hubID: hub)
        #expect(try SecretVault(group: .keys, backend: b).ids().isEmpty && SecretVault(group: .push, backend: b).ids().isEmpty)
    }

    @Test func aDirectModeWipeNeverRemovesTheHubPairing() throws {
        let (c, b) = make()
        _ = try c.createChannelKey(hubID: hub); _ = try c.createPushKey(hubID: hub)
        try c.putSessionToken("tok", hubID: hub); try c.putRecord(Data("r".utf8), hubID: hub)
        let keys = SecretVault(group: .keys, backend: b), push = SecretVault(group: .push, backend: b)
        // a direct-mode device identity and workspace item in the same groups
        try keys.put(Data("dk".utf8), for: SecretID(realm: .live, purpose: "dk_sig"))
        try keys.put(Data("x".utf8), for: SecretID(realm: .live, ws: String(repeating: "a", count: 32), purpose: "wk"))
        // first direct Live entry, Leave Live, interrupted reset: all run the realm wipe
        try keys.wipe(realm: .live); try push.wipe(realm: .live)
        try keys.wipeUnindexed(realm: .live, knownWorkspaces: [])
        #expect(try keys.ids().map(\.purpose).sorted() == ["hub.\(hub).channel-key", "hub.\(hub).record", "hub.\(hub).session"])
        #expect(try push.ids().map(\.purpose) == ["hub.\(hub).push-key"])
        #expect(try c.loadChannelKey(hubID: hub).channelID.count == 32 && c.pairedHubs() == [hub])
        // only Reset removes it
        try keys.wipeHubItems(realm: .live); try push.wipeHubItems(realm: .live)
        #expect(try keys.ids().isEmpty && push.ids().isEmpty)
    }

    @Test func pushKeyOpensTheVectorHintAndNothingElse() throws {
        let ps = HV.root["phase4"]["relay_routes"]["push_seal"]
        let opener = try HubPushOpener(raw: scalarFromSeed(Hex.decode(HV.keys["push_alice_phone"]["seed"].str!)!))
        #expect(opener.publicKey.x963 == B64U.decode(HV.keys["push_alice_phone"]["pub"].str!))
        let ch = ps["channel_id"].str!, id = ps["msg_id"].str!
        let hint = try opener.openPush(sealed: ps["sealed"].str, hubID: hub, channelID: ch, messageID: id)
        #expect(hint.type == .prepare && hint.ref == ps["payload"]["ref"].str && hint.tsMs == ps["payload"]["ts_ms"].int)
        #expect(throws: Refusal.malformed) { try opener.openPush(sealed: ps["sealed"].str, hubID: HV.root["ids"]["hub_rogue"].str, channelID: ch, messageID: id) }
        #expect(throws: Refusal.malformed) { try opener.openPush(sealed: ps["sealed"].str, hubID: hub, channelID: HV.root["ids"]["channel_bob_browser"].str, messageID: id) }
        #expect(throws: Refusal.malformed) { try opener.openPush(sealed: ps["sealed"].str, hubID: hub, channelID: ch, messageID: String(repeating: "0", count: 32)) }
        #expect(throws: Refusal.malformed) { try opener.openPush(sealed: "AAAA", hubID: hub, channelID: ch, messageID: id) }
        // another recipient key cannot open it
        let (c, _) = make()
        let other = try c.createPushKey(hubID: hub)
        #expect(throws: Refusal.malformed) { try other.openPush(sealed: ps["sealed"].str, hubID: hub, channelID: ch, messageID: id) }
    }

    @Test func pushKeyRoundTripsThroughTheVault() throws {
        let (c, _) = make()
        let k = try c.createPushKey(hubID: hub)
        #expect(try c.loadPushKey(hubID: hub).publicKey == k.publicKey)
        try c.deletePushKey(hubID: hub)
        #expect(throws: CustodyError.missing) { try c.loadPushKey(hubID: hub) }
    }
}
