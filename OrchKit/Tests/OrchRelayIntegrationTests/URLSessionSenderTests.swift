import Foundation
import Testing
@testable import OrchClient

/// The real sender against loopback stub servers (always run, no relay needed).
@Suite(.serialized) struct URLSessionSenderTests {
    func get(_ target: String, headers: [String: String] = [:], method: String = "GET", body: Data = Data()) throws -> WireRequest {
        try WireRequest(method: method, target: target, headers: headers, body: body, clientAddress: "127.0.0.1")
    }

    @Test func productionInitAcceptsOnlyHTTPSOrigins() throws {
        _ = try URLSessionRequestSender(origin: "https://relay.example.org")
        for o in ["http://127.0.0.1:8101", "http://localhost:8101", "http://relay.example.org", "https://relay.example.org/", "ftp://a", ""] {
            #expect(throws: RealmViolation.self) { _ = try URLSessionRequestSender(origin: o) }
        }
        #expect(throws: RealmViolation.invalidOrigin) { _ = try RealmContext.live(origin: "http://127.0.0.1:8101") }
        #expect(throws: RealmViolation.invalidOrigin) { _ = try RealmContext.liveLoopbackForTesting(origin: "http://localhost:8101") }
        #expect(throws: RealmViolation.invalidOrigin) { _ = try RealmContext.liveLoopbackForTesting(origin: "http://127.0.0.1") }
        #expect(throws: RealmViolation.invalidOrigin) { _ = try RealmContext.liveLoopbackForTesting(origin: "https://127.0.0.1:1") }
        #expect(throws: RealmViolation.self) { _ = try URLSessionRequestSender(loopbackOrigin: "http://relay.example.org:80") }
        let ctx = try RealmContext.liveLoopbackForTesting(origin: "http://[::1]:8101")
        #expect(ctx.realm == .live)
    }

    @Test func targetsThatCouldChangeTheHostAreRefusedBeforeIO() async throws {
        let s = try StubServer(); defer { s.stop() }
        let sender = try URLSessionRequestSender(loopbackOrigin: s.origin)
        for t in ["//evil.example/x", "http://evil.example/x", "x", "/a b", "/a#f", "/a\\b", ""] {
            await #expect(throws: TransportError.invalidArgument) { _ = try await sender.send(self.get(t)) }
        }
        #expect(s.requests.isEmpty)
    }

    @Test func aRedirectIsRefusedAndNeverFollowed() async throws {
        let other = try StubServer(); defer { other.stop() }
        let s = try StubServer(); defer { s.stop() }
        let to = other.origin + "/landing"
        s.handle { _ in .raw(StubServer.http(302, headers: ["Location": to], body: "")) }
        let sender = try URLSessionRequestSender(loopbackOrigin: s.origin)
        for status in [301, 302, 303, 307, 308] {
            s.handle { _ in .raw(StubServer.http(status, headers: ["Location": to], body: "")) }
            let r = try await sender.send(get("/v2/x", method: "POST", body: Data("{}".utf8)))
            #expect(r.status == status)
            #expect(r.header("location") == to)
        }
        let g = try await sender.send(get("/v2/y"))
        #expect(g.status == 308)
        #expect(other.requests.isEmpty)
        // the reply is never mistaken for a relay refusal or data
        #expect(HostAPI.failure(of: g) == .badReply)
    }

    @Test func aBodyOverTheCapIsCutOffWhileReading() async throws {
        let s = try StubServer(); defer { s.stop() }
        let sender = try URLSessionRequestSender(loopbackOrigin: s.origin, maxResponseBytes: 4096)
        // a declared length over the cap
        s.handle { _ in .raw(StubServer.http(200, body: String(repeating: "x", count: 5000))) }
        await #expect(throws: TransportError.responseTooLarge) { _ = try await sender.send(self.get("/declared")) }
        // chunked with no length that never ends
        s.handle { _ in .endless(chunk: 1000) }
        await #expect(throws: TransportError.responseTooLarge) { _ = try await sender.send(self.get("/endless")) }
        // exactly at the cap passes
        s.handle { _ in .raw(StubServer.http(200, body: String(repeating: "x", count: 4096))) }
        let ok = try await sender.send(get("/exact"))
        #expect(ok.body.count == 4096)
        // the default cap is 4 MiB
        let d = try URLSessionRequestSender(loopbackOrigin: s.origin)
        #expect(d.maxResponseBytes == 4 << 20)
        s.handle { _ in .endless(chunk: 200_000) }
        await #expect(throws: TransportError.responseTooLarge) { _ = try await d.send(self.get("/endless-default")) }
    }

    @Test func connectionLossAndTimeoutsAreDisconnected() async throws {
        let s = try StubServer(); defer { s.stop() }
        let sender = try URLSessionRequestSender(loopbackOrigin: s.origin, requestTimeout: 0.5, resourceTimeout: 2)
        s.handle { _ in .truncated(Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabc".utf8)) }
        await #expect(throws: TransportError.disconnected) { _ = try await sender.send(self.get("/cut")) }
        s.handle { _ in .hang }
        await #expect(throws: TransportError.disconnected) { _ = try await sender.send(self.get("/hang")) }
        let port = s.port
        s.stop()
        let dead = try URLSessionRequestSender(loopbackOrigin: "http://127.0.0.1:\(port)", requestTimeout: 1, resourceTimeout: 2)
        await #expect(throws: TransportError.disconnected) { _ = try await dead.send(self.get("/x")) }
    }

    @Test func cancellationStopsAHungRequest() async throws {
        let s = try StubServer(); defer { s.stop() }
        s.handle { _ in .hang }
        let sender = try URLSessionRequestSender(loopbackOrigin: s.origin)
        let t = Task { try await sender.send(self.get("/hang")) }
        try await Task.sleep(for: .milliseconds(200))
        t.cancel()
        await #expect(throws: CancellationError.self) { _ = try await t.value }
    }

    @Test func sendsOnlyTheHeadersTheRequestCarriesAndKeepsNoCookies() async throws {
        let s = try StubServer(); defer { s.stop() }
        s.handle { _ in .raw(StubServer.http(200, headers: ["Set-Cookie": "a=b", "Content-Type": "application/json"], body: "{}")) }
        let sender = try URLSessionRequestSender(loopbackOrigin: s.origin)
        _ = try await sender.send(get("/first"))
        let r = try await sender.send(get("/second?after=3&wait=25", headers: ["authorization": "Bearer abc", "content-type": "application/json"],
                                          method: "POST", body: Data("{}".utf8)))
        #expect(r.status == 200)
        let seen = s.requests.last!
        #expect(seen.method == "POST" && seen.target == "/second?after=3&wait=25")
        #expect(seen.headers["authorization"] == "Bearer abc")
        #expect(seen.headers["cookie"] == nil)
        #expect(seen.headers["if-none-match"] == nil && seen.headers["referer"] == nil && seen.headers["origin"] == nil)
    }
}
