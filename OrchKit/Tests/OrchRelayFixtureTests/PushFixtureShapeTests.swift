import Foundation
import Testing
@testable import OrchClient
import OrchProtocol
import OrchTestVectors

/// The push registration fixtures of the relay (protocol-v2 section 19.10, `push_register.json`, `push_unregister.json`) against what the phone
/// sends and accepts (copies in `push_fixtures/`). The relay's own tests replay these files against its implementation; here the phone side of the same bytes is pinned.
@Suite struct PushFixtureShapeTests {
    private func file(_ name: String) throws -> Fixtures.File { try Fixtures.loadPush(name) }
    private func note(_ s: String) -> Comment { Comment(rawValue: s) }
    private func isBool(_ j: Fixtures.JSON?, _ v: Bool) -> Bool { if case .bool(let b)? = j { return b == v }; return false }
    private func isHex16(_ j: Fixtures.JSON?) -> Bool { j?.string.flatMap { Hex.decode($0, length: 16) } != nil }

    @Test func registerRequestsCarryExactlyTheFieldsTheClientSends() throws {
        let f = try file("push_register.json")
        let expected: Set<String> = ["workspace_id", "registration_id", "env", "topic", "token"]
        var checked = 0
        for c in f.cases {
            guard let o = c.request["json"]?.object else { continue }
            let id = caseID(f, c)
            // cases about a malformed body may drop or change a field; every other body is the client's exact shape
            if c.name.hasPrefix("refusal_400") || c.name.hasSuffix("_malformed") { continue }
            #expect(Set(o.keys) == expected, note("\(id) fields"))
            #expect(o["topic"]?.string == PushService.topic, note("\(id) topic"))
            #expect(["sandbox", "production"].contains(o["env"]?.string ?? ""), note("\(id) env"))
            #expect(isHex16(o["registration_id"]) && isHex16(o["workspace_id"]), note("\(id) ids are 32 hex"))
            let raw = o["token"]?.string.flatMap { B64U.decode($0) }
            #expect(raw.map { (32...100).contains($0.count) } == true, note("\(id) token 32..100 bytes"))
            checked += 1
        }
        #expect(checked >= 10)
    }

    @Test func unregisterRequestsCarryAnIdOrNullAndNothingElse() throws {
        let f = try file("push_unregister.json")
        var sawNull = false
        for c in f.cases {
            guard let o = c.request["json"]?.object, !c.name.hasSuffix("_malformed"), !c.name.hasPrefix("refusal_400") else { continue }
            #expect(Set(o.keys) == ["workspace_id", "registration_id"], note(caseID(f, c)))
            if case .null? = o["registration_id"] { sawNull = true }
        }
        #expect(sawNull, "the all-registrations form (registration_id null) is in the fixtures")
    }

    @Test func successAnswersAreTheShapesTheClientAccepts() throws {
        let reg = try file("push_register.json"), unreg = try file("push_unregister.json")
        for c in reg.cases where c.response["status"]?.int == 200 {
            let o = try #require(c.response["json"]?.object)
            #expect(Set(o.keys) == ["registration_id", "registered"] && isBool(o["registered"], true) && isHex16(o["registration_id"]), note(caseID(reg, c)))
        }
        for c in unreg.cases where c.response["status"]?.int == 200 {
            let o = try #require(c.response["json"]?.object)
            #expect(Set(o.keys) == ["registration_id", "registered"] && isBool(o["registered"], false), note(caseID(unreg, c)))
        }
    }

    @Test func everyRefusalCodeIsKnownAndMapsToTheDocumentedOutcome() throws {
        for name in ["push_register.json", "push_unregister.json"] {
            let f = try file(name)
            for c in f.cases where (c.response["status"]?.int ?? 200) >= 400 {
                let code = try #require(c.response["json"]?.object?["error"]?.string)
                let known = try #require(RelayRefusal.Code(rawValue: code), note("\(caseID(f, c)): unknown code \(code)"))
                let refusal = RelayRefusal(status: Int(c.response["status"]?.int ?? 0), code: known)
                let outcome: PushRegistrationOutcome = PushService.outcome(of: ClientError.relay(refusal))
                let id = note(caseID(f, c))
                switch code {
                case "not_found": #expect(outcome == .pushOff, id)   // how a relay without push answers
                case "rate_limited", "quota_exceeded": #expect(outcome == PushRegistrationOutcome.rateLimited(retryAfter: nil), id)
                case "not_eligible", "revoked", "not_for_this_device", "malformed", "too_large": #expect(outcome == .refused(code), id)
                default: #expect(outcome == .failed(code), id)   // unauthenticated, cert_expired, registration_conflict: retried, or reminted by the service
                }
            }
        }
    }
}
