import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchFakeHost
import OrchProtocol
import OrchTestVectors
@testable import OrchClient
@testable import OrchFakeHost
@testable import OrchProtocol

// G3b (orch-relay 04da0e7, P3-D28) vector gates through the phone's own answer check (PairingWire.check) and the fakes:
// bridge.pair_answers, cert_binding.challenges, rejected_forms.answers and approved_anchor.answers share one runner (multi-step,
// restart, the accepted challenge's request id and the join floor carried as the coordinator carries them); approved_anchor.join
// through JoinAnchor; cert_binding.host through FakeHost's epoch-0 pipeline.

func vectorSuite2() -> J { J(try! StrictJSON.parse(OrchTestVectors.Vectors.data, maxBytes: .max, maxDepth: 64))["suites"]["2"] }

/// Runs one answer case: `ctx` plus either one envelope (`envelope`, `expect`, `now_ms`) or `steps`. Returns (accepted, dropped, alarms).
struct AnswerRunner {
    static func context(_ x: J) -> PairingWire.Context {
        let earlier = x["earlier_attempts"].items.map { PairingAttemptContext.EarlierAttempt(deviceID: $0["device_id"].id, dkHash: B64U.decode($0["dk_hash"].str)!) }
        return PairingWire.Context(workspace: x["workspace"].id, device: x["device"].id, offer: x["offer"].id, secret: SymmetricKey(data: x["secret"].hexData),
                                   wskPin: x["wsk_pin"].hexData, pkPin: x["pk_pin"].hexData,
                                   dkSig: try! SigningPublicKey(x963: B64U.decode(x["dk_sig_pub"].str)!),
                                   dkKx: try! AgreementPublicKey(x963: B64U.decode(x["dk_kx_pub"].str)!),
                                   offsetMs: x["offset_ms"].i64, attempt: x["attempt"].str, earlierAttempts: earlier,
                                   acceptedRequestID: x["challenge_request_id"].string.flatMap { ID16(hex: $0) })
    }

    static func pendingTable(_ x: J) -> [ID16: Bridge.PendingRequest] {
        var t: [ID16: Bridge.PendingRequest] = [:]
        for (k, v) in x["pending"].v.object ?? [:] { t[ID16(hex: k)!] = Bridge.PendingRequest(next: UInt64(v.object!["next"]!.int!), epoch: 0) }
        return t
    }

    static func anchorJSON(_ a: JoinAnchor) -> JSONValue {
        ["epoch": .int(Int64(a.epoch)), "list_seq": .int(a.listSeq), "card_seq": .int(a.cardSeq), "scopes": .array(a.scopes.map { .string($0) }),
         "baseline": a.baseline.map { ["n": .int($0.n), "hash": .string($0.hash)] } ?? .null]
    }

    var accepted = 0, dropped = 0, alarms = 0

    mutating func run(_ c: J) {
        let name = c["name"].str
        var ctx = Self.context(c["ctx"])
        var pending = Self.pendingTable(c["ctx"])
        var anchor: JoinAnchor?
        let steps = c["steps"].items.isEmpty ? [c] : c["steps"].items
        for (n, s) in steps.enumerated() {
            let id = "\(name)#\(n)", e = s["expect"], env = s["envelope"].hexData
            let h = try! Bridge.Parts(envelope: env).header
            if let add = s["add_pending"].string { pending[ID16(hex: add)!] = Bridge.PendingRequest(next: 0, epoch: 0) }
            let mailbox = Bridge.MailboxPosition(id: h.rid, index: h.seq, last: h.flagSet.contains(.last), stream: false)
            let (outcome, table) = PairingWire.check(env, context: ctx, pending: pending, mailbox: mailbox, nowMs: s["now_ms"].i64)
            switch outcome {
            case .accept(let a):
                accepted += 1
                #expect(e["result"].str == "accept", "\(id)")
                #expect(B64U.encode(a.wskPub.x963) == e["wsk_pub"].str, "\(id)")
                switch a.body {
                case .pending(_, let sas): #expect(e["state"].str == "pending" && sas == e["sas"].str, "\(id)")
                case .certPending(let label, _, let ch):
                    #expect(e["state"].str == "cert_pending" && label == e["primary_label"].str, "\(id)")
                    #expect(ch?.certCode == e["cert_code"].string, "\(id)")
                    if let ch, ctx.acceptedRequestID == nil { ctx.acceptedRequestID = ch.requestID }
                case .approved(let scopes, _, let cert, _, _, let next):
                    anchor = anchor.map { $0.raised(by: next) } ?? next
                    #expect(e["state"].str == "approved", "\(id)")
                    _ = scopes
                    #expect(anchor!.scopes == e["scopes"].items.map(\.str), "\(id) scopes: the floor's are shown")
                    #expect(cert.deviceID.hex == e["device_id"].str, "\(id)")
                    if e["anchor"].v.object != nil { #expect(Self.anchorJSON(anchor!) == e["anchor"].v, "\(id) anchor") }
                case .rejected(let why, let alarm):
                    #expect(e["state"].str == "rejected" && e["attributed"].v.bool != true, "\(id)")
                    #expect(why == e["why"].string, "\(id): \(String(describing: why))")
                    #expect(alarm == (e["alarm"].v.bool ?? false), "\(id) alarm")
                    if alarm { alarms += 1 }
                case .denied: #expect(e["state"].str == "rejected" && e["attributed"].v.bool == true, "\(id)")
                case .expired: #expect(e["state"].str == "expired", "\(id)")
                case .refusal(let code, _):
                    #expect(code == e["refusal"].str, "\(id)")
                    if let off = e["offset_ms"].int { #expect(a.offsetMs == off && !a.clockWrong, "\(id)") }
                }
                pending = table
            case .drop(let why, let alarm, _):
                dropped += 1
                #expect(e["result"].str == "drop" && e["why"].str == why, "\(id): \(why)")
                #expect((alarm != nil) == (e["alarm"].v.bool ?? false), "\(id)")
                if alarm != nil { alarms += 1 }
                #expect(table == pending, "\(id): a dropped answer changes nothing")
            }
            // the context after the step (pending table, the accepted challenge's request id), as the coordinator persists it
            let after = s["ctx_after"]
            if after.v.object != nil {
                #expect(Self.pendingTable(after) == pending, "\(id) pending after")
                #expect(ctx.acceptedRequestID?.hex == after["challenge_request_id"].string, "\(id) request id after")
            }
        }
    }
}

@Suite struct PairingBindingVectorTests {
    var s2: J { vectorSuite2() }

    @Test func pairAnswers() {
        let cases = s2["bridge"]["pair_answers"].items
        #expect(cases.count == 20)
        var r = AnswerRunner()
        for c in cases { r.run(c) }
        #expect(r.accepted == 7 && r.dropped == 13 && r.alarms == 2, "\(r.accepted) \(r.dropped) \(r.alarms)")
    }

    @Test func challengesBoundToTheAttempt() {
        let cases = s2["cert_binding"]["challenges"].items
        #expect(cases.count == 14)
        var r = AnswerRunner()
        for c in cases { r.run(c) }
        #expect(r.accepted == 2 && r.dropped == 13 && r.alarms == 5, "\(r.accepted) \(r.dropped) \(r.alarms)")
    }

    @Test func rejectedForms() {
        let cases = s2["rejected_forms"]["answers"].items
        #expect(cases.count == 23)
        var r = AnswerRunner()
        for c in cases { r.run(c) }
        #expect(r.accepted == 25 && r.dropped == 0 && r.alarms == 4, "\(r.accepted) \(r.dropped) \(r.alarms)")
    }

    @Test func approvedAnchorAnswers() {
        let cases = s2["approved_anchor"]["answers"].items
        #expect(cases.count == 13)
        var r = AnswerRunner()
        for c in cases { r.run(c) }
        #expect(r.accepted == 10 && r.dropped == 7, "\(r.accepted) \(r.dropped)")
    }

    /// The join floor at join (section 8.3): the first list and card against the anchor; the floor is never changed by a refusal.
    @Test func approvedAnchorJoin() throws {
        let cases = s2["approved_anchor"]["join"].items
        #expect(cases.count == 11)
        var ran = 0
        for c in cases {
            let name = c["name"].str
            let anchor = try #require(JoinAnchor.parse(c["state"]["anchor"].v), "\(name)")
            let device = c["state"]["device"].id
            let wsk = try SigningPublicKey(x963: c["wsk_pub"].hexData)
            for (n, s) in c["steps"].items.enumerated() {
                let id = "\(name)#\(n)", e = s["expect"]
                var got: JSONValue
                switch s["op"].str {
                case "list":
                    let list = try MemberList.verify(s["signed"].v, wsk: wsk)
                    do { _ = try anchor.checkList(list, device: device); got = ["ok": "advanced"] }
                    catch let r as JoinAnchor.Refusal { got = ["refuse": .string(r.rawValue)] }
                    if got == ["ok": "advanced"] {
                        let head = s["state"]["head"]
                        #expect(head["list_seq"].int == list.listSeq && head["epoch"].int == Int64(list.epoch), "\(id) head")
                    }
                case "card":
                    let seq = s["card_o"]["card_seq"].i64
                    do { try anchor.checkCard(cardSeq: seq); got = ["ok": .int(seq)] }
                    catch let r as JoinAnchor.Refusal { got = ["refuse": .string(r.rawValue)] }
                default: Issue.record("\(id): op"); continue
                }
                #expect(got == e.v, "\(id): \(got)")
                // the floor is the same after the step (a refusal leaves it for the retry)
                #expect(JoinAnchor.parse(s["state"]["anchor"].v) == anchor, "\(id) floor")
                ran += 1
            }
        }
        #expect(ran == 12)
    }

    /// cert_binding.host: the pair request carries the attempt (32 lower hex), a resend keeps it, a new attempt is closed; the two
    /// rejected forms the host answers.
    @Test func hostCases() {
        let cases = s2["cert_binding"]["host"].items
        #expect(cases.count == 5)
        var ran = 0
        for c in cases {
            var core = hostCore(from: c["state"])
            for (n, s) in c["steps"].items.enumerated() {
                let name = "\(c["name"].str)#\(n)", e = s["expect"]
                let result = core.check(s["envelope"].hexData, mailbox: s["mailbox_id"].string.flatMap { ID16(hex: $0) }, nowMs: s["now_ms"].i64)
                switch e["result"].str {
                case "pair_pending":
                    guard case .pair(.pending(_, _, _, let answer), _) = result else { Issue.record("\(name): \(result)"); continue }
                    #expect(answer == e["answer"].v, "\(name)")
                case "pair_status":
                    guard case .pair(.status(let answer), _) = result else { Issue.record("\(name): \(result)"); continue }
                    #expect(answer == e["answer"].v, "\(name)")
                case "refuse":
                    guard case .pair(.refuse(let code, _), _) = result else { Issue.record("\(name): \(result)"); continue }
                    #expect(code == e["code"].str, "\(name)")
                default: Issue.record("\(name): \(e["result"].str)")
                }
                ran += 1
            }
        }
        #expect(ran == 7)
    }
}
