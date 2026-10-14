import Foundation
import Testing
import OrchClient
import OrchProtocol
@testable import OrchFakeHost
@testable import OrchClient

/// Phone-side wire fixes against the real relay (orch-relay 772d7b0): paginated revocation read, bridge poll throttling and `wait`,
/// the 4 MiB reply cap, FastAPI's 404 body, and the `/v2` Drop PUT.
final class ScriptedSender: RequestSender, @unchecked Sendable {
    let origin = "https://relay.example.org"
    private let lock = NSLock()
    private var seen: [WireRequest] = []
    private let script: @Sendable (WireRequest, Int) -> WireReply
    init(_ script: @escaping @Sendable (WireRequest, Int) -> WireReply) { self.script = script }
    var requests: [WireRequest] { lock.withLock { seen } }
    func send(_ request: WireRequest) async throws -> WireReply {
        let n = lock.withLock { seen.append(request); return seen.count }
        return script(request, n)
    }
}

/// Answers the first `throttled` bridge polls with 429 (Retry-After: 2) and 503, then forwards.
final class ThrottlingPollTransport: RelayTransport, @unchecked Sendable {
    let inner: any RelayTransport
    private let lock = NSLock()
    private var polls = 0
    private var posts = 0
    private let throttled: Int
    init(_ inner: any RelayTransport, throttled: Int) { self.inner = inner; self.throttled = throttled }
    var pollCount: Int { lock.withLock { polls } }
    var postCount: Int { lock.withLock { posts } }
    var context: RealmContext { inner.context }
    func challenge() async throws -> WireReply { try await inner.challenge() }
    func login(_ body: Data) async throws -> WireReply { try await inner.login(body) }
    func pairingPost(_ envelope: Data, route: PairRoute) async throws -> WireReply { try await inner.pairingPost(envelope, route: route) }
    func pairingPoll(route: PairRoute, after: UInt64?, wait: Int?) async throws -> WireReply { try await inner.pairingPoll(route: route, after: after, wait: wait) }
    func bridgePost(_ envelope: Data, route: BridgeRoute, session: RelaySession) async throws -> WireReply {
        lock.withLock { posts += 1 }
        return try await inner.bridgePost(envelope, route: route, session: session)
    }
    func bridgePoll(route: BridgeRoute, after: UInt64?, wait: Int?, session: RelaySession) async throws -> WireReply {
        let n = lock.withLock { polls += 1; return polls }
        if n <= throttled {
            if n % 2 == 1 {
                return try WireReply(status: 429, headers: ["content-type": "application/json", "retry-after": "2"], body: HostAPI.json(["error": "rate_limited"]))
            }
            return try WireReply(status: 503, headers: ["content-type": "application/json", "retry-after": "1"], body: HostAPI.json(["error": "overloaded"]))
        }
        return try await inner.bridgePoll(route: route, after: after, wait: wait, session: session)
    }
    func grants(workspaceID: ID16, epoch: UInt32?, session: RelaySession) async throws -> WireReply { try await inner.grants(workspaceID: workspaceID, epoch: epoch, session: session) }
    func memberList(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try await inner.memberList(workspaceID: workspaceID, session: session) }
    func card(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try await inner.card(workspaceID: workspaceID, session: session) }
    func cardKey(workspaceID: ID16, cardSequence: UInt32, session: RelaySession) async throws -> WireReply { try await inner.cardKey(workspaceID: workspaceID, cardSequence: cardSequence, session: session) }
    func registerPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await inner.registerPush(body, session: session) }
    func unregisterPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await inner.unregisterPush(body, session: session) }
    func revocation(deviceID: ID16, after: String?, limit: Int?) async throws -> WireReply { try await inner.revocation(deviceID: deviceID, after: after, limit: limit) }
    func dropPut(objectID: ID16, ifMatch: UInt32, body: Data, session: RelaySession) async throws -> WireReply { try await inner.dropPut(objectID: objectID, ifMatch: ifMatch, body: body, session: session) }
    func dropList(_ query: Data, session: RelaySession) async throws -> WireReply { try await inner.dropList(query, session: session) }
    func dropGet(objectID: ID16, version: UInt32, part: DropPart, session: RelaySession) async throws -> WireReply { try await inner.dropGet(objectID: objectID, version: version, part: part, session: session) }
}

@Suite struct RelayWireFixesTests {
    func transport(_ sender: ScriptedSender) throws -> RoutedRelayTransport<ScriptedSender> {
        let c = try RealmContext.live(origin: sender.origin)
        return try RoutedRelayTransport(context: c, origin: c.origin, sender: sender, clientAddress: "a")
    }

    func page(_ people: [ID16], next: String?) throws -> WireReply {
        let pairs: [JSONValue] = people.map { p in
            .object(["person_id": .string(p.hex), "reason": "lost", "provenance": "feed",
                     "revocation": .object(["o": .object(["person_id": .string(p.hex)]), "sig": "x"])])
        }
        return try WireReply(status: 200, headers: ["content-type": "application/json"],
                             body: canonicalJSON(.object(["pairs": .array(pairs), "next": next.map { .string($0) } ?? .null])))
    }

    @Test func revocationWalksPagesAndPicksThePinnedPersonsPair() async throws {
        let mine = ID16.random(), other = ID16.random()
        let sender = ScriptedSender { req, n in
            if n == 1 { return (try? self.page([other], next: "cursor1"))! }
            return (try? self.page([other, mine], next: nil))!
        }
        let rec = try await RelayClient(transport: transport(sender)).revocation(device: ID16.random(), person: mine)
        #expect(rec.object?["o"]?.object?["person_id"]?.string == mine.hex)
        #expect(sender.requests.count == 2)
        #expect(sender.requests[0].target.hasSuffix("/revocation") && sender.requests[1].target.hasSuffix("/revocation?after=cursor1"))
    }

    @Test func revocationPageWalkIsBounded() async throws {
        let sender = ScriptedSender { _, n in (try? self.page([ID16.random()], next: "c\(n)"))! }
        await #expect(throws: ClientError.relay(RelayRefusal(status: 404, code: .notFound))) {
            _ = try await RelayClient(transport: self.transport(sender)).revocation(device: ID16.random(), person: ID16.random())
        }
        #expect(sender.requests.count == RelayClient.maxRevocationPages)
        // a relay that repeats its cursor ends the walk at once
        let loop = ScriptedSender { _, _ in (try? self.page([ID16.random()], next: "same"))! }
        await #expect(throws: ClientError.self) { _ = try await RelayClient(transport: self.transport(loop)).revocation(device: ID16.random(), person: ID16.random()) }
        #expect(loop.requests.count == 2)
    }

    @Test func oldRecordShapeIsABadReply() throws {
        let old = try canonicalJSON(.object(["record": .object([:])]))
        #expect(throws: ClientError.badReply) { _ = try HostAPI.revocationPage(old) }
    }

    @Test func revocationAndPollQueriesAreStrict() async throws {
        let sender = ScriptedSender { _, _ in (try? WireReply(status: 200, body: HostAPI.json()))! }
        let t = try transport(sender)
        let d = ID16.random(), ws = ID16.random(), rid = ID16.random()
        _ = try await t.revocation(deviceID: d, after: "ab_-Z9", limit: 32)
        _ = try await t.bridgePoll(route: BridgeRoute(workspaceID: ws, requestID: rid), after: 3, wait: 25, session: RelaySession(token: "t"))
        _ = try await t.bridgePoll(route: BridgeRoute(workspaceID: ws, requestID: rid), after: nil, wait: 0, session: RelaySession(token: "t"))
        _ = try await t.pairingPoll(route: PairRoute(workspaceID: ws, offerID: rid, requestID: rid), after: nil, wait: nil)
        let targets = sender.requests.map(\.target)
        #expect(targets[0].hasSuffix("/revocation?after=ab_-Z9&limit=32"))
        #expect(targets[1].hasSuffix("/bridge/\(rid.hex)?after=3&wait=25"))
        #expect(targets[2].hasSuffix("/bridge/\(rid.hex)?wait=0"))
        #expect(targets[3].hasSuffix("/pair/\(rid.hex)/\(rid.hex)"))
        for bad in ["a&b=1", "a b", "", "a/b", "a=="] {
            await #expect(throws: TransportError.invalidArgument) { _ = try await t.revocation(deviceID: d, after: bad, limit: nil) }
        }
        await #expect(throws: TransportError.invalidArgument) { _ = try await t.revocation(deviceID: d, after: nil, limit: 33) }
        await #expect(throws: TransportError.invalidArgument) { _ = try await t.revocation(deviceID: d, after: nil, limit: 0) }
        await #expect(throws: TransportError.invalidArgument) {
            _ = try await t.bridgePoll(route: BridgeRoute(workspaceID: ws, requestID: rid), after: nil, wait: 26, session: RelaySession(token: "t"))
        }
        #expect(sender.requests.count == 4)
    }

    @Test func fastAPINotFoundIsNotFoundNotBadReply() throws {
        let nf = try WireReply(status: 404, headers: ["content-type": "application/json"], body: Data(#"{"detail":"Not Found"}"#.utf8))
        #expect(HostAPI.failure(of: nf) == .relay(RelayRefusal(status: 404, code: .notFound)))
        for body in [#"{"detail":"Nope"}"#, #"{"detail":"Not Found","x":1}"#, #"{"detail":["Not Found"]}"#, "not json"] {
            #expect(HostAPI.failure(of: try WireReply(status: 404, body: Data(body.utf8))) == .badReply)
        }
        // the same body under another status is not that
        #expect(HostAPI.failure(of: try WireReply(status: 400, body: Data(#"{"detail":"Not Found"}"#.utf8))) == .badReply)
    }

    @Test func replyCapIsFourMiB() throws {
        #expect(HostAPI.maxJSONBytes == 4 << 20)
        let pad = String(repeating: "a", count: 3 << 20)
        let big = Data(#"{"member_list":""#.utf8) + Data(pad.utf8) + Data(#""}"#.utf8)
        _ = try HostAPI.memberList(big)
        let tooBig = Data(#"{"member_list":""#.utf8) + Data(String(repeating: "a", count: 4 << 20).utf8) + Data(#""}"#.utf8)
        #expect(throws: ClientError.badReply) { _ = try HostAPI.memberList(tooBig) }
    }

    @Test func dropPutSitsUnderV2() async throws {
        let sender = ScriptedSender { _, _ in (try? WireReply(status: 200, body: HostAPI.json()))! }
        let oid = ID16.random()
        _ = try await transport(sender).dropPut(objectID: oid, ifMatch: 1, body: Data(), session: RelaySession(token: "t"))
        #expect(sender.requests[0].method == "PUT" && sender.requests[0].target == "/v2/drop/\(oid.hex)/versions")
    }

    @Test func aThrottledBridgePollKeepsPollingTheSameRid() async throws {
        let w = try await World.make()
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .response(status: 200, headers: [:], data: Data()) })
        let throttling = ThrottlingPollTransport(w.transport, throttled: 3)      // 429, 503, 429, then the real relay
        let phone = try await w.makePhone(transport: throttling)
        let s = phone.session
        let response = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        #expect(response.status == 200)
        #expect(throttling.postCount == 1)                    // one request, never re-sent
        #expect(throttling.pollCount >= 4)
        #expect(counter.value == 1)
    }
}
