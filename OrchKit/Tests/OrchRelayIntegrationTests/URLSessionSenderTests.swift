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
        let s = try await StubServer.start(); defer { s.stop() }
        let sender = try URLSessionRequestSender(loopbackOrigin: s.origin)
        for t in ["//evil.example/x", "http://evil.example/x", "x", "/a b", "/a#f", "/a\\b", "", "/a<b", "/a>b", "/a|b", "/a{b}", "/a\"b", "/a^b", "/a`b", "/a[b]", "/a%", "/a%z", "/a%zz", "/a%2", "/a?b=%zz", "/a?b?c", "/a\u{e9}", "/a\nb", "/a\u{0}b"] {
            await #expect(throws: TransportError.invalidArgument) { _ = try await sender.send(self.get(t)) }
        }
        #expect(s.requests.isEmpty)
    }

    @Test func aRedirectIsRefusedAndNeverFollowed() async throws {
        let other = try await StubServer.start(); defer { other.stop() }
        let s = try await StubServer.start(); defer { s.stop() }
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

    @Test func targetAllowListAcceptsRealRelayTargets() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        let sender = try URLSessionRequestSender(loopbackOrigin: s.origin)
        for t in ["/v2/workspaces/00ff/bridge/aa?after=3&wait=25", "/v2/devices/ab/revocation?after=ab_-Z9&limit=32", "/a%2Fb", "/healthz"] {
            let r = try await sender.send(get(t))
            #expect(r.status == 200)
        }
    }

    @Test func aCompressedResponseIsRefusedAtTheHeaders() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        let sender = try URLSessionRequestSender(loopbackOrigin: s.origin)
        for enc in ["gzip", "deflate", "br", "GZIP", "gzip, identity"] {
            // Garbage that is not valid compressed data. URLSession's own gzip and br decoders may fail on it before the delegate sees
            // the headers (then it is `.disconnected`); otherwise the header check refuses it. Either way no data is returned.
            // The real-bomb test below pins the header check itself.
            s.handle { _ in .raw(StubServer.http(200, headers: ["Content-Encoding": enc], body: String(repeating: "z", count: 64))) }
            do { _ = try await sender.send(self.get("/bomb")); Issue.record("\(enc) was accepted") }
            catch let e as TransportError { #expect(e == .responseTooLarge || e == .disconnected) }
        }
        #expect(s.requests.allSatisfy { $0.headers["accept-encoding"] == "identity" })
        s.handle { _ in .raw(StubServer.http(200, headers: ["Content-Encoding": "identity"], body: "{}")) }
        let ok = try await sender.send(get("/plain"))
        #expect(ok.status == 200)
    }

    /// A real gzip bomb (512 MiB of zeros in about 0.5 MB), served with `Content-Encoding: gzip`. It must be refused without the
    /// decoded bytes ever being buffered: the error is `responseTooLarge` and the process stays small.
    @Test func aRealGzipBombIsRefusedWithoutDecoding() async throws {
        let bomb = try Self.gzipOfZeros(mebibytes: 512)
        #expect(bomb.count < 2 << 20)
        let s = try await StubServer.start(); defer { s.stop() }
        var raw = Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Type: application/json\r\nContent-Length: \(bomb.count)\r\nConnection: close\r\n\r\n".utf8)
        raw.append(bomb)
        let response = raw
        s.handle { _ in .raw(response) }
        let sender = try URLSessionRequestSender(loopbackOrigin: s.origin)
        await #expect(throws: TransportError.responseTooLarge) { _ = try await sender.send(self.get("/bomb")) }
        // Refused at the headers: the delegate was never handed a decoded chunk (unfixed, it receives one of hundreds of MiB first).
        #expect(sender.largestChunkSeen == 0)
    }

    static func gzipOfZeros(mebibytes: Int) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "head -c \(mebibytes << 20) /dev/zero | gzip -9"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    @Test func aRequestBodyIsReadBeforeTheStubAnswers() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        s.handle { _ in .raw(StubServer.http(413, body: "{}")) }
        let sender = try URLSessionRequestSender(loopbackOrigin: s.origin)
        let r = try await sender.send(get("/big", method: "POST", body: Data(repeating: 1, count: 1 << 20)))
        #expect(r.status == 413)
    }

    @Test func aBodyOverTheCapIsCutOffWhileReading() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
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
        let s = try await StubServer.start(); defer { s.stop() }
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
        let s = try await StubServer.start(); defer { s.stop() }
        s.handle { _ in .hang }
        let sender = try URLSessionRequestSender(loopbackOrigin: s.origin)
        let t = Task { try await sender.send(self.get("/hang")) }
        try await Task.sleep(for: .milliseconds(200))
        t.cancel()
        await #expect(throws: CancellationError.self) { _ = try await t.value }
    }

    @Test func sendsOnlyTheHeadersTheRequestCarriesAndKeepsNoCookies() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
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
