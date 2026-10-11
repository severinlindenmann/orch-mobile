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
// host_cases: 47 in the file. 25 are epoch >= 1 requests (testBridgeHostCases); the other 22 (names starting "pair") are epoch-0
// pairing cases (section 8.3, K_pair, offers, cert_pending), run by testPairHostCases in PairingVectorTests. The names are
// listed here so that none can be silently skipped.

let pairingCaseNames = [
    "pair_first_time", "pair_resend_then_other_key", "pair_unknown_offer_dropped", "pair_sealed_under_another_secret_dropped",
    "pair_expired_offer", "pair_device_id_not_of_key", "pair_signed_by_another_key", "pair_stale_timestamp",
    "pair_with_a_label_full_of_controls", "pair_with_existing_cert", "pair_with_another_persons_cert", "pair_with_a_cert_for_another_key",
    "pair_with_a_revoked_cert", "pair_meta_with_extra_field", "pair_other_op_at_epoch_0", "pair_status_pending", "pair_status_cert_pending",
    "pair_status_cert_pending_with_the_primarys_challenge", "pair_status_cert_pending_expired", "pair_status_approved",
    "pair_status_rejected", "pair_status_without_pairing",
]

func bridgeVectors() -> J { J(try! StrictJSON.parse(OrchTestVectors.Vectors.data, maxBytes: .max, maxDepth: 64))["suites"]["2"]["bridge"] }

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
    if let wsk = st["wsk_pub"].string { core.wskPub = try! SigningPublicKey(x963: B64U.decode(wsk)!) }
    if let owner = st["owner_pk_pub"].string { core.ownerPK = try! SigningPublicKey(x963: B64U.decode(owner)!) }
    for (k, v) in st["offers"].v.object ?? [:] {
        let o = v.object!
        core.offers[ID16(hex: k)!] = HostOffer(secret: Hex.decode(o["secret"]!.string!)!, expiresMs: o["expires_ms"]!.int!, sasNonce: B64U.decode(o["sas_nonce"]!.string!)!,
                                               used: o["used"]!.bool!, unverified: (o["unverified"]?.array ?? []).map { $0.int! })
    }
    for (k, v) in st["pending_pairs"].v.object ?? [:] {
        let o = v.object!
        let cert: JSONValue? = o["cert"].flatMap { $0.isNull ? nil : $0 }
        var p = HostPendingPair(offer: ID16(hex: o["offer_id"]!.string!)!, dkSig: try! SigningPublicKey(x963: B64U.decode(o["dk_sig_pub"]!.string!)!),
                                dkKx: try! AgreementPublicKey(x963: B64U.decode(o["dk_kx_pub"]!.string!)!), label: o["label"]!.string!,
                                sasNonce: B64U.decode(o["sas_nonce"]!.string!)!, cert: cert, certState: o["cert_state"]!.string!, state: o["state"]!.string!)
        p.certPendingSince = o["cert_pending_since"]?.int
        p.primaryLabel = o["primary_label"]?.string
        p.challenge = o["challenge"].flatMap { $0.isNull ? nil : $0 }
        p.scopes = o["scopes"]?.array?.compactMap(\.string)
        core.pendingPairs[ID16(hex: k)!] = p
    }
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

    /// Resulting state of EVERY host case and chain step (host_cases carry no state_after, so these are derived from the
    /// section 8.6 order): the sequence window per device ("high/bitmap" in binary), the rid records and what each holds
    /// (`run` = accepted and not yet completed), the stream table and the refusal-budget log.
    struct S: Equatable {
        let seq: [String], rids: Int, outcomes: [String], streams: Int, unverified: Int
    }

    static let expectedState: [String: S] = [
        "full_request_accepted#0": S(seq: ["7/1"], rids: 1, outcomes: ["run"], streams: 0, unverified: 0),
        "replayed_request#0": S(seq: ["7/1"], rids: 1, outcomes: ["run"], streams: 0, unverified: 0),
        "replayed_request#1": S(seq: ["7/1"], rids: 1, outcomes: ["run"], streams: 0, unverified: 0),
        "previous_epoch_refused_stale_epoch#0": S(seq: ["3/1"], rids: 1, outcomes: ["stale_epoch"], streams: 0, unverified: 0),
        "stale_epoch_consumes_its_seq_then_a_new_request_runs#0": S(seq: ["3/1"], rids: 1, outcomes: ["stale_epoch"], streams: 0, unverified: 0),
        "stale_epoch_consumes_its_seq_then_a_new_request_runs#1": S(seq: ["3/1"], rids: 2, outcomes: ["stale_epoch", "stale_sequence"], streams: 0, unverified: 0),
        "stale_epoch_consumes_its_seq_then_a_new_request_runs#2": S(seq: ["4/11"], rids: 3, outcomes: ["run", "stale_epoch", "stale_sequence"], streams: 0, unverified: 0),
        "future_epoch_dropped#0": S(seq: [], rids: 0, outcomes: [], streams: 0, unverified: 0),
        "epoch_whose_key_the_host_deleted_dropped#0": S(seq: [], rids: 0, outcomes: [], streams: 0, unverified: 0),
        "sealed_under_another_epochs_key_dropped#0": S(seq: [], rids: 0, outcomes: [], streams: 0, unverified: 0),
        "removed_device_not_member#0": S(seq: [], rids: 0, outcomes: [], streams: 0, unverified: 1),
        "revoked_device#0": S(seq: [], rids: 0, outcomes: [], streams: 0, unverified: 1),
        "signed_by_another_members_key#0": S(seq: [], rids: 0, outcomes: [], streams: 0, unverified: 1),
        "other_suite_dropped#0": S(seq: [], rids: 0, outcomes: [], streams: 0, unverified: 0),
        "old_magic_v1_dropped#0": S(seq: [], rids: 0, outcomes: [], streams: 0, unverified: 0),
        "version_1_dropped#0": S(seq: [], rids: 0, outcomes: [], streams: 0, unverified: 0),
        "other_workspace_dropped#0": S(seq: [], rids: 0, outcomes: [], streams: 0, unverified: 0),
        "mailbox_id_differs_from_rid#0": S(seq: [], rids: 0, outcomes: [], streams: 0, unverified: 0),
        "old_timestamp#0": S(seq: ["4/1"], rids: 1, outcomes: ["stale_timestamp"], streams: 0, unverified: 0),
        "timestamp_at_window_edge#0": S(seq: ["4/1"], rids: 1, outcomes: ["run"], streams: 0, unverified: 0),
        "sequence_zero#0": S(seq: ["0/0"], rids: 1, outcomes: ["stale_sequence"], streams: 0, unverified: 0),
        "repeated_sequence#0": S(seq: ["5/1"], rids: 1, outcomes: ["run"], streams: 0, unverified: 0),
        "repeated_sequence#1": S(seq: ["5/1"], rids: 2, outcomes: ["run", "stale_sequence"], streams: 0, unverified: 0),
        "meta_with_a_duplicate_key#0": S(seq: [], rids: 1, outcomes: ["malformed"], streams: 0, unverified: 0),
        "meta_with_a_float#0": S(seq: [], rids: 1, outcomes: ["malformed"], streams: 0, unverified: 0),
        "meta_without_op#0": S(seq: [], rids: 1, outcomes: ["malformed"], streams: 0, unverified: 0),
        "stream_of_another_device#0": S(seq: ["5/1"], rids: 1, outcomes: ["forbidden_scope"], streams: 1, unverified: 0),
        "refusal_budget_spent_drops_unverified#0": S(seq: [], rids: 0, outcomes: [], streams: 0, unverified: 10),
        "quota_busy#0": S(seq: [], rids: 2, outcomes: ["busy", "run"], streams: 0, unverified: 0),
    ]

    @Test func testResultingStateOfEveryHostCase() throws {
        var seen = Set<String>()
        for c in bridgeVectors()["host_cases"].items where !c["name"].str.hasPrefix("pair") {
            var core = hostCore(from: c["state"])
            let steps = c["steps"].items.isEmpty ? [c] : c["steps"].items
            for (n, s) in steps.enumerated() {
                _ = core.check(s["envelope"].hexData, mailbox: s["mailbox_id"].string.flatMap { ID16(hex: $0) }, nowMs: s["now_ms"].i64)
                let name = "\(c["name"].str)#\(n)"
                let outcomes = core.rids.values.map { r -> String in
                    switch r.outcome { case nil: "run"; case .refusal(let x)?: x.code; case .stored?: "stored"; case .bodyNotStored?: "body_not_stored" }
                }.sorted()
                let got = S(seq: core.seq.values.map { "\($0.high)/\(String($0.bitmap, radix: 2))" }.sorted(), rids: core.rids.count, outcomes: outcomes,
                            streams: core.streams.count, unverified: core.unverified.count)
                #expect(got == Self.expectedState[name], "\(name): \(got)")
                seen.insert(name)
            }
        }
        #expect(seen == Set(Self.expectedState.keys))      // every case and step has an expectation, and none is stale
    }
}
