import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchTestVectors
@testable import OrchClient
@testable import OrchFakeHost
@testable import OrchProtocol

// Slice 2b vector gates (suites."2".bridge): host_cases pair_* (22) through FakeHost's own epoch-0 pipeline, pair_answers (20) through
// the phone's check, links (6) through the link parser. Each case asserts the action AND the resulting state.

@Suite struct PairingVectorTests {
    @Test func testPairHostCases() throws {
        let all = bridgeVectors()["host_cases"].items
        let cases = all.filter { $0["name"].str.hasPrefix("pair") }
        #expect(all.count == 47 && cases.count == 22 && cases.map { $0["name"].str } == pairingCaseNames)
        var ran = 0
        for c in cases {
            var core = hostCore(from: c["state"])
            let steps = c["steps"].items.isEmpty ? [c] : c["steps"].items
            for (n, s) in steps.enumerated() {
                let name = "\(c["name"].str)#\(n)", e = s["expect"]
                let result = core.check(s["envelope"].hexData, mailbox: s["mailbox_id"].string.flatMap { ID16(hex: $0) }, nowMs: s["now_ms"].i64)
                switch e["result"].str {
                case "pair_pending":
                    guard case .pair(.pending(let label, let certState, let sas, let answer), let h) = result else { Issue.record("\(name): \(result)"); continue }
                    if let l = e["label"].string { #expect(label == l, "\(name)") }
                    if let cs = e["cert_state"].string { #expect(certState == cs, "\(name)") }
                    if let want = e["sas"].string { #expect(sas == want, "\(name)") }
                    #expect(answer == e["answer"].v && h.epoch == 0, "\(name)")
                    // resulting state: the offer is used and the device has its pending pairing
                    #expect(core.offers[h.stream]?.used == true && core.pendingPairs[h.device]?.state == "pending", "\(name)")
                case "pair_status":
                    guard case .pair(.status(let answer), _) = result else { Issue.record("\(name): \(result)"); continue }
                    #expect(answer == e["answer"].v, "\(name)")
                case "refuse":
                    guard case .pair(.refuse(let code, let meta), _) = result else { Issue.record("\(name): \(result)"); continue }
                    var want = e.v.object!
                    want["result"] = nil; want["code"] = nil
                    var got = meta.object!; got["refusal"] = nil
                    #expect(code == e["code"].str && got == want, "\(name)")
                    // every refusal carries wsk_pub and counts against the offer's own budget
                    #expect(got["wsk_pub"] != nil, "\(name)")
                    let h = try Bridge.Parts(envelope: s["envelope"].hexData).header
                    #expect(core.offers[h.stream]?.unverified.count == 1 || c["name"].str == "pair_resend_then_other_key", "\(name)")
                case "drop":
                    #expect(result == .drop(e["why"].str), "\(name): \(result)")
                default: Issue.record("\(name): unknown result")
                }
                ran += 1
            }
        }
        #expect(ran == 24)           // 22 cases; pair_resend_then_other_key has 3 steps
    }

    @Test func testPairHostCaseStateAfterResendThenOtherKey() throws {
        let c = bridgeVectors()["host_cases"].items.first { $0["name"].str == "pair_resend_then_other_key" }!
        var core = hostCore(from: c["state"])
        for s in c["steps"].items { _ = core.check(s["envelope"].hexData, mailbox: ID16(hex: s["mailbox_id"].str), nowMs: s["now_ms"].i64) }
        #expect(core.pendingPairs.count == 1 && core.offers.values.first?.used == true)
        #expect(core.offers.values.first?.unverified.count == 1)         // only the other key's attempt was refused
    }

    // MARK: pair_answers

    func ctx(_ c: J) -> PairingWire.Context {
        let x = c["ctx"]
        return PairingWire.Context(workspace: x["workspace"].id, device: x["device"].id, offer: x["offer"].id, secret: SymmetricKey(data: x["secret"].hexData),
                                   wskPin: x["wsk_pin"].hexData, pkPin: x["pk_pin"].hexData,
                                   dkSig: try! SigningPublicKey(x963: B64U.decode(x["dk_sig_pub"].str)!), dkKx: try! AgreementPublicKey(x963: B64U.decode(x["dk_kx_pub"].str)!),
                                   offsetMs: x["offset_ms"].i64)
    }

    @Test func testPairAnswerVectors() throws {
        let cases = bridgeVectors()["pair_answers"].items
        #expect(cases.count == 20)
        var accepted = 0, dropped = 0, alarms = 0
        for c in cases {
            let name = c["name"].str, e = c["expect"]
            let env = c["envelope"].hexData
            let h = try Bridge.Parts(envelope: env).header
            var pending: [ID16: Bridge.PendingRequest] = [:]
            for (k, v) in c["ctx"]["pending"].v.object! { pending[ID16(hex: k)!] = Bridge.PendingRequest(next: UInt64(v.object!["next"]!.int!), epoch: 0) }
            let mailbox = Bridge.MailboxPosition(id: h.rid, index: h.seq, last: h.flagSet.contains(.last), stream: false)
            let (outcome, table) = PairingWire.check(env, context: ctx(c), pending: pending, mailbox: mailbox, nowMs: c["now_ms"].i64)
            switch outcome {
            case .accept(let a):
                accepted += 1
                #expect(e["result"].str == "accept", "\(name)")
                #expect(B64U.encode(a.wskPub.x963) == e["wsk_pub"].str, "\(name)")
                #expect(table[h.rid]?.next == (pending[h.rid]?.next ?? 0) + 1, "\(name)")        // resulting state: the chunk index advanced
                switch a.body {
                case .pending(_, let sas): #expect(e["state"].str == "pending" && sas == e["sas"].str, "\(name)")
                case .certPending(let label, _, let ch):
                    #expect(e["state"].str == "cert_pending" && label == e["primary_label"].str, "\(name)")
                    #expect(ch?.certCode == e["cert_code"].string, "\(name)")
                case .approved(let scopes, _, let cert, _, let epoch):
                    #expect(e["state"].str == "approved" && scopes == e["scopes"].items.map(\.str) && Int64(epoch) == e["epoch"].i64, "\(name)")
                    #expect(cert.deviceID.hex == e["device_id"].str, "\(name)")
                case .rejected: #expect(e["state"].str == "rejected", "\(name)")
                case .denied: Issue.record("\(name): the vectors carry no primary rejection")
                case .expired: #expect(e["state"].str == "expired", "\(name)")
                case .refusal(let code, _):
                    #expect(code == e["refusal"].str, "\(name)")
                    if let off = e["offset_ms"].int { #expect(a.offsetMs == off && !a.clockWrong, "\(name)"); #expect(table[h.rid]?.offsetAdopted == true, "\(name)") }
                }
            case .drop(let why, let alarm, _):
                dropped += 1
                #expect(e["result"].str == "drop" && e["why"].str == why, "\(name): \(why)")
                #expect((alarm != nil) == (e["alarm"].v.bool ?? false), "\(name)")
                if alarm != nil { alarms += 1 }
                #expect(table == pending, "\(name)")                                               // a dropped answer changes nothing
            }
        }
        #expect(accepted == 7 && dropped == 13 && alarms == 2)
    }

    // MARK: links

    @Test func testPairingLinkVectors() throws {
        let cases = bridgeVectors()["links"].items
        #expect(cases.count == 6)
        for c in cases {
            let f = PairingLink.parseFragment(c["fragment"].str)
            if c["parsed"].v.isNull {
                #expect(f == nil, "\(c["name"].str)")
            } else {
                let p = c["parsed"]
                #expect(f?.workspace.hex == p["workspace"].str && f?.offer.hex == p["offer"].str, "\(c["name"].str)")
                #expect(f?.secret == p["secret"].hexData && f?.wskPin == p["wsk_pin"].hexData && f?.pkPin == p["pk_pin"].hexData, "\(c["name"].str)")
            }
        }
        // whole links: canonical /app/pair, the /pair alias, orch:// with exactly one relay origin
        let frag = c0Fragment()
        let canon = try PairingLink.parse("https://relay.example.org/app/pair#" + frag)
        let alias = try PairingLink.parse("https://relay.example.org/pair#" + frag)
        #expect(canon == alias && canon.origin == "https://relay.example.org")
        #expect(try PairingLink.parse("https://relay.example.org:8443/app/pair#" + frag).origin == "https://relay.example.org:8443")
        #expect(try PairingLink.parse("orch://pair?relay=https%3A%2F%2Frelay.example.org#" + frag).origin == "https://relay.example.org")
        #expect(try PairingLink.parse("http://localhost:8787/app/pair#" + frag).origin == "http://localhost:8787")
        for bad in ["orch://pair#" + frag,                                              // no relay origin
                    "orch://pair?relay=https%3A%2F%2Fa.example.org&relay=https%3A%2F%2Fb.example.org#" + frag,
                    "orch://pair?relay=https%3A%2F%2Fa.example.org&x=1#" + frag,
                    "orch://pair?relay=http%3A%2F%2Fevil.example.org#" + frag,             // not a section 7.1 origin
                    "orch://pair?relay=https%3A%2F%2Fa.example.org%2Fpath#" + frag,
                    "orch://pair?relay=https%3A%2F%2Fuser%40a.example.org#" + frag,
                    "orch://pair?relay=%ZZ#" + frag,
                    "https://user@relay.example.org/app/pair#" + frag,                     // userinfo
                    "https://relay.example.org/other/pair#" + frag,
                    "https://relay.example.org/app/pair?x=1#" + frag,
                    "https://relay.example.org/app/pair/#" + frag,
                    "https://relay.example.org/app/pair",                                // no fragment
                    "ftp://relay.example.org/app/pair#" + frag,
                    "https://relay.example.org/app/pair#" + frag + ".extra",
                    "https://relay.example.org/app/pair#" + frag + "#" + frag,
                    "https://2130706433/app/pair#" + frag] {
            #expect(throws: PairingLink.Failure.self, "\(bad)") { _ = try PairingLink.parse(bad) }
        }
        // the secret is in no textual rendering
        let secret = B64U.encode(canon.secret)
        #expect(!"\(canon)".contains(secret) && !String(reflecting: canon).contains(secret) && !"\(Mirror(reflecting: canon).children.map { "\($0.value)" })".contains(secret))
    }

    func c0Fragment() -> String { String(bridgeVectors()["links"].items[0]["fragment"].str) }
}
