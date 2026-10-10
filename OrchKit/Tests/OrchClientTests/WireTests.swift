import Foundation
import Testing
import OrchProtocol
@testable import OrchClient

/// Counts what reaches the wire and answers 200 `{"host_api":0}`.
final class RecordingSender: RequestSender, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [WireRequest] = []
    var requests: [WireRequest] { lock.withLock { seen } }
    func send(_ request: WireRequest) async throws -> WireReply {
        lock.withLock { seen.append(request) }
        return try WireReply(status: 200, headers: [:], body: HostAPI.json())
    }
}

func demoContext() -> RealmContext { RealmContext.demo(DemoCapability(id: ID16.random())) }

func routed(_ ctx: RealmContext? = nil, sender: RecordingSender = RecordingSender()) throws -> (RoutedRelayTransport<RecordingSender>, RecordingSender) {
    let c = try ctx ?? RealmContext.live(origin: "https://relay.example.org")
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
            "/mobile/host-api/0/workspaces/\(ws.hex)/grants?epoch=1",
            "/mobile/host-api/0/workspaces/\(ws.hex)/grants",
            "/mobile/host-api/0/workspaces/\(ws.hex)/grants?epoch=4294967295"])
    }

    @Test func testPollCursorUInt64() async throws {
        let (t, s) = try routed()
        let route = BridgeRoute(workspaceID: ws, requestID: rid)
        for cursor: UInt64? in [nil, 0, 1, UInt64(UInt32.max), UInt64(UInt32.max) + 1, (1 << 53) - 1, UInt64.max] {
            _ = try await t.bridgePoll(route: route, after: cursor, session: session)
        }
        let base = "/mobile/host-api/0/workspaces/\(ws.hex)/bridge/\(rid.hex)"
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

    @Test func testAdapterVersionRejected() async throws {
        // Every request announces version 0.
        let (t, s) = try routed()
        _ = try await t.challenge()
        _ = try await t.card(workspaceID: ws, session: session)
        _ = try await t.dropPut(objectID: rid, ifMatch: 0, body: Data(), session: session)
        #expect(s.requests.allSatisfy { $0.header("Orch-Host-API") == "0" })
        #expect(s.requests[0].body == (try canonicalJSON(["host_api": 0])))
        // Replies: any other version (or none) is refused; no negotiation, no fallback.
        for body in [#"{"host_api":1,"chunks":[]}"#, #"{"chunks":[]}"#, #"{"host_api":"0","chunks":[]}"#, #"{"host_api":0.0,"chunks":[]}"#] {
            #expect(throws: AdapterError.self) { try HostAPI.chunks(Data(body.utf8)) }
        }
        #expect(throws: AdapterError.unsupportedHostAPI) { try HostAPI.chunks(Data(#"{"host_api":1,"chunks":[]}"#.utf8)) }
        #expect(try HostAPI.chunks(Data(#"{"host_api":0,"chunks":[]}"#.utf8)).isEmpty)
        // Unknown extra fields in a v0 reply are refused.
        #expect(throws: AdapterError.badReply) { try HostAPI.chunks(Data(#"{"host_api":0,"chunks":[],"extra":1}"#.utf8)) }
        // HTTP 400 unsupported_host_api is an adapter error, not a protocol refusal.
        let r = try WireReply(status: 400, body: Data(#"{"host_api":0,"error":"unsupported_host_api"}"#.utf8))
        #expect(HostAPI.failure(of: r) == .adapter(.unsupportedHostAPI))
        // A section 14 refusal never carries host_api, and a body that claims both is not trusted as a refusal.
        let m = try WireReply(status: 400, body: Data(#"{"error":"malformed"}"#.utf8))
        #expect(HostAPI.failure(of: m) == .relay(RelayRefusal(status: 400, code: .malformed)))
        let bad = try WireReply(status: 400, body: Data(#"{"host_api":0,"error":"malformed"}"#.utf8))
        #expect(HostAPI.failure(of: bad) == .adapter(.badReply))
        let nonJSON = try WireReply(status: 502, body: Data("<html>bad gateway</html>".utf8))
        #expect(HostAPI.failure(of: nonJSON) == .adapter(.badReply))
        #expect(HostAPI.failure(of: try WireReply(status: 429, headers: ["Retry-After": "5"],
                                                  body: Data(#"{"host_api":0,"error":"rate_limited"}"#.utf8))) == .adapter(.rateLimited(retryAfter: 5)))
    }

    @Test func relayRefusalsAndHostRefusalsAreDifferentTypes() {
        // A relay `revoked` is unsigned and only ever triggers a record fetch; it must not be expressible as a host refusal.
        let relay: ClientError = .relay(RelayRefusal(status: 403, code: .revoked))
        let host: ClientError = .host(.revoked)
        #expect(relay != host)
        for code in RelayRefusal.Code.allCases {
            let r = try! WireReply(status: 409, body: Data("{\"error\":\"\(code.rawValue)\"}".utf8))
            #expect(HostAPI.failure(of: r) == .relay(RelayRefusal(status: 409, code: code)))
        }
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
        let R = "/mobile/host-api/0"
        _ = try await t.challenge(); _ = try await t.login(Data())
        _ = try await t.pairingPost(Data([1]), route: PairRoute(workspaceID: ws, offerID: rid, requestID: ws))
        _ = try await t.bridgePost(Data([1]), route: BridgeRoute(workspaceID: ws, requestID: rid), session: session)
        _ = try await t.cardKey(workspaceID: ws, cardSequence: 7, session: session)
        _ = try await t.registerPush(Data(), session: session); _ = try await t.unregisterPush(Data(), session: session)
        _ = try await t.revocation(deviceID: rid, session: session)
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
        // Pairing needs no bearer; the PUT route is protocol section 10.6 unchanged.
        #expect(s.requests[2].header("authorization") == nil)
        _ = try await t.dropPut(objectID: rid, ifMatch: 2, body: Data(), session: session)
        #expect(s.requests.last!.method == "PUT" && s.requests.last!.target == "/drop/\(rid.hex)/versions" && s.requests.last!.header("if-match") == "2")
    }
}
