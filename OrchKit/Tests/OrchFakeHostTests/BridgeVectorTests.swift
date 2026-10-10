import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchProtocol
import OrchTestVectors
@testable import OrchFakeHost
@testable import OrchProtocol

// Gate for protocol section 8.6 / 8.8 vectors (suites."2".bridge). Each case is run for its resulting action AND resulting
// state, against FakeHost's own pipeline (host_cases) and against WorkspaceSession (device_cases), independently.
//
// host_cases: 47 in the file. 25 are epoch >= 1 requests and are run here. The other 22 (names starting "pair") are epoch-0
// pairing cases (section 8.3, K_pair, offers, cert_pending): slice 2b. They are counted and named below so that none is
// silently skipped, and so slice 2b can turn the expectation into a run.

let pairingCaseNames = [
    "pair_first_time", "pair_resend_then_other_key", "pair_unknown_offer_dropped", "pair_sealed_under_another_secret_dropped",
    "pair_expired_offer", "pair_device_id_not_of_key", "pair_signed_by_another_key", "pair_stale_timestamp",
    "pair_with_a_label_full_of_controls", "pair_with_existing_cert", "pair_with_another_persons_cert", "pair_with_a_cert_for_another_key",
    "pair_with_a_revoked_cert", "pair_meta_with_extra_field", "pair_other_op_at_epoch_0", "pair_status_pending", "pair_status_cert_pending",
    "pair_status_cert_pending_with_the_primarys_challenge", "pair_status_cert_pending_expired", "pair_status_approved",
    "pair_status_rejected", "pair_status_without_pairing",
]

func bridgeVectors() -> J { J(try! StrictJSON.parse(OrchTestVectors.Vectors.data, maxBytes: .max))["suites"]["2"]["bridge"] }

func keyFromHex(_ s: String) -> SymmetricKey { SymmetricKey(data: Hex.decode(s)!) }

func hostCore(from st: J) -> HostBridgeCore {
    var core = HostBridgeCore(workspace: st["workspace"].id, epoch: UInt32(st["epoch"].i64))
    for (k, v) in st["wk"].v.object ?? [:] { core.keys[UInt32(k)!] = keyFromHex(v.string!) }
    for (k, v) in st["members"].v.object ?? [:] { core.members[ID16(hex: k)!] = v.array!.map { $0.string! } }
    for (k, v) in st["certs"].v.object ?? [:] {
        core.devicePubs[ID16(hex: k)!] = try! SigningPublicKey(x963: B64U.decode(v.object!["dk_sig_pub"]!.string!)!)
    }
    core.revoked = Set((st["revoked"].v.array ?? []).map { ID16(hex: $0.string!)! })
    for (k, v) in st["seq"].v.object ?? [:] {
        core.seq[ID16(hex: k)!] = SeqWindow(high: UInt64(v.object?["high"]?.int ?? 0), bitmap: UInt64(bitPattern: v.object?["bitmap"]?.int ?? 0))
    }
    for (k, v) in st["rids"].v.object ?? [:] {
        let o = v.object!
        core.rids[ID16(hex: k)!] = RidRecord(device: ID16(hex: o["device"]!.string!)!, digest: Hex.decode(o["digest"]!.string!)!, outcome: nil, until: o["until"]!.int!)
    }
    for (k, v) in st["streams"].v.object ?? [:] { core.streams[ID16(hex: k)!] = ID16(hex: v.string!)! }
    core.unverified = (st["unverified"].v.array ?? []).map { $0.int! }
    if let per = st["limits"]["per_device"].int { core.limits.perDevice = Int(per) }
    return core
}

@Suite struct BridgeHostVectorTests {
    @Test func testHostCaseInventory() {
        let cases = bridgeVectors()["host_cases"].items
        #expect(cases.count == 47)
        let names = cases.map { $0["name"].str }
        let pairing = names.filter { $0.hasPrefix("pair") }
        #expect(pairing == pairingCaseNames)
        #expect(names.count - pairing.count == 25)
    }

    @Test func testBridgeHostCases() throws {
        var ran = 0
        for c in bridgeVectors()["host_cases"].items where !c["name"].str.hasPrefix("pair") {
            var core = hostCore(from: c["state"])
            let steps = c["steps"].items.isEmpty ? [c] : c["steps"].items
            for (n, s) in steps.enumerated() {
                let env = s["envelope"].hexData
                let mailbox = s["mailbox_id"].string.flatMap { ID16(hex: $0) }
                let result = core.check(env, mailbox: mailbox, nowMs: s["now_ms"].i64)
                let name = "\(c["name"].str)#\(n)"
                let e = s["expect"]
                switch e["result"].str {
                case "accept":
                    guard case .accept(let a) = result else { Issue.record("\(name): \(result)"); continue }
                    #expect(a.scopes == e["scopes"].items.map(\.str), "\(name)")
                    #expect(a.meta == e["meta"].v, "\(name)")
                    #expect(a.data == e["data"].hexData, "\(name)")
                case "refuse":
                    guard case .refuse(let r, let h) = result else { Issue.record("\(name): \(result)"); continue }
                    var want = e.v.object!
                    want["result"] = nil; want["code"] = nil
                    let stream = want.removeValue(forKey: "stream") != nil
                    #expect(r.code == e["code"].str, "\(name)")
                    var got = r.meta.object!; got["refusal"] = nil
                    #expect(got == want, "\(name)")
                    #expect(h.flagSet.contains(.stream) == stream, "\(name)")
                case "drop":
                    #expect(result == .drop(e["why"].str), "\(name): \(result)")
                default: Issue.record("\(name): unknown result")
                }
                ran += 1
            }
        }
        #expect(ran == 29)       // 25 cases; replayed_request has 2 steps, stale_epoch_consumes 3, repeated_sequence 2
    }

    @Test func testBridgeStateAfterCases() throws {
        // Resulting state: consumed sequence numbers, recorded rids, the refusal budget, stream ownership.
        var core = hostCore(from: bridgeVectors()["host_cases"].items.first { $0["name"].str == "stale_epoch_consumes_its_seq_then_a_new_request_runs" }!["state"])
        let steps = bridgeVectors()["host_cases"].items.first { $0["name"].str == "stale_epoch_consumes_its_seq_then_a_new_request_runs" }!["steps"].items
        for s in steps { _ = core.check(s["envelope"].hexData, mailbox: ID16(hex: s["mailbox_id"].str), nowMs: s["now_ms"].i64) }
        let dev = ID16(hex: "4177b27d8e4ac182e8d388b247d2b136")!
        #expect(core.seq[dev]!.high >= 3)
        #expect(core.rids.count == 3)                      // refusals are recorded before they are sent
        #expect(core.rids.values.filter { $0.outcome == nil }.count == 1)
        var spent = hostCore(from: bridgeVectors()["host_cases"].items.first { $0["name"].str == "refusal_budget_spent_drops_unverified" }!["state"])
        #expect(spent.unverified.count == 10)
        let before = spent.rids.count
        let c = bridgeVectors()["host_cases"].items.first { $0["name"].str == "refusal_budget_spent_drops_unverified" }!
        #expect(spent.check(c["envelope"].hexData, mailbox: nil, nowMs: c["now_ms"].i64) == .drop("budget"))
        #expect(spent.rids.count == before)                // a dropped refusal records nothing
    }
}
