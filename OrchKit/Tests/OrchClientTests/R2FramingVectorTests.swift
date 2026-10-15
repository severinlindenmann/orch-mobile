import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol
import OrchTestVectors
@testable import OrchClient

/// The R2 framing vectors of orch-core (`r2_framing.json`, 40 cases, vendored unmodified; see PROVENANCE.md): every case's request
/// opens under the vector's key and carries the meta the vector names, every response chunk passes the phone's own section 8.8 checks,
/// and the assembled answer is exactly the vector's (Result or refusal, with the closed per-code field sets) in the vector's retry class.
struct R2Vectors {
    let root: JSONValue
    init() { root = try! StrictJSON.parse(Vectors.r2Framing, maxBytes: .max, maxDepth: 64) }

    var workspace: ID16 { ID16(hex: root.object!["workspace_id"]!.string!)! }
    var wsk: SigningPublicKey { try! SigningPublicKey(x963: B64U.decode(root.object!["wsk_pub"]!.string!)!) }
    var wk: [UInt32: SymmetricKey] {
        Dictionary(uniqueKeysWithValues: root.object!["wk"]!.object!.map { (UInt32($0.key)!, SymmetricKey(data: Hex.decode($0.value.string!)!)) })
    }
    var cases: [[String: JSONValue]] { root.object!["cases"]!.array!.map { $0.object! } }
    var tables: [String: JSONValue] { root.object!["tables"]!.object! }
    var constants: [String: JSONValue] { root.object!["constants"]!.object! }
}

private func hexData(_ v: JSONValue?) -> Data { Hex.decode(v!.string!)! }

/// A chunk of a vector answer checked as the phone checks it, in the vector's order.
private func phoneChunks(_ c: [String: JSONValue], _ v: R2Vectors) throws -> [R2.Chunk] {
    let request = try Bridge.Parts(envelope: hexData(c["request"]))
    let device = ID16(hex: c["device"]!.string!)!
    let now = c["now_ms"]!.int!
    var table: [ID16: Bridge.PendingRequest] = [:]
    var out: [R2.Chunk] = []
    for hex in c["response"]!.array! {
        let env = hexData(hex)
        let h = try Bridge.Parts(envelope: env).header
        if table[request.header.rid] == nil { table[request.header.rid] = Bridge.PendingRequest(next: 0, stream: false, epoch: h.epoch) }
        let ctx = Bridge.DeviceContext(workspace: v.workspace, device: device, wsk: v.wsk, wk: v.wk)
        let pos = Bridge.MailboxPosition(id: h.rid, index: h.seq, last: h.flagSet.contains(.last), stream: h.flagSet.contains(.stream))
        let (outcome, next) = Bridge.checkResponse(env, context: ctx, pending: table, mailbox: pos, nowMs: now)
        table = next
        guard case .accept(let a) = outcome else { Issue.record("dropped \(c["name"]!.string!): \(outcome)"); throw ViewError.malformed }
        out.append(R2.Chunk(meta: a.meta, data: a.data, last: a.last, refusal: a.refusal))
    }
    return out
}

@Suite struct R2FramingVectorTests {
    let v = R2Vectors()

    @Test func inventory() {
        #expect(v.cases.count == 40)
        let names = v.cases.map { $0["name"]!.string! }
        #expect(Set(names).count == 40)
    }

    @Test func constantsAndTablesMatch() {
        let k = v.constants
        #expect(k["max_answer"]?.int == Int64(R2.maxAnswer))
        #expect(k["chunk_room"]?.int == Int64(R2.chunkRoom))
        #expect(k["relay_device_response_bytes"]?.int == Int64(R2.relayDeviceResponseBytes))
        #expect(k["fresh_past_ms"]?.int == R2.freshPastMs)
        #expect(k["fresh_future_ms"]?.int == R2.freshFutureMs)
        #expect(k["pending_no_record_ms"]?.int == R2.pendingNoRecordMs)
        #expect(k["window_ms"]?.int == Bridge.windowMs)
        let t = v.tables
        #expect(Set(t["meta_keys"]!.array!.map { $0.string! }) == R2.metaKeys)
        #expect(Set(t["auth"]!.array!.map { $0.string! }) == R2.columnRAuth)
        let ops = t["ops"]!.object!
        #expect(Set(ops.keys) == Set(R2.ops.keys))
        for (name, row) in ops {
            let spec = R2.ops[name]!, o = row.object!
            #expect(o["backend"]?.string == spec.backend)
            #expect(o["kind"]?.string == spec.kind.rawValue)
            #expect(o["scope"]?.string == spec.scope)
            #expect(o["event"]?.string == spec.event)
        }
    }

    @Test func refusalFieldSetsMatch() throws {
        let fields = v.tables["refusal_fields"]!.object!
        let proto = fields["proto"]!.object!
        #expect(Set(proto.keys) == Set(v.tables["proto_codes"]!.array!.map { $0.string! }))
        // each proto code parses with exactly its field and refuses an extra one
        let sample: [String: JSONValue] = ["high": 3, "host_ms": 5, "epoch": 2, "status": "unknown"]
        for (code, f) in proto {
            var m: [String: JSONValue] = ["refusal": .string(code)]
            for name in f.array!.map({ $0.string! }) { m[name] = sample[name]! }
            #expect(HostRefusal(meta: .object(m))?.code == code)
            var extra = m; extra["retryable"] = false
            #expect(HostRefusal(meta: .object(extra)) == nil)
            for name in f.array!.map({ $0.string! }) { var missing = m; missing[name] = nil; #expect(HostRefusal(meta: .object(missing)) == nil) }
        }
        let host = fields["host"]!.object!
        // the reader reasons are the vector's, exactly
        let reasons = host["reason"]!.object!
        for (code, list) in reasons { #expect(Set(list.array!.map { $0.string! }) == HostRefusal.readerReasons[code]) }
        #expect(Set(reasons.keys) == Set(HostRefusal.readerReasons.keys))
        #expect(host["always"]!.array!.map { $0.string! } == ["retryable"])
        #expect(host["next_key"]!.array!.map { $0.string! } == ["ticket.key_not_next"])
    }

    @Test func retryTableMatchesPhoneRetry() {
        let table = v.tables["retry"]!.object!
        let none = PhoneRefusalContext(eventID: "", hostNowMs: 0)
        let context = v.tables["retry_context"]!.object!
        for (code, cls) in table {
            let want: PhoneRetryClass = switch cls.string! {
            case "A": .a
            case "B": .b
            case "C-auto": .cAuto
            case "C-review": .cReview
            default: .d
            }
            if context[code] != nil { continue }
            #expect(PhoneRetryTable.classify(code, none) == want, "\(code)")
        }
        // the generated table IS the data: every code of `tables.retry` (but the two contextual ones) lands in exactly its class's set,
        // and the sets hold nothing else but the documented overlay
        let sets: [(String, Set<String>)] = [("A", PhoneRetryTable.classA), ("B", PhoneRetryTable.classB), ("C-auto", PhoneRetryTable.classCAuto),
                                              ("C-review", PhoneRetryTable.classCReview), ("D", PhoneRetryTable.classD)]
        var fromData: [String: Set<String>] = [:]
        for (code, cls) in table where context[code] == nil { fromData[cls.string!, default: []].insert(code) }
        for (name, set) in sets {
            #expect(set.subtracting(PhoneRetryTableGenerated.overlay) == fromData[name, default: []], "class \(name)")
        }
        #expect(Set(context.keys) == PhoneRetryTableGenerated.contextual)
        #expect(PhoneRetryTableGenerated.overlay == ["no_answer", "silence", "already_done.unknown", "outcome.pending"])
        // orch-52: a bare `timeout` is not in the data (D); `relay.timeout` is (A)
        #expect(table["timeout"] == nil && table["relay.timeout"]?.string == "A")
        #expect(PhoneRetryTable.classify("timeout", none) == .d)
        #expect(PhoneRetryTable.classify("relay.timeout", none) == .a)
        #expect(PhoneRetryTable.classify("internal", PhoneRefusalContext(eventID: "", hostNowMs: 0, admitted: true)) == .b)
        #expect(PhoneRetryTable.classify("internal", none) == .d)
        #expect(PhoneRetryTable.classify("no.such_code", none) == .d)
    }

    @Test func requestsOpenAndCarryTheVectorsMeta() throws {
        for c in v.cases {
            let name = c["name"]!.string!
            let parts = try Bridge.Parts(envelope: hexData(c["request"]))
            let h = parts.header
            guard let wk = v.wk[h.epoch], let key = Bridge.channelKey(header: h, wk: wk) else { Issue.record("no key \(name)"); continue }
            let plain = try Bridge.openBody(parts, channelKey: key)
            let (meta, data) = try Bridge.unframe(plain)
            #expect(data.isEmpty, "\(name)")
            if let expected = c["request_meta"], !expected.isNull { #expect(meta == expected, "\(name)") }
        }
    }

    @Test func theBuilderFollowsTheHostsMetaChecks() throws {
        let refused: [String: String] = [
            "forbidden_op_http": "forbidden_scope", "auth_key": "req.invalid", "grant_shaped": "grant.secret_in_args",
            "write_without_idem": "idem.required", "idem_on_a_read": "req.invalid", "malformed_meta": "req.invalid",
        ]
        for c in v.cases {
            let name = c["name"]!.string!
            guard let meta = c["request_meta"], !meta.isNull else { continue }
            if let code = refused[name] {
                do { try R2.checkMeta(meta); Issue.record("\(name) accepted") } catch let e as R2.MetaError { #expect(e.code == code, "\(name)") }
            } else if name != "idem_not_the_event_id" {
                // every other request meta passes the same checks the host runs first, and the builder reproduces it
                let r = try R2.checkMeta(meta)
                #expect(try R2.requestMeta(op: r.op, args: r.args, idem: r.idem, rd: r.rd) == meta, "\(name)")
            }
        }
        // the builder never produces what the host refuses
        #expect(throws: R2.MetaError.forbiddenScope) { try R2.requestMeta(op: "http") }
        #expect(throws: R2.MetaError.reqInvalid) { try R2.requestMeta(op: "whoami", idem: "01M3250V00KN566QSESSTZJD3R") }
        #expect(throws: R2.MetaError.idemRequired) { try R2.requestMeta(op: "answer", args: ["log": "x", "events": []]) }
        #expect(throws: R2.MetaError.idemInvalid) { try R2.requestMeta(op: "answer", idem: "not-a-ulid") }
        #expect(throws: R2.MetaError.reqInvalid) { try R2.requestMeta(op: "whoami", rd: "sha256:xyz") }
        #expect(throws: R2.MetaError.grantSecretInArgs) {
            try R2.requestMeta(op: "ticket.get", args: ["ref": "gr_00000000000000000000000000.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"])
        }
        #expect(try R2.requestMeta(op: "needs") == ["op": "needs", "args": [:]])
    }

    @Test func answersParseAsTheVectorsSay() throws {
        for c in v.cases {
            let name = c["name"]!.string!
            let expected = c["answer"]!.array!
            let chunks = try phoneChunks(c, v)
            #expect(chunks.count == expected.count, "\(name)")
            for (got, want) in zip(chunks, expected) {
                let w = want.object!
                #expect(got.meta == w["meta"], "\(name)")
                #expect(got.data == hexData(w["data"]), "\(name)")
                let flags = w["flags"]!.int!
                #expect(got.last == (flags & 1 != 0) && got.refusal == (flags & 4 != 0), "\(name)")
            }
            if chunks.isEmpty { continue }
            let answer: R2.Answer
            do { answer = try R2.assemble(chunks) } catch { Issue.record("assemble \(name): \(chunks.map(\.meta))"); continue }
            let cls = c["retry_class"]
            switch answer {
            case .result(let r):
                #expect(cls == nil || cls!.isNull, "\(name)")
                #expect(r.exit == 0 && r.data.object != nil, "\(name)")
            case .refusal(let r):
                let want: PhoneRetryClass = switch cls?.string {
                case "A": .a
                case "B": .b
                case "C-auto": .cAuto
                case "C-review": .cReview
                default: .d
                }
                // `outcome.unknown_idem` after its bound is C-review once a log read shows the event absent (the sheet says C-review
                // outright; #74's rule, kept, asks for that read first: B until then)
                let ctx = PhoneRefusalContext(eventID: "01M323W73ZAEQEG3D94X5HK2GM", hostNowMs: 1_790_000_000_000, logShowsEventAbsent: true)
                #expect(R2.retryClass(of: r, context: ctx) == want, "\(name) \(r.code)")
                #expect(cls?.string != nil, "\(name)")
            }
        }
    }

    @Test func successAnswersAreTheResultEnvelope() throws {
        let byName = Dictionary(uniqueKeysWithValues: v.cases.map { ($0["name"]!.string!, $0) })
        let whoami = try R2.assemble(try phoneChunks(byName["read_whoami"]!, v))
        guard case .result(let r) = whoami else { Issue.record("not a result"); return }
        #expect(r.duplicate == false && r.seq == 0 && r.cursor == 0 && r.head == nil && r.key == nil && r.hints.isEmpty && r.lines.isEmpty)
        #expect(r.data.object?["op"] == "whoami")
        // a chunked answer: meta {"status":"ok"} then {}, LAST on the final chunk, 300 000 bytes of text across them
        let chunked = try phoneChunks(byName["chunked_answer"]!, v)
        #expect(chunked.count == 2 && R2.isOKMeta(chunked[0].meta) && chunked[1].meta == [:] && !chunked[0].last && chunked[1].last)
        guard case .result(let big) = try R2.assemble(chunked) else { Issue.record("not a result"); return }
        #expect(big.data.object?["text"]?.string?.utf8.count == 300_000)
        // the success meta is exactly {"status":"ok"}: nothing else, never a v0 `{status, headers}`
        #expect(!R2.isOKMeta(["status": "ok", "headers": [:]]) && !R2.isOKMeta(["status": 200]) && !R2.isOKMeta([:]))
        #expect(throws: ViewError.self) { _ = try R2.assemble([R2.Chunk(meta: ["status": "ok"], data: Data("{}".utf8), last: true, refusal: false)]) }
        #expect(throws: ViewError.self) {
            _ = try R2.assemble([R2.Chunk(meta: ["status": "ok"], data: Data(), last: false, refusal: false),
                                 R2.Chunk(meta: ["status": "ok"], data: Data("{\"data\":1,\"exit\":0}".utf8), last: true, refusal: false)])
        }
    }

    @Test func refusalsCarryOnlyTheirFields() throws {
        let byName = Dictionary(uniqueKeysWithValues: v.cases.map { ($0["name"]!.string!, $0) })
        func refusal(_ n: String) throws -> HostRefusal {
            guard case .refusal(let r) = try R2.assemble(try phoneChunks(byName[n]!, v)) else { throw ViewError.malformed }
            return r
        }
        #expect(try refusal("seq_used") == .staleSequence(high: 14))
        #expect(try refusal("stale_timestamp") == .staleTimestamp(hostMs: 1_790_000_000_000))
        #expect(try refusal("stale_epoch") == .staleEpoch(epoch: 2))
        #expect(try refusal("already_done_on_a_read") == .alreadyDone(status: "unknown"))
        #expect(try refusal("not_member") == .notMember)
        #expect(try refusal("ticket_key_not_next") == .host(code: "ticket.key_not_next", retryable: false, seqs: nil, nextKey: "DEMO-42"))
        #expect(try refusal("same_idem_new_rid_while_running") == .host(code: "pending", retryable: true, seqs: nil, nextKey: nil))
        #expect(try refusal("outcome_get_idem_expired") == .host(code: "idem.expired", retryable: true, seqs: nil, nextKey: nil))
        // a host code with another field, a wrong `retryable`, an unknown key or a bad `seqs` is refused
        #expect(HostRefusal(meta: ["refusal": "ticket.exists", "retryable": false, "message": "x"]) == nil)
        #expect(HostRefusal(meta: ["refusal": "ticket.exists", "retryable": true]) == nil)
        #expect(HostRefusal(meta: ["refusal": "ticket.exists"]) == nil)
        #expect(HostRefusal(meta: ["refusal": "ticket.exists", "retryable": false, "next_key": "DEMO-42"]) == nil)
        #expect(HostRefusal(meta: ["refusal": "ticket.key_not_next", "retryable": false, "next_key": "demo"]) == nil)
        #expect(HostRefusal(meta: ["refusal": "validation.event", "retryable": false, "seqs": []]) == nil)
        #expect(HostRefusal(meta: ["refusal": "validation.event", "retryable": false, "seqs": [0]]) == nil)
        #expect(HostRefusal(meta: ["refusal": "validation.event", "retryable": false, "seqs": [7, 8]]) == .host(code: "validation.event", retryable: false, seqs: [7, 8], nextKey: nil))
        #expect(HostRefusal(meta: ["refusal": "Bad Code", "retryable": false]) == nil)
        // `internal` depends on a context the answer does not carry: either value is a valid answer
        #expect(HostRefusal(meta: ["refusal": "internal", "retryable": true]) != nil)
        #expect(HostRefusal(meta: ["refusal": "internal", "retryable": false]) != nil)
    }

    @Test func aReadRefusedAlreadyDoneIsReissuedNotReconciled() throws {
        let byName = Dictionary(uniqueKeysWithValues: v.cases.map { ($0["name"]!.string!, $0) })
        guard case .refusal(let r) = try R2.assemble(try phoneChunks(byName["already_done_on_a_read"]!, v)) else { Issue.record("not a refusal"); return }
        #expect(R2.retryClass(of: r) == .b)
        #expect(byName["already_done_on_a_read"]!["retry_class"] == "B")
    }

    @Test func readerRefusalShapesOfH12d3() {
        func m(_ code: String, _ extra: [String: JSONValue]) -> JSONValue {
            var o: [String: JSONValue] = ["refusal": .string(code), "retryable": false]
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }
        for reason in ["no_declaration", "declaration_unknown"] {
            #expect(HostRefusal(meta: m("sign.convenience_readers", ["reason": .string(reason)])) == .reader(code: "sign.convenience_readers", reason: reason, required: nil, declared: nil))
        }
        #expect(HostRefusal(meta: m("sign.convenience_readers", ["reason": "reader_too_old", "required": 1, "declared": 0]))
            == .reader(code: "sign.convenience_readers", reason: "reader_too_old", required: 1, declared: 0))
        #expect(HostRefusal(meta: m("reader.decl_invalid", ["reason": "kat_mismatch"])) == .reader(code: "reader.decl_invalid", reason: "kat_mismatch", required: nil, declared: nil))
        // closed: another reason, a missing or extra level field, a retryable refusal, an unknown key
        #expect(HostRefusal(meta: m("sign.convenience_readers", ["reason": "because"])) == nil)
        #expect(HostRefusal(meta: m("sign.convenience_readers", ["reason": "reader_too_old"])) == nil)
        #expect(HostRefusal(meta: m("sign.convenience_readers", ["reason": "no_declaration", "required": 1, "declared": 0])) == nil)
        #expect(HostRefusal(meta: m("reader.decl_invalid", ["reason": "no_declaration"])) == nil)
        #expect(HostRefusal(meta: m("reader.decl_invalid", ["reason": "shape", "message": "x"])) == nil)
        #expect(HostRefusal(meta: ["refusal": "reader.decl_invalid", "retryable": true, "reason": "shape"]) == nil)
        // every shape is class D: never sent again as if nothing happened
        #expect(R2.retryClass(of: .reader(code: "sign.convenience_readers", reason: "declaration_unknown", required: nil, declared: nil)) == .d)
        // the wire spelling round-trips
        let r = HostRefusal.reader(code: "sign.convenience_readers", reason: "reader_too_old", required: 1, declared: 0)
        #expect(HostRefusal(meta: r.meta) == r)
    }
}
