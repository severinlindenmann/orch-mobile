import Foundation
import Testing
import OrchClient
import OrchProtocol
import OrchTestVectors
@testable import OrchFakeHost

/// The FakeRelay's cert queue (P3-D11) against the shared vectors' `p3` cases with op `request` (admission) and `queue`
/// (challenge, rejection, certificate completion): same result, same post-state, byte for byte.
@Suite struct CertQueueVectorTests {
    static let p3: [JSONValue] = {
        let root = try? StrictJSON.parse(Vectors.data, maxBytes: .max)
        return root?.object?["suites"]?.object?["2"]?.object?["p3"]?.object?["cases"]?.array ?? []
    }()

    static func record(_ v: JSONValue) throws -> CertQueue.Record {
        let o = try #require(v.object), req = try #require(o["request"]), ro = try #require(req.object?["o"]?.object)
        func id(_ k: String) throws -> ID16 { try #require(ro[k]?.string.flatMap(ID16.init(hex:))) }
        func opt(_ k: String) -> JSONValue? { o[k].flatMap { $0.isNull ? nil : $0 } }
        return CertQueue.Record(request: req, requestID: try id("request_id"), workspace: try id("workspace_id"), person: try id("person_id"),
                                primary: try id("primary_device_id"), expiresMs: try #require(ro["expires_ms"]?.int),
                                state: try #require(o["state"]?.string.flatMap(CertQueue.State.init(rawValue:))),
                                challenge: opt("challenge"), cert: opt("cert"), rejection: opt("rejection"))
    }

    static func key(_ v: JSONValue?) throws -> SigningPublicKey { try SigningPublicKey(x963: try #require(v?.string.flatMap { Hex.decode($0) })) }

    static func result(_ o: CertQueue.Outcome) -> JSONValue {
        switch o {
        case .ok(let s): return .object(["ok": .string(s)])
        case .refuse(let c): return .object(["refuse": .string(c.rawValue)])
        }
    }

    @Test func requestAdmission() throws {
        let cases = Self.p3.filter { $0.object?["op"]?.string == "request" }
        #expect(cases.count == 13)
        for c in cases {
            let name = c.object?["name"]?.string ?? "?", a = try #require(c.object?["args"])
            var records: [ID16: CertQueue.Record] = [:]
            for (_, v) in c.object?["state"]?.object ?? [:] { let r = try Self.record(v); records[r.requestID] = r }
            let primary = try #require(a.object?["primary"]?.string.flatMap(ID16.init(hex:)))
            let out = CertQueue.admit(try #require(a.object?["signed"]), wsk: try Self.key(a.object?["wsk_pub"]),
                                      workspace: try #require(a.object?["ws"]?.string.flatMap(ID16.init(hex:))),
                                      owner: try #require(a.object?["owner"]?.string.flatMap(ID16.init(hex:))),
                                      isAddressee: { $0 == primary }, records: &records, nowMs: try #require(a.object?["now_ms"]?.int))
            let expect = try #require(c.object?["expect"]?.object)
            #expect(Self.result(out) == expect["result"], "\(name): \(out)")
            var want: [ID16: CertQueue.Record] = [:]
            for (_, v) in expect["state"]?.object ?? [:] { let r = try Self.record(v); want[r.requestID] = r }
            #expect(records == want, "\(name) post-state")
        }
    }

    @Test func queueTransitions() throws {
        let cases = Self.p3.filter { $0.object?["op"]?.string == "queue" }
        #expect(cases.count == 27)
        var seen: [String: Int] = [:]
        for c in cases {
            let name = c.object?["name"]?.string ?? "?", a = try #require(c.object?["args"]?.object)
            var r = try Self.record(try #require(c.object?["state"]))
            let signed = try #require(a["signed"]), pk = try Self.key(a["pk_pub"]), now = try #require(a["now_ms"]?.int)
            let action = a["action"]?.string ?? ""
            let out: CertQueue.Outcome
            switch action {
            case "challenge": out = CertQueue.challenge(&r, signed: signed, pk: pk, nowMs: now)
            case "rejection": out = CertQueue.reject(&r, signed: signed, pk: pk, nowMs: now)
            case "certificate": out = CertQueue.certificate(&r, signed: signed, pk: pk, nowMs: now)
            default: Issue.record("\(name): unknown action \(action)"); continue
            }
            seen[action, default: 0] += 1
            let expect = try #require(c.object?["expect"]?.object)
            #expect(Self.result(out) == expect["result"], "\(name): \(out)")
            #expect(r == (try Self.record(try #require(expect["state"]))), "\(name) post-state")
        }
        #expect(seen == ["challenge": 11, "rejection": 8, "certificate": 8], "\(seen)")
    }
}
