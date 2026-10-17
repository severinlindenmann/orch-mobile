import Foundation
import Testing
import OrchProtocol
@testable import OrchClient

/// Counts what reaches the wire and answers 200 `{"host_api":0}`.
final class RecordingSender: RequestSender, InProcessDemoSender, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [WireRequest] = []
    private var current: String
    init(origin: String = "https://relay.example.org") { current = origin }
    /// Settable so a test can make the sender drift to another origin after the transport was built.
    var origin: String { get { lock.withLock { current } } set { lock.withLock { current = newValue } } }
    var requests: [WireRequest] { lock.withLock { seen } }
    func send(_ request: WireRequest) async throws -> WireReply {
        lock.withLock { seen.append(request) }
        return try WireReply(status: 200, headers: [:], body: HostAPI.json())
    }
}

func demoContext() -> RealmContext { RealmContext.demo(DemoCapability(id: ID16.random())) }

func routed(_ ctx: RealmContext? = nil, sender: RecordingSender? = nil) throws -> (RoutedRelayTransport<RecordingSender>, RecordingSender) {
    let c = try ctx ?? RealmContext.live(origin: "https://relay.example.org")
    let sender = sender ?? RecordingSender(origin: c.origin)
    return (try RoutedRelayTransport(context: c, origin: c.origin, sender: sender, clientAddress: "198.51.100.1"), sender)
}

let session = RelaySession(token: "tok123")
let ws = ID16(hex: "00112233445566778899aabbccddeeff")!
let rid = ID16(hex: "ffeeddccbbaa99887766554433221100")!

@Suite struct WireTests {
    @Test func testHeaderNamesCaseInsensitive() throws {
        let r = try WireReply(status: 200, headers: ["Content-Type": "application/json", "RETRY-after": " 5 "])
        #expect(r.header("content-type") == "application/json")
        #expect(r.header("CONTENT-TYPE") == "application/json")
        #expect(r.header("Retry-After") == "5")
        #expect(r.headers.keys.allSatisfy { $0 == $0.lowercased() })
        // Two spellings of one name with the same value are one header; with different values they conflict.
        let same = try WireReply(status: 200, headerFields: [(name: "X-A", value: "1"), (name: "x-a", value: "1")])
        #expect(same.headers == ["x-a": "1"])
        #expect(throws: WireError.conflictingHeader("x-a")) {
            try WireReply(status: 200, headerFields: [(name: "X-A", value: "1"), (name: "x-a", value: "2")])
        }
        #expect(throws: WireError.conflictingHeader("content-length")) {
            try WireReply(status: 200, headers: ["Content-Length": "1", "content-length": "2"])
        }
        #expect(throws: WireError.self) { try WireReply(status: 200, headers: ["bad name": "1"]) }
        #expect(throws: WireError.self) { try WireReply(status: 200, headers: ["x": "a\r\nInjected: 1"]) }
        #expect(throws: WireError.self) { try WireReply(status: 200, headers: ["": "1"]) }
        // The same normalization applies to requests.
        let q = try WireRequest(method: "GET", target: "/x", headers: ["Authorization": "Bearer t"], clientAddress: "a")
        #expect(q.header("AUTHORIZATION") == "Bearer t")
        #expect(throws: WireError.self) {
            try WireRequest(method: "GET", target: "/x", headers: ["Authorization": "a", "authorization": "b"], clientAddress: "a")
        }
    }

    @Test func testZeroGrantEpochRejected() async throws {
        let (t, s) = try routed()
        await #expect(throws: TransportError.invalidEpoch) { try await t.grants(workspaceID: ws, epoch: 0, session: session) }
        await #expect(throws: TransportError.invalidEpoch) { try await t.cardKey(workspaceID: ws, cardSequence: 0, session: session) }
        #expect(s.requests.isEmpty)                                  // refused before any I/O
        _ = try await t.grants(workspaceID: ws, epoch: 1, session: session)
        _ = try await t.grants(workspaceID: ws, epoch: nil, session: session)
        _ = try await t.grants(workspaceID: ws, epoch: UInt32.max, session: session)
        #expect(s.requests.map(\.target) == [
            "/v2/workspaces/\(ws.hex)/grants?epoch=1",
            "/v2/workspaces/\(ws.hex)/grants",
            "/v2/workspaces/\(ws.hex)/grants?epoch=4294967295"])
    }

    @Test func testPollCursorUInt64() async throws {
        let (t, s) = try routed()
        let route = BridgeRoute(workspaceID: ws, requestID: rid)
        for cursor: UInt64? in [nil, 0, 1, UInt64(UInt32.max), UInt64(UInt32.max) + 1, (1 << 53) - 1, UInt64.max] {
            _ = try await t.bridgePoll(route: route, after: cursor, session: session)
        }
        let base = "/v2/workspaces/\(ws.hex)/bridge/\(rid.hex)"
        #expect(s.requests.map(\.target) == [base, base + "?after=0", base + "?after=1", base + "?after=4294967295",
                                             base + "?after=4294967296", base + "?after=9007199254740991",
                                             base + "?after=18446744073709551615"])
        let pr = PairRoute(workspaceID: ws, offerID: rid, requestID: rid)
        _ = try await t.pairingPoll(route: pr, after: UInt64.max)
        #expect(s.requests.last!.target.hasSuffix("?after=18446744073709551615"))
        // The decimal spelling is strict both ways.
        #expect(HostAPI.parseDecimal("18446744073709551615") == UInt64.max)
        for bad in ["18446744073709551616", "01", "-1", "+1", "", "1.0", "0x10", " 1", "1 ", "123456789012345678901"] {
            #expect(HostAPI.parseDecimal(bad) == nil, "\(bad)")
        }
        #expect(HostAPI.parseDecimal("0") == 0)
    }

    @Test func noAdapterVersionOnTheRelayWire() async throws {
        // No request announces an adapter version: no `Orch-Host-API` header, no `host_api` body field (protocol-v2 section 19).
        let (t, s) = try routed()
        _ = try await t.challenge()
        _ = try await t.card(workspaceID: ws, session: session)
        _ = try await t.dropPut(objectID: rid, ifMatch: 0, body: Data(), session: session)
        #expect(s.requests.allSatisfy { $0.header("Orch-Host-API") == nil })
        #expect(s.requests[0].body == (try canonicalJSON([:])))
        #expect(s.requests[0].target == "/v2/session/challenge")
        // Replies: strict section 2.3 JSON with the exact field set, nothing else.
        for body in [#"{"host_api":0,"chunks":[]}"#, #"{}"#, #"{"chunks":[],"extra":1}"#, #"{"chunks":0.0}"#, #"[]"#, "x"] {
            #expect(throws: ClientError.badReply, "\(body)") { try HostAPI.chunks(Data(body.utf8)) }
        }
        #expect(try HostAPI.chunks(Data(#"{"chunks":[]}"#.utf8)).isEmpty)
        // A refusal is `{"error": code}` plus its documented fields only: an adapter field is not trusted.
        let m = try WireReply(status: 400, body: Data(#"{"error":"malformed"}"#.utf8))
        #expect(HostAPI.failure(of: m) == .relay(RelayRefusal(status: 400, code: .malformed)))
        for bad in [#"{"host_api":0,"error":"malformed"}"#, #"{"error":"malformed","extra":1}"#, #"{"error":"unsupported_host_api"}"#, #"{"error":1}"#, "{}"] {
            #expect(HostAPI.failure(of: try WireReply(status: 400, body: Data(bad.utf8))) == .badReply, "\(bad)")
        }
        let nonJSON = try WireReply(status: 502, body: Data("<html>bad gateway</html>".utf8))
        #expect(HostAPI.failure(of: nonJSON) == .badReply)
        #expect(HostAPI.failure(of: try WireReply(status: 429, headers: ["Retry-After": "5"],
                                                  body: Data(#"{"error":"rate_limited"}"#.utf8))) == .relay(RelayRefusal(status: 429, code: .rateLimited, retryAfter: 5)))
    }

    @Test func relayRefusalsAndHostRefusalsAreDifferentTypes() {
        // A relay `revoked` is unsigned and only ever triggers a record fetch; it must not be expressible as a host refusal.
        let relay: ClientError = .relay(RelayRefusal(status: 403, code: .revoked))
        let host: ClientError = .host(.revoked)
        #expect(relay != host)
        for code in RelayRefusal.Code.allCases {
            let allowed = RelayRefusal.statuses(of: code)
            #expect(!allowed.isEmpty)
            for st in allowed {
                // section 14 fields: required for these codes, absent for every other
                var extra = ""
                var want = RelayRefusal(status: st, code: code)
                switch code {
                case .staleEpoch: extra = #","epoch":3"#; want = RelayRefusal(status: st, code: code, epoch: 3)
                case .versionConflict: extra = #","current":4"#; want = RelayRefusal(status: st, code: code, current: 4)
                case .staleTimestamp: extra = #","server_ms":5"#; want = RelayRefusal(status: st, code: code, serverMs: 5)
                case .alreadyClaimed: extra = #","claimed_by":null"#
                default: break
                }
                let r = try! WireReply(status: st, body: Data("{\"error\":\"\(code.rawValue)\"\(extra)}".utf8))
                #expect(HostAPI.failure(of: r) == .relay(want), "\(code) at \(st)")
                if !extra.isEmpty {
                    // missing or mistyped documented fields are not a refusal
                    let bare = try! WireReply(status: st, body: Data("{\"error\":\"\(code.rawValue)\"}".utf8))
                    #expect(HostAPI.failure(of: bare) == .badReply, "\(code) without its fields")
                }
            }
            // The same code under any other status is not a section 14 refusal.
            for other in [200, 400, 401, 403, 404, 409, 410, 413, 428, 429, 500, 502, 503] where !allowed.contains(other) {
                let w = try! WireReply(status: other, body: Data("{\"error\":\"\(code.rawValue)\"}".utf8))
                #expect(HostAPI.failure(of: w) == .badReply, "\(code) at \(other)")
            }
        }
    }

    @Test func section19RefusalCodesAndStatusPairs() throws {
        func f(_ status: Int, _ code: String, retry: String? = nil) throws -> ClientError {
            HostAPI.failure(of: try WireReply(status: status, headers: retry.map { ["Retry-After": $0] } ?? [:],
                                              body: HostAPI.json(["error": .string(code)])))
        }
        let pairs: [(Int, String)] = [(401, "unauthenticated"), (404, "not_found"), (413, "too_large"), (400, "too_large"), (503, "overloaded"),
                                      (429, "quota_exceeded"), (409, "account_exists"), (409, "fenced"), (409, "grant_conflict"), (409, "wrap_conflict"),
                                      (409, "chunk_conflict"), (409, "retry_exhausted"), (409, "holder_conflict"), (410, "expired"), (401, "expired")]
        for (st, code) in pairs {
            guard case .relay(let r) = try f(st, code) else { Issue.record("\(st) \(code)"); continue }
            #expect(r.status == st && r.code.rawValue == code)
        }
        // Family mismatches and the retired adapter codes are bad replies.
        #expect(try f(403, "unauthenticated") == .badReply)
        #expect(try f(500, "not_found") == .badReply)
        #expect(try f(200, "rate_limited") == .badReply)
        #expect(try f(400, "unsupported_host_api") == .badReply)
        #expect(try f(501, "not_implemented") == .badReply)
        // Retry-After is carried by 429 and 503 only.
        #expect(try f(503, "overloaded", retry: "7") == .relay(RelayRefusal(status: 503, code: .overloaded, retryAfter: 7)))
        #expect(try f(409, "fenced", retry: "7") == .relay(RelayRefusal(status: 409, code: .fenced)))
        // stale_epoch: `epoch` is the only extra field and must be a protocol epoch.
        for bad in [#"{"error":"stale_epoch","epoch":0}"#, #"{"error":"version_conflict","current":-1}"#, #"{"error":"version_conflict","current":"1"}"#,
                    #"{"error":"already_claimed","claimed_by":"xyz"}"#, #"{"error":"already_claimed"}"#] {
            #expect(HostAPI.failure(of: try WireReply(status: 409, body: Data(bad.utf8))) == .badReply, "\(bad)")
        }
        #expect(HostAPI.failure(of: try WireReply(status: 401, body: Data(#"{"error":"stale_timestamp","server_ms":-1}"#.utf8))) == .badReply)
        let claimed = try WireReply(status: 409, body: Data(#"{"error":"already_claimed","claimed_by":"00000000000000000000000000000001"}"#.utf8))
        #expect(HostAPI.failure(of: claimed) == .relay(RelayRefusal(status: 409, code: .alreadyClaimed, claimedBy: ID16(hex: "00000000000000000000000000000001"))))
    }

    @Test func retryAfterIsAStrictDecimalClampedToOneThroughAnHour() throws {
        func retry(_ h: String?) throws -> ClientError {
            HostAPI.failure(of: try WireReply(status: 429, headers: h.map { ["Retry-After": $0] } ?? [:], body: HostAPI.json(["error": .string("rate_limited")])))
        }
        #expect(try retry("5") == .relay(RelayRefusal(status: 429, code: .rateLimited, retryAfter: 5)))
        #expect(try retry("1") == .relay(RelayRefusal(status: 429, code: .rateLimited, retryAfter: 1)))
        #expect(try retry("3600") == .relay(RelayRefusal(status: 429, code: .rateLimited, retryAfter: 3600)))
        #expect(try retry("0") == .relay(RelayRefusal(status: 429, code: .rateLimited, retryAfter: 1)))
        #expect(try retry("3601") == .relay(RelayRefusal(status: 429, code: .rateLimited, retryAfter: 3600)))
        #expect(try retry("18446744073709551615") == .relay(RelayRefusal(status: 429, code: .rateLimited, retryAfter: 3600)))
        // Not delta-seconds: no hint at all, never a negative, signed, fractional, padded, hex or date value.
        for bad in ["-99999999", "+5", "5.0", "05", "0x10", "1e3", "5 6", "99999999999999999999999", "Wed, 21 Oct 2026 07:28:00 GMT", ""] {
            #expect(try retry(bad) == .relay(RelayRefusal(status: 429, code: .rateLimited, retryAfter: nil)), "\(bad)")
        }
        #expect(try retry(nil) == .relay(RelayRefusal(status: 429, code: .rateLimited, retryAfter: nil)))
    }

    @Test func theBearerNeverAppearsInTextualRenderings() {
        let s = RelaySession(token: "SECRET-BEARER")
        let o = RelayClient.Opened(session: s, expiresMs: 5)
        var dumped = ""
        dump(s, to: &dumped); dump(o, to: &dumped)
        let texts = ["\(s)", String(describing: s), String(reflecting: s), "\(o)", String(describing: o), String(reflecting: o), dumped,
                     "\(Mirror(reflecting: s).children.count)", "\(Mirror(reflecting: o).children)",
                     "\((try? WireRequest(method: "GET", target: "/x", headers: ["authorization": "Bearer SECRET-BEARER"], clientAddress: "a")) as Any)"]
        for t in texts { #expect(!t.contains("SECRET-BEARER"), "\(t)") }
        #expect(s.token == "SECRET-BEARER" && o.session == s)
    }

    @Test func theSenderOriginIsAdmittedOnEverySend() async throws {
        let (t, sender) = try routed()
        _ = try await t.challenge()
        sender.origin = "https://elsewhere.example.org"          // a sender that drifts (a redirect, a swapped host) is not sent through
        await #expect(throws: TransportError.realm(.externalOrigin)) { _ = try await t.challenge() }
        sender.origin = DemoRelay.origin
        await #expect(throws: TransportError.realm(.crossRealmOrigin)) { _ = try await t.challenge() }
        #expect(sender.requests.count == 1)
        // A sender on another origin than the one admitted cannot even be paired with the transport.
        let live = try RealmContext.live(origin: "https://relay.example.org")
        #expect(throws: TransportError.realm(.externalOrigin)) {
            try RoutedRelayTransport(context: live, origin: live.origin, sender: RecordingSender(origin: "https://other.example.org"), clientAddress: "a")
        }
    }

    @Test func aDemoContextBuiltFromAnInvalidatedGenerationNeverSends() async throws {
        let cap = DemoCapability(id: ID16.random())
        let (t, sender) = try routed(RealmContext.demo(cap))
        _ = try await t.challenge()
        cap.generation.invalidate()
        await #expect(throws: TransportError.realm(.staleGeneration)) { _ = try await t.challenge() }
        await #expect(throws: TransportError.realm(.staleGeneration)) { _ = try await t.revocation(deviceID: rid) }
        #expect(sender.requests.count == 1)
    }

    @Test func requestsCarryBearerAndRefuseUnsafeTokens() async throws {
        let (t, s) = try routed()
        _ = try await t.memberList(workspaceID: ws, session: session)
        #expect(s.requests[0].header("authorization") == "Bearer tok123")
        for bad in ["", "a b", "a\r\nX: 1", "tök", String(repeating: "a", count: 600)] {
            await #expect(throws: TransportError.invalidArgument) { try await t.card(workspaceID: ws, session: RelaySession(token: bad)) }
        }
        #expect(s.requests.count == 1)
    }

    @Test func routesMatchHostAPI() async throws {
        let (t, s) = try routed()
        let R = "/v2"
        _ = try await t.challenge(); _ = try await t.login(Data())
        _ = try await t.pairingPost(Data([1]), route: PairRoute(workspaceID: ws, offerID: rid, requestID: ws))
        _ = try await t.bridgePost(Data([1]), route: BridgeRoute(workspaceID: ws, requestID: rid), session: session)
        _ = try await t.cardKey(workspaceID: ws, cardSequence: 7, session: session)
        _ = try await t.registerPush(Data(), session: session); _ = try await t.unregisterPush(Data(), session: session)
        _ = try await t.revocation(deviceID: rid)
        _ = try await t.dropList(Data(), session: session)
        _ = try await t.dropGet(objectID: rid, version: 3, part: .wraps, session: session)
        #expect(s.requests.map { "\($0.method) \($0.target)" } == [
            "POST \(R)/session/challenge", "POST \(R)/session/login",
            "POST \(R)/workspaces/\(ws.hex)/pair/\(rid.hex)/\(ws.hex)",
            "POST \(R)/workspaces/\(ws.hex)/bridge/\(rid.hex)",
            "GET \(R)/workspaces/\(ws.hex)/card-key?card_seq=7",
            "POST \(R)/push/register", "POST \(R)/push/unregister",
            "GET \(R)/devices/\(rid.hex)/revocation",
            "POST \(R)/drop/list", "GET \(R)/drop/\(rid.hex)/versions/3/wraps"])
        // Pairing needs no bearer; every Drop route, the PUT included, sits under /v2.
        #expect(s.requests[2].header("authorization") == nil)
        _ = try await t.dropPut(objectID: rid, ifMatch: 2, body: Data(), session: session)
        #expect(s.requests.last!.method == "PUT" && s.requests.last!.target == "\(R)/drop/\(rid.hex)/versions" && s.requests.last!.header("if-match") == "2")
    }
}
