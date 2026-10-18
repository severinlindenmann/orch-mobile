import Foundation
import Testing
@testable import OrchClient

/// The real sender (Network.framework + our HTTP/1.1 parser) against loopback stub servers. Always run, no relay needed.
/// TLS is not exercised here and there is no TLS-skip option: these tests use the DEBUG + package loopback plain path only.
@Suite(.serialized) struct NWSenderTests {
    func get(_ target: String, headers: [String: String] = [:], method: String = "GET", body: Data = Data()) throws -> WireRequest {
        try WireRequest(method: method, target: target, headers: headers, body: body, clientAddress: "127.0.0.1")
    }

    static func resp(_ status: Int = 200, _ headers: [String], body: Data = Data()) -> Data {
        Data(("HTTP/1.1 \(status) X\r\n" + headers.map { $0 + "\r\n" }.joined() + "\r\n").utf8) + body
    }

    func sender(_ s: StubServer, cap: Int = 4096, idle: TimeInterval = 5, total: TimeInterval = 10) throws -> NWRequestSender {
        try NWRequestSender(loopbackOrigin: s.origin, maxResponseBytes: cap, requestTimeout: idle, resourceTimeout: total)
    }

    func expectDisconnected(_ raw: Data, _ note: String = "", sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        s.handle { _ in .raw(raw) }
        let snd = try sender(s)
        do { _ = try await snd.send(get("/x")); Issue.record("accepted: \(note)", sourceLocation: sourceLocation) }
        catch let e as TransportError { #expect(e == .disconnected, "\(note): \(e)", sourceLocation: sourceLocation) }
    }

    // MARK: origin and target

    @Test func productionInitAcceptsOnlyHTTPSOrigins() throws {
        _ = try NWRequestSender(origin: "https://relay.example.org")
        for o in ["http://127.0.0.1:8101", "http://localhost:8101", "http://relay.example.org", "https://relay.example.org/", "ftp://a", ""] {
            #expect(throws: RealmViolation.self) { _ = try NWRequestSender(origin: o) }
        }
        #expect(throws: RealmViolation.invalidOrigin) { _ = try RealmContext.live(origin: "http://127.0.0.1:8101") }
        #expect(throws: RealmViolation.invalidOrigin) { _ = try RealmContext.liveLoopbackForTesting(origin: "http://localhost:8101") }
        #expect(throws: RealmViolation.invalidOrigin) { _ = try RealmContext.liveLoopbackForTesting(origin: "http://127.0.0.1") }
        #expect(throws: RealmViolation.invalidOrigin) { _ = try RealmContext.liveLoopbackForTesting(origin: "https://127.0.0.1:1") }
        #expect(throws: RealmViolation.self) { _ = try NWRequestSender(loopbackOrigin: "http://relay.example.org:80") }
        #expect(try RealmContext.liveLoopbackForTesting(origin: "http://[::1]:8101").realm == .live)
    }

    @Test func targetsThatCouldChangeTheRequestAreRefusedBeforeIO() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        let snd = try sender(s)
        for t in ["//evil.example/x", "http://evil.example/x", "x", "/a b", "/a#f", "/a\\b", "", "/a<b", "/a>b", "/a|b", "/a{b}", "/a\"b", "/a^b", "/a`b",
                  "/a[b]", "/a%", "/a%z", "/a%zz", "/a%2", "/a?b=%zz", "/a?b?c", "/a\u{e9}", "/a\nb", "/a\r\nHost: evil", "/a\u{0}b"] {
            await #expect(throws: TransportError.invalidArgument) { _ = try await snd.send(self.get(t)) }
        }
        for h in ["host", "content-length", "transfer-encoding", "connection", "accept-encoding", "user-agent", "expect", "upgrade", "proxy-authorization"] {
            await #expect(throws: TransportError.invalidArgument) { _ = try await snd.send(self.get("/x", headers: [h: "v"])) }
        }
        #expect(s.requests.isEmpty)
    }

    @Test func targetAllowListAcceptsRealRelayTargets() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        let snd = try sender(s)
        for t in ["/v2/workspaces/00ff/bridge/aa?after=3&wait=25", "/v2/devices/ab/revocation?after=ab_-Z9&limit=32", "/a%2Fb", "/healthz"] {
            #expect(try await snd.send(get(t)).status == 200)
        }
    }

    @Test func sendsExactlyTheDocumentedHeaders() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        s.handle { _ in .raw(StubServer.http(200, headers: ["Set-Cookie": "a=b"], body: "{}")) }
        let snd = try sender(s)
        _ = try await snd.send(get("/first"))
        let r = try await snd.send(get("/second?after=3", headers: ["authorization": "Bearer abc", "content-type": "application/json"], method: "POST", body: Data("{}".utf8)))
        #expect(r.status == 200)
        let seen = s.requests.last!
        #expect(seen.method == "POST" && seen.target == "/second?after=3")
        #expect(Set(seen.headers.keys) == ["host", "user-agent", "accept-encoding", "connection", "authorization", "content-type", "content-length"])
        #expect(seen.headers["accept-encoding"] == "identity" && seen.headers["connection"] == "close" && seen.headers["host"] == "127.0.0.1:\(s.port)")
    }

    @Test func onlyTheMethodsTheProtocolUsesAreAllowed() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        let snd = try sender(s)
        for m in ["HEAD", "CONNECT", "TRACE", "OPTIONS", "PATCH", "get", "G ET", ""] {
            await #expect(throws: TransportError.invalidArgument) { _ = try await snd.send(self.get("/x", method: m)) }
        }
        for m in ["GET", "POST", "PUT", "DELETE"] { #expect(try await snd.send(get("/x", method: m)).status == 200) }
    }

    @Test func repeatedHeadersNeverFailARequestUnlessTheyAreFramingOrSecurityRelevant() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        let snd = try sender(s)
        // CDN-style repeats of headers the client never reads: first value kept, no failure
        s.handle { _ in .raw(Self.resp(200, ["Set-Cookie: a=1", "Set-Cookie: b=2", "Server-Timing: x;dur=1", "Server-Timing: y;dur=2", "Via: 1", "Via: 2", "Content-Length: 0"])) }
        let r = try await snd.send(get("/x"))
        #expect(r.header("set-cookie") == "a=1" && r.header("server-timing") == "x;dur=1" && r.header("via") == "1")
        // equal repeats of strict headers are fine, conflicting ones are refused
        s.handle { _ in .raw(Self.resp(200, ["Content-Type: application/json", "content-type: application/json", "Retry-After: 3", "Content-Length: 0"])) }
        #expect(try await snd.send(get("/x")).header("retry-after") == "3")
        for (name, repeated) in [("content-type", ["Content-Type: a", "Content-Type: b"]), ("retry-after", ["Retry-After: 1", "Retry-After: 2"]), ("location", ["Location: /a", "Location: /b"])] {
            try await expectDisconnected(Self.resp(302, repeated + ["Content-Length: 0"]), name)
        }
    }

    @Test func chunkedOnHTTP10IsRefused() async throws {
        try await expectDisconnected(Data("HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8), "1.0 chunked")
        let s = try await StubServer.start(); defer { s.stop() }
        s.handle { _ in .raw(Data("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nab".utf8)) }
        #expect(try await sender(s).send(get("/x")).body == Data("ab".utf8))
    }

    @Test func aLargeHeadBlockIsScannedIncrementally() throws {
        let raw = Data("HTTP/1.1 200 OK\r\n".utf8) + Data((0..<60).map { "X-\($0): \(String(repeating: "v", count: 200))\r\n" }.joined().utf8) + Data("Content-Length: 1\r\n\r\nz".utf8)
        var p = HTTP1ResponseParser(maxBody: 10)
        for b in raw { try p.feed(Data([b])) }                     // one byte at a time: linear, and the terminator is found across reads
        #expect(p.isComplete && p.body == Data("z".utf8))
        var bare = HTTP1ResponseParser(maxBody: 10)
        #expect(throws: HTTP1ResponseParser.Failure.self) { for b in Data("HTTP/1.1 200 OK\r\nX: a\nb: c\r\n\r\n".utf8) { try bare.feed(Data([b])) } }
        var bareCR = HTTP1ResponseParser(maxBody: 10)
        #expect(throws: HTTP1ResponseParser.Failure.self) { for b in Data("HTTP/1.1 200 OK\r\nX: a\rb: c\r\n\r\n".utf8) { try bareCR.feed(Data([b])) } }
    }

    /// Every wire-header name the client reads must be a `strictRepeats` header, so a conflicting repeat of it is refused rather than
    /// silently resolved to the first value. Update BOTH lists when the client starts reading another reply header.
    static let wireHeadersTheClientReads: Set<String> = ["retry-after"]     // HostAPI.retryAfter; (content-type in WorkspaceSession is a bridge header)

    @Test func everyWireHeaderTheClientReadsIsAStrictRepeat() {
        #expect(Self.wireHeadersTheClientReads.isSubset(of: HTTP1ResponseParser.strictRepeats))
        // the framing headers the parser itself acts on are strict too
        #expect(["content-length", "transfer-encoding", "content-encoding"].allSatisfy(HTTP1ResponseParser.strictRepeats.contains))
    }

    // MARK: redirects

    @Test func aRedirectIsReturnedNotFollowed() async throws {
        let other = try await StubServer.start(); defer { other.stop() }
        let s = try await StubServer.start(); defer { s.stop() }
        let snd = try sender(s)
        for status in [301, 302, 303, 307, 308] {
            s.handle { _ in .raw(Self.resp(status, ["Location: \(other.origin)/landing", "Content-Length: 0"])) }
            let r = try await snd.send(get("/v2/x", method: "POST", body: Data("{}".utf8)))
            #expect(r.status == status && r.header("location") == "\(other.origin)/landing")
        }
        #expect(other.requests.isEmpty)
        #expect(HostAPI.failure(of: try await snd.send(get("/y"))) == .badReply)
    }

    // MARK: size cap

    @Test func contentLengthAtTheCapPassesAndOverIsRefusedAtTheHeaders() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        let snd = try sender(s, cap: 4096)
        s.handle { _ in .raw(Self.resp(200, ["Content-Length: 4096"], body: Data(repeating: 0x78, count: 4096))) }
        #expect(try await snd.send(get("/exact")).body.count == 4096)
        let before = snd.bytesRead
        s.handle { _ in .raw(Self.resp(200, ["Content-Length: 4097"], body: Data(repeating: 0x78, count: 4097))) }
        await #expect(throws: TransportError.responseTooLarge) { _ = try await snd.send(self.get("/over")) }
        #expect(snd.bytesRead - before <= HTTP1ResponseParser.maxHeaderBlock + NWRequestSender.readBufferBytes)
    }

    @Test func chunkedAtTheCapPassesAndOverIsRefused() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        let snd = try sender(s, cap: 4096)
        @Sendable func chunked(_ sizes: [Int]) -> Data {
            var d = Data()
            for n in sizes { d += Data(String(n, radix: 16).utf8) + Data("\r\n".utf8) + Data(repeating: 0x78, count: n) + Data("\r\n".utf8) }
            return Self.resp(200, ["Transfer-Encoding: chunked"], body: d + Data("0\r\n\r\n".utf8))
        }
        let exact = chunked([1000, 3096]), over = chunked([1000, 3097]), one = chunked([5000])
        s.handle { _ in .raw(exact) }
        #expect(try await snd.send(get("/exact")).body.count == 4096)
        s.handle { _ in .raw(over) }
        await #expect(throws: TransportError.responseTooLarge) { _ = try await snd.send(self.get("/over")) }
        s.handle { _ in .raw(one) }
        await #expect(throws: TransportError.responseTooLarge) { _ = try await snd.send(self.get("/over1")) }
        s.handle { _ in .endless(chunk: 1000) }
        await #expect(throws: TransportError.responseTooLarge) { _ = try await snd.send(self.get("/endless")) }
        let big = try NWRequestSender(loopbackOrigin: s.origin)
        #expect(big.maxResponseBytes == 4 << 20)
        s.handle { _ in .endless(chunk: 200_000) }
        await #expect(throws: TransportError.responseTooLarge) { _ = try await big.send(self.get("/endless-default")) }
    }

    @Test func aCloseDelimitedBodyIsRefused() async throws {
        try await expectDisconnected(Self.resp(200, ["Content-Type: application/json"], body: Data("{}".utf8)), "no framing")
    }

    // MARK: compression bombs (nothing is ever decoded)

    #if os(macOS)   // Process (gzip of zeros)
    @Test func compressedBombsAreRefusedAtTheHeadersWithoutDecoding() async throws {
        let gz = try Self.gzipOfZeros(mebibytes: 512)
        #expect(gz.count < 2 << 20)
        let cases: [(String, [String], Data)] = [
            ("gzip + type", ["Content-Encoding: gzip", "Content-Type: application/json", "Content-Length: \(gz.count)"], gz),
            ("gzip no type", ["Content-Encoding: gzip", "Content-Length: \(gz.count)"], gz),
            ("br no type", ["Content-Encoding: br", "Content-Length: 3000"], Data(repeating: 0x1b, count: 3000)),
            ("deflate no type", ["Content-Encoding: deflate", "Content-Length: 3000"], Data(repeating: 0x78, count: 3000)),
            ("GZIP chunked", ["Content-Encoding: GZIP", "Transfer-Encoding: chunked"], Data("5\r\nabcde\r\n0\r\n\r\n".utf8)),
            ("gzip, identity", ["Content-Encoding: gzip, identity", "Content-Length: 3"], Data("abc".utf8)),
            ("second field", ["Content-Encoding: identity", "Content-Encoding: gzip", "Content-Length: 3"], Data("abc".utf8)),
        ]
        for (name, headers, body) in cases {
            let s = try await StubServer.start(); defer { s.stop() }
            let raw = Self.resp(200, headers, body: body)
            s.handle { _ in .raw(raw) }
            let snd = try sender(s, cap: 1 << 20)
            do { _ = try await snd.send(get("/bomb")); Issue.record("\(name) accepted") }
            catch let e as TransportError { #expect(e == .responseTooLarge, "\(name): \(e)") }
            // one read buffer past the header block at most: the body is never consumed
            #expect(snd.bytesRead <= HTTP1ResponseParser.maxHeaderBlock + NWRequestSender.readBufferBytes, "\(name): \(snd.bytesRead)")
        }
        let s = try await StubServer.start(); defer { s.stop() }
        s.handle { _ in .raw(StubServer.http(200, headers: ["Content-Encoding": "identity"], body: "{}")) }
        #expect(try await sender(s).send(get("/plain")).status == 200)
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
    #endif

    // MARK: malformed framing

    @Test func malformedChunkFramingIsRefused() async throws {
        let h = ["Transfer-Encoding: chunked"]
        for (name, body) in [("zz", "zz\r\nab\r\n0\r\n\r\n"), ("negative", "-1\r\nab\r\n0\r\n\r\n"), ("plus", "+2\r\nab\r\n0\r\n\r\n"), ("empty size", "\r\nab\r\n0\r\n\r\n"),
                             ("nine digits", "000000002\r\nab\r\n0\r\n\r\n"), ("space", "2 \r\nab\r\n0\r\n\r\n"), ("bad data end", "2\r\nabXX0\r\n\r\n"),
                             ("bare LF size", "2\nab\r\n0\r\n\r\n"), ("bad extension", "2;a\u{1}\r\nab\r\n0\r\n\r\n"), ("overflow", "ffffffffff\r\n"),
                             ("bare LF trailer", "0\r\nX: y\n\r\n")] {
            try await expectDisconnected(Self.resp(200, h, body: Data(body.utf8)), name)
        }
    }

    @Test func framingConflictsAreRefused() async throws {
        let cases: [(String, [String])] = [
            ("CL+TE", ["Content-Length: 2", "Transfer-Encoding: chunked"]),
            ("duplicate CL equal", ["Content-Length: 2", "Content-Length: 2"]),
            ("duplicate CL different", ["Content-Length: 2", "Content-Length: 3"]),
            ("CL list", ["Content-Length: 2, 2"]), ("CL plus", ["Content-Length: +2"]), ("CL inner space", ["Content-Length: 1 2"]),
            ("CL hex", ["Content-Length: 0x2"]), ("CL overflow", ["Content-Length: 99999999999999999999"]),
            ("TE gzip", ["Transfer-Encoding: gzip, chunked"]), ("TE twice", ["Transfer-Encoding: chunked", "Transfer-Encoding: chunked"]),
            ("TE param", ["Transfer-Encoding: chunked;q=1"]), ("TE identity", ["Transfer-Encoding: identity"]),
        ]
        for (name, headers) in cases { try await expectDisconnected(Self.resp(200, headers, body: Data("ab".utf8)), name) }
    }

    @Test func malformedHeadsAreRefused() async throws {
        let cases: [(String, Data)] = [
            ("bare LF", Data("HTTP/1.1 200 OK\nContent-Length: 2\n\nab".utf8)),
            ("bare CR", Data("HTTP/1.1 200 OK\r\nX: a\rb\r\nContent-Length: 2\r\n\r\nab".utf8)),
            ("obs-fold", Self.resp(200, ["X: a", " b", "Content-Length: 2"], body: Data("ab".utf8))),
            ("space before colon", Self.resp(200, ["Content-Length : 2"], body: Data("ab".utf8))),
            ("bad version", Data("HTTP/2.0 200 OK\r\nContent-Length: 2\r\n\r\nab".utf8)),
            ("no reason separator", Data("HTTP/1.1 200OK\r\nContent-Length: 2\r\n\r\nab".utf8)),
            ("101", Self.resp(101, ["Upgrade: x"])), ("NUL", Data("HTTP/1.1 200 OK\r\nX: a\u{0}b\r\nContent-Length: 2\r\n\r\nab".utf8)),
        ]
        for (name, raw) in cases { try await expectDisconnected(raw, name) }
    }

    @Test func anOverLongHeaderBlockIsRefusedWithoutReadingItAll() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        let raw = Self.resp(200, ["X-Pad: " + String(repeating: "a", count: 40_000), "Content-Length: 0"])
        s.handle { _ in .raw(raw) }
        let snd = try sender(s)
        await #expect(throws: TransportError.disconnected) { _ = try await snd.send(self.get("/x")) }
        #expect(snd.bytesRead <= HTTP1ResponseParser.maxHeaderBlock + NWRequestSender.readBufferBytes)
        try await expectDisconnected(Self.resp(200, (0..<65).map { "X-\($0): v" } + ["Content-Length: 0"]), "65 fields")
        let ok = try await StubServer.start(); defer { ok.stop() }
        ok.handle { _ in .raw(Self.resp(200, (0..<60).map { "X-\($0): v" } + ["Content-Length: 0"])) }
        #expect(try await sender(ok).send(get("/x")).headers.count == 60 + 1)
    }

    @Test func interimRepliesAreSkippedWithinBounds() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        let interim = Self.resp(100, [])
        s.handle { _ in .raw(interim + Self.resp(200, ["Content-Length: 2"], body: Data("{}".utf8))) }
        #expect(try await sender(s).send(get("/x")).body == Data("{}".utf8))
        let five = Data((0..<5).map { _ in interim }.joined()) + Self.resp(200, ["Content-Length: 0"])
        try await expectDisconnected(five, "five interim")
    }

    @Test func noBodyStatuses() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        let snd = try sender(s)
        for (status, headers) in [(204, [String]()), (304, ["ETag: x"]), (205, ["Content-Length: 0"]), (205, [String]())] {
            s.handle { _ in .raw(Self.resp(status, headers)) }
            let r = try await snd.send(get("/x")); #expect(r.status == status && r.body.isEmpty)
        }
        try await expectDisconnected(Self.resp(204, ["Content-Length: 2"], body: Data("ab".utf8)), "204 with CL")
        try await expectDisconnected(Self.resp(205, ["Content-Length: 2"], body: Data("ab".utf8)), "205 with body")
    }

    // MARK: fragmentation and coalescing

    @Test func responsesParseAtEveryByteBoundaryAndCoalesced() async throws {
        let json = Data(#"{"chunks":[]}"#.utf8)
        let responses: [(String, Data, Int, Data)] = [
            ("content-length", Self.resp(200, ["Content-Type: application/json", "Content-Length: \(json.count)"], body: json), 200, json),
            ("chunked + extension + trailer", Self.resp(200, ["Transfer-Encoding: chunked"], body: Data("5;x=1\r\nhello\r\n4\r\n abc\r\n0\r\nT: v\r\n\r\n".utf8)), 200, Data("hello abc".utf8)),
            ("interim then final", Self.resp(100, []) + Self.resp(202, ["Content-Length: 2"], body: Data("{}".utf8)), 202, Data("{}".utf8)),
            ("204", Self.resp(204, []), 204, Data()),
        ]
        for (name, raw, status, body) in responses {
            let s = try await StubServer.start(); defer { s.stop() }
            let snd = try sender(s)
            s.handle { _ in .raw(raw) }
            let whole: WireReply
            do { whole = try await snd.send(get("/x")) } catch { Issue.record("\(name) coalesced threw \(error)"); continue }
            #expect(whole.status == status && whole.body == body, "\(name) coalesced")
            for cut in 1..<raw.count {
                let pieces = [raw.prefix(cut), raw.dropFirst(cut)].map { Data($0) }
                s.handle { _ in .pieces(pieces, gapMs: 2) }
                do {
                    let r = try await snd.send(get("/x"))
                    #expect(r.status == status && r.body == body, "\(name) split at \(cut)")
                } catch { Issue.record("\(name) split at \(cut) threw \(error)") }
            }
        }
    }

    @Test func theParserAloneGivesTheSameResultAtEveryByteBoundary() throws {
        let raw = Self.resp(200, ["Transfer-Encoding: chunked", "X-A: b"], body: Data("4\r\nwxyz\r\n0\r\n\r\n".utf8))
        for cut in 0...raw.count {
            var p = HTTP1ResponseParser(maxBody: 100)
            try p.feed(raw.prefix(cut)); try p.feed(raw.dropFirst(cut))
            #expect(p.isComplete && p.body == Data("wxyz".utf8) && p.status == 200)
        }
        var oneByte = HTTP1ResponseParser(maxBody: 100)
        for b in raw { try oneByte.feed(Data([b])) }
        #expect(oneByte.isComplete && oneByte.body == Data("wxyz".utf8))
    }

    // MARK: time and failure

    @Test func earlyCloseMidBodyIsDisconnected() async throws {
        try await expectDisconnected(Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabc".utf8), "CL truncated")
        try await expectDisconnected(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab".utf8), "chunk truncated")
        try await expectDisconnected(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n".utf8), "no last chunk")
        try await expectDisconnected(Data("HTTP/1.1 200 OK\r\nContent-Le".utf8), "head truncated")
    }

    @Test func silenceTimesOutOnTheIdleLimit() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        s.handle { _ in .hang }
        let snd = try sender(s, idle: 0.5, total: 5)
        let t0 = ContinuousClock.now
        await #expect(throws: TransportError.disconnected) { _ = try await snd.send(self.get("/hang")) }
        #expect(ContinuousClock.now - t0 < .seconds(3))
    }

    @Test func aSlowLorisCannotExtendTheAbsoluteDeadline() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        s.handle { _ in .trickle(prefix: Data("HTTP/1.1 200 OK\r\nX-A: ".utf8), everyMs: 100) }
        let snd = try sender(s, idle: 0.6, total: 1.5)
        let t0 = ContinuousClock.now
        await #expect(throws: TransportError.disconnected) { _ = try await snd.send(self.get("/loris")) }
        #expect(ContinuousClock.now - t0 < .seconds(4))
        // a slow body in the same way
        s.handle { _ in .trickle(prefix: Data("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n".utf8), everyMs: 100) }
        let t1 = ContinuousClock.now
        await #expect(throws: TransportError.self) { _ = try await snd.send(self.get("/loris2")) }
        #expect(ContinuousClock.now - t1 < .seconds(4))
    }

    @Test func aRefusedConnectionIsDisconnected() async throws {
        let s = try await StubServer.start()
        let port = s.port
        s.stop()
        // idle limit far above the assertion: `.waiting` (refused / no path) must be final at once, not after the idle timeout
        let dead = try NWRequestSender(loopbackOrigin: "http://127.0.0.1:\(port)", requestTimeout: 30, resourceTimeout: 60)
        let t0 = ContinuousClock.now
        await #expect(throws: TransportError.disconnected) { _ = try await dead.send(self.get("/x")) }
        #expect(ContinuousClock.now - t0 < .seconds(5))
    }

    @Test func cancellationMapsToCancellationErrorOnlyForTheCaller() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        s.handle { _ in .hang }
        let snd = try sender(s)
        let t = Task { try await snd.send(self.get("/hang")) }
        try await Task.sleep(for: .milliseconds(200))
        t.cancel()
        await #expect(throws: CancellationError.self) { _ = try await t.value }
        // cancelled before it starts
        let early = Task { () -> WireReply in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await snd.send(self.get("/never"))
        }
        await #expect(throws: CancellationError.self) { _ = try await early.value }
        #expect(s.count("/never") == 0)
        // a connection dropped by the server is not a cancellation
        s.handle { _ in .truncated(Data("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nab".utf8)) }
        await #expect(throws: TransportError.disconnected) { _ = try await snd.send(self.get("/cut")) }
    }

    @Test func aPerRequestCapAllowsOneLargeReplyAndTheDefaultStaysTight() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        let body = String(repeating: "x", count: 300_000)
        s.handle { _ in .raw(StubServer.http(200, body: body)) }
        let snd = try sender(s, cap: 100_000)
        await #expect(throws: TransportError.responseTooLarge) { _ = try await snd.send(self.get("/blob")) }
        let big = try WireRequest(method: "GET", target: "/blob", body: Data(), clientAddress: "127.0.0.1", options: RequestOptions(maxResponseBytes: 400_000))
        #expect(try await snd.send(big).body.count == 300_000)
        for bad in [0, -1, 1 << 30] {
            let r = try WireRequest(method: "GET", target: "/blob", body: Data(), clientAddress: "127.0.0.1", options: RequestOptions(maxResponseBytes: bad))
            await #expect(throws: TransportError.invalidArgument) { _ = try await snd.send(r) }
        }
    }

    @Test func aPerRequestDeadlineReplacesTheDefaultForThatRequestOnly() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        s.handle { _ in .hang }
        let snd = try sender(s, idle: 30, total: 30)
        let r = try WireRequest(method: "GET", target: "/slow", body: Data(), clientAddress: "127.0.0.1", options: RequestOptions(resourceTimeout: 0.5))
        let t0 = ContinuousClock.now
        await #expect(throws: TransportError.disconnected) { _ = try await snd.send(r) }
        #expect(ContinuousClock.now - t0 < .seconds(10))
    }

    @Test func aFileBodyIsStreamedWithItsExactContentLength() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nw-body-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 7, count: 1_000_003).write(to: url)
        s.handle { _ in .raw(StubServer.http(201, body: "{}")) }
        let snd = try sender(s)
        let r = try WireRequest(method: "PUT", target: "/up", headers: ["content-type": "application/octet-stream"], body: Data(), clientAddress: "127.0.0.1", bodyFile: url)
        #expect(try await snd.send(r).status == 201)
        #expect(s.requests.last?.headers["content-length"] == "1000003")
        // a file and a body together, or a missing file, are refused before any I/O
        let both = try WireRequest(method: "PUT", target: "/up", body: Data([1]), clientAddress: "127.0.0.1", bodyFile: url)
        await #expect(throws: TransportError.invalidArgument) { _ = try await snd.send(both) }
        let missing = try WireRequest(method: "PUT", target: "/up", clientAddress: "127.0.0.1", bodyFile: url.appendingPathExtension("none"))
        await #expect(throws: TransportError.invalidArgument) { _ = try await snd.send(missing) }
    }

    @Test func anEarlyFinalReplyStopsTheUpload() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        s.readsRequestBody = false
        s.handle { _ in .raw(StubServer.http(413, body: "{}")) }
        let snd = try sender(s)
        let t0 = ContinuousClock.now
        let r = try await snd.send(get("/big", method: "POST", body: Data(repeating: 1, count: 8 << 20)))
        #expect(r.status == 413)
        #expect(ContinuousClock.now - t0 < .seconds(5))
    }

    @Test func aRequestBodyIsReadBeforeTheStubAnswers() async throws {
        let s = try await StubServer.start(); defer { s.stop() }
        s.handle { _ in .raw(StubServer.http(413, body: "{}")) }
        let r = try await sender(s).send(get("/big", method: "POST", body: Data(repeating: 1, count: 1 << 20)))
        #expect(r.status == 413)
    }
}
