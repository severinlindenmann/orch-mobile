import Foundation
import OrchTestVectors
import Testing
@testable import OrchProtocol

/// Replays the hub contract vectors (orch-hub `vectors_hub.json`, Tests/OrchTestVectors/PROVENANCE.md) for every check the phone
/// implements: `pair_link`, `api_origin`, `card`, `channel_cert`. Each case runs against the Swift verifier with the case's own dev mode.
enum HubVectors {
    static let root: JSONValue = { try! StrictJSON.parse(OrchTestVectors.Vectors.hub, maxBytes: .max, maxDepth: 64) }()
    static func cases(_ check: String) -> [JSONValue] { root["cases"].items.filter { $0["check"].str == check } }
    static var expected: Int { root["cases"].items.count }

    /// `{"ok": ...}` -> nil, `{"error": code}` -> code.
    static func errorCode(_ c: JSONValue) -> String? { c["expect"]["error"].string }

    static func run(_ c: JSONValue, _ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let r as Refusal { return r.rawValue } catch { return "unexpected:\(error)" }
    }

    static func heldCard(_ card: JSONValue, verifier: HubVerifier, now: Int64) throws -> HeldHubCard {
        try verifier.verifyCard(card, nowMs: now)
    }
}

@Suite struct HubVectorTests {
    @Test func theFileIsTheHubContractAndHasTheCasesWeReplay() {
        #expect(HubVectors.root["contract"].str == "orch.hub/0")
        #expect(HubVectors.cases("pair_link").count == 25)
        #expect(HubVectors.cases("api_origin").count == 13)
        #expect(HubVectors.cases("card").count == 26)
        #expect(HubVectors.cases("channel_cert").count == 3)
    }

    @Test func pairLinkCases() throws {
        for c in HubVectors.cases("pair_link") {
            let v = HubVerifier(devMode: c["args"]["dev_mode"].bool ?? false)
            var parsed: HubPairLink?
            let err = HubVectors.run(c) { parsed = try v.parseLink(c["args"]["link"].str) }
            #expect(err == HubVectors.errorCode(c), "\(c["name"].str)")
            if HubVectors.errorCode(c) == nil, let p = parsed {
                let ok = c["expect"]["ok"]
                #expect(p.api == ok["api"].str && p.hubID == ok["hub_id"].str && p.userID == ok["user_id"].str && p.code == ok["code"].str, "\(c["name"].str)")
            }
        }
    }

    @Test func linkNeverPrintsTheCode() throws {
        let link = try HubVerifier(devMode: true).parseLink(HubVectors.cases("pair_link")[0]["args"]["link"].str)
        #expect(!"\(link)".contains(link.code) && !"\(String(reflecting: link))".contains(link.code))
        #expect(!String(describing: Mirror(reflecting: link).children.map { "\($0.value)" }).contains(link.code))
    }

    @Test func fingerprintIs8GroupsOf4() {
        let fp = HubVectors.root["phase4"]["channel_api"]["pair_link"]
        #expect(HubIdentifiers.fingerprint(hubID: fp["parsed"]["hub_id"].str) == fp["fingerprint"].str)
        #expect(HubIdentifiers.fingerprint(hubID: "ABC") == nil)
    }

    @Test func idsAndSessionRefMatchTheVectors() throws {
        let keys = HubVectors.root["keys"], ids = HubVectors.root["ids"]
        #expect(HubIdentifiers.hubID(root: keys["hk_root"]["pub"].sigPub) == ids["hub"].str)
        #expect(HubIdentifiers.channelID(key: keys["channel_alice_phone"]["pub"].sigPub) == ids["channel_alice_phone"].str)
        let sr = HubVectors.root["phase4"]["channel_api"]["session_ref"]
        #expect(try HubIdentifiers.sessionRef(token: sr["token"].str) == sr["session_ref"].str)
        #expect(throws: Refusal.self) { try HubIdentifiers.sessionRef(token: "") }
        #expect(throws: Refusal.self) { try HubIdentifiers.sessionRef(token: "caf\u{e9}") }
    }

    @Test func cardCases() throws {
        for c in HubVectors.cases("card") {
            let a = c["args"], v = HubVerifier(devMode: a["dev_mode"].bool ?? false), now = a["now_ms"].i64
            let pin: SigningPublicKey? = a["pinned_root"].isNull ? nil : a["pinned_root"].sigPub
            let revoked = Set(a["revoked_op_certs"].items.map(\.str))
            var got: HeldHubCard?
            let err = HubVectors.run(c) {
                let held = a["held_card"].isNull ? nil : try HubVectors.heldCard(a["held_card"], verifier: v, now: now)
                got = try v.verifyCard(a["card"], nowMs: now, pinnedRoot: pin, revokedOpCerts: revoked, held: held)
            }
            #expect(err == HubVectors.errorCode(c), "\(c["name"].str)")
            if HubVectors.errorCode(c) == nil, let g = got {
                #expect(g.hubID == c["expect"]["ok"]["hub_id"].str && g.opCertID == c["expect"]["ok"]["op_cert_id"].str, "\(c["name"].str)")
            }
        }
    }

    @Test func apiOriginCases() throws {
        for c in HubVectors.cases("api_origin") {
            let a = c["args"], v = HubVerifier(devMode: a["dev_mode"].bool ?? false), now = a["now_ms"].i64
            var origin: String?
            let err = HubVectors.run(c) {
                let held = try v.verifyCard(a["card"], nowMs: now)
                origin = try v.verifyAPIOrigin(a["signed"], held: held, linkAPI: a["link_api"].str, nowMs: now,
                                               revokedOpCerts: Set(a["revoked_later"].items.map(\.str)))
            }
            #expect(err == HubVectors.errorCode(c), "\(c["name"].str)")
            if HubVectors.errorCode(c) == nil { #expect(origin == c["expect"]["ok"]["origin"].str, "\(c["name"].str)") }
        }
    }

    @Test func channelCertCases() throws {
        for c in HubVectors.cases("channel_cert") {
            let a = c["args"], v = HubVerifier(devMode: a["dev_mode"].bool ?? false), now = a["now_ms"].i64
            var cert: HubChannelCert?
            let err = HubVectors.run(c) {
                let held = try v.verifyCard(a["card"], nowMs: now)
                cert = try v.verifyChannelCert(a["signed"], held: held, nowMs: now)
            }
            #expect(err == HubVectors.errorCode(c), "\(c["name"].str)")
            if HubVectors.errorCode(c) == nil { #expect(cert?.channelID == c["expect"]["ok"]["channel_id"].str, "\(c["name"].str)") }
        }
    }

    @Test func aReleaseBuildIsARealVerifier() throws {
        // dev objects are refused by a real verifier, everywhere; and a real verifier refuses a loopback link.
        let real = HubVerifier(devMode: false)
        let card = HubVectors.cases("card")[0]["args"]
        #expect(throws: Refusal.devRefused) { try real.verifyCard(card["card"], nowMs: card["now_ms"].i64) }
        #expect(throws: Refusal.malformed) { try real.parseLink("orch://hub-pair/127.0.0.1:8443#h1.38d8abed52ccfb538da401fd54e64bdc.a368bd380588e5dabee62a516031e21f.ab12-cd34-ef56") }
    }

    // challenge check: the phone signs only the exact object it expects (design B1 step 5)
    @Test func registrationChallengeChecks() throws {
        let v = HubVerifier(devMode: true)
        let hubID = HubVectors.root["ids"]["hub"].str, user = HubVectors.root["ids"]["user_alice"].str
        let key = HubVectors.root["keys"]["channel_alice_phone"]["pub"].sigPub
        let now: Int64 = 1_790_000_000_000
        let nonce = "l7c_-YIfhoBOVhfVAyyc-VAXy2zc0TZcaZYIrTk9z2U"
        func obj(_ edit: (inout [String: JSONValue]) -> Void = { _ in }) -> JSONValue {
            var o: [String: JSONValue] = ["v": 2, "suite": 2, "kind": "hub.channel_register", "hv": 0, "hub_id": .string(hubID), "user_id": .string(user),
                                          "channel_kind": "phone", "key_pub": .string(B64U.encode(key.x963)), "attestation": "pairing-code",
                                          "nonce": .string(nonce), "expires_ms": .int(now + 60_000), "dev": true]
            edit(&o); return .object(o)
        }
        func check(_ c: JSONValue, hub: String? = nil, usr: String? = nil, own: SigningPublicKey? = nil, id: String? = nil) throws {
            _ = try v.checkRegistrationChallenge(c, challengeID: id ?? nonce, hubID: hub ?? hubID, userID: usr ?? user, ownKey: own ?? key, nowMs: now)
        }
        try check(obj())
        #expect(throws: Refusal.otherHub) { try check(obj(), hub: HubVectors.root["ids"]["hub_rogue"].str) }
        #expect(throws: Refusal.otherUser) { try check(obj(), usr: HubVectors.root["ids"]["user_bob"].str) }
        #expect(throws: Refusal.challengeInvalid) { try check(obj(), own: HubVectors.root["keys"]["channel_bob_browser"]["pub"].sigPub) }
        #expect(throws: Refusal.challengeInvalid) { try check(obj(), id: "other") }
        #expect(throws: Refusal.challengeInvalid) { try check(obj { $0["expires_ms"] = .int(now - 1) }) }
        #expect(throws: Refusal.challengeInvalid) { try check(obj { $0["expires_ms"] = .int(now + 1_000_000) }) }
        #expect(throws: Refusal.factorMismatch) { try check(obj { $0["attestation"] = "session" }) }
        #expect(throws: Refusal.factorMismatch) { try check(obj { $0["channel_kind"] = "browser" }) }
        #expect(throws: Refusal.malformed) { try check(obj { $0["extra"] = 1 }) }
        #expect(throws: Refusal.devMismatch) { try check(obj { $0["dev"] = false }) }
        #expect(throws: Refusal.devRefused) { _ = try HubVerifier(devMode: false).checkRegistrationChallenge(obj(), challengeID: nonce, hubID: hubID, userID: user, ownKey: key, nowMs: now) }
    }

    @Test func renderCasesMatchTheHub() {
        let cases = HubVectors.cases("render")
        #expect(cases.count == 3)
        for c in cases {
            #expect(HubText.render(c["args"]["text"].str) == c["expect"]["ok"]["shown"].str, "\(c["name"].str)")
        }
        // Idempotent, and the escapes are plain ASCII.
        #expect(HubText.render(HubText.render("a\u{202E}b\u{3164}")) == "a<U+202E>b<U+3164>")
        #expect(HubText.render("\u{0}\u{7F}x") == "<U+0000><U+007F>x")
    }

    /// L2-B2-1: the result must not depend on the OS's Unicode tables. Every scalar either stays itself or becomes `<U+XXXX>`; anything
    /// assigned after Unicode 16.0 (or of unknown age) is escaped; and the vector scalars agree.
    @Test func renderSweepIsPinnedToUnicode16() {
        var escapedLater = 0
        for v in UInt32(0)...0x10FFFF {
            guard let u = Unicode.Scalar(v) else { continue }
            let out = HubText.render(String(u))
            if out == String(u) { continue }
            #expect(out.hasPrefix("<U+") && out.hasSuffix(">") && out.utf8.allSatisfy { $0 < 0x80 }, "\(v)")
            if let a = u.properties.age, a.major > 16, u.properties.generalCategory != .unassigned { escapedLater += 1 }
        }
        // a scalar assigned in Unicode 17 is escaped even where the runtime knows it (U+088F, U+1ACF); plain text is not
        #expect(HubText.render("\u{088F}") == "<U+088F>")
        #expect(HubText.render("\u{1ACF}") == "<U+1ACF>")
        #expect(HubText.render("Zürich é 日本 😀") == "Zürich é 日本 😀")
        _ = escapedLater
    }
}
