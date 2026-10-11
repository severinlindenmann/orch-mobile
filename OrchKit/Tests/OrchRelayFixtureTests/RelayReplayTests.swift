import Foundation
import Testing
import OrchClient
import OrchFakeHost
import OrchProtocol
import OrchTestVectors

/// Executable replay of the relay HTTP v2 fixtures against the in-process FakeRelay. Each case's `given` is seeded through the
/// FakeRelay's package-scope test seeds, the request is sent byte for byte (`cj(json)`, raw body or recipe), and status, the
/// `Retry-After` and `Content-Type` headers and the exact JSON are compared. Files listed in `FixtureCoverage.replayable` are
/// replayed in full; an unseeded case fails rather than being skipped.
private struct FixedWall: WallClock { let nowMs: Int64 }

private final class ScriptedEntropy: Entropy, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data]
    init(_ queue: [Data]) { self.queue = queue }
    func bytes(_ count: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        if !queue.isEmpty { return queue.removeFirst() }
        return Data(count: count)
    }
}

private let fixtureOrigin = "https://relay.dev.severin.io"
private let fixtureDevice = ID16(hex: "4177b27d8e4ac182e8d388b247d2b136")!

@Suite struct FixtureReplayTests {
    static let files = FixtureSchemaTests.files

    /// The signing key of fixture device 4177...: its certificate is the success case of device_put.json.
    static func deviceKey() throws -> SigningPublicKey {
        let put = try #require(files.first { $0.fileName == "device_put.json" })
        let pub = try #require(put.cases[0].request["json"]?["cert"]?["o"]?["dk_sig_pub"]?.string.flatMap { B64U.decode($0) })
        return try SigningPublicKey(x963: pub)
    }

    static func body(_ r: Fixtures.JSON) throws -> Data {
        if let j = r["json"] { return try canonicalJSON(try #require(j.jsonValue)) }
        if let b = r["body_b64u"]?.string { return try #require(B64U.decode(b)) }
        if let rec = r["body_recipe"] {
            var d = try #require(rec["prefix_b64u"]?.string.flatMap { B64U.decode($0) })
            d.append(Data(repeating: UInt8(try #require(rec["byte"]?.int)), count: Int(try #require(rec["count"]?.int))))
            d.append(try #require(rec["suffix_b64u"]?.string.flatMap { B64U.decode($0) }))
            return d
        }
        return Data()
    }

    static func target(_ r: Fixtures.JSON) throws -> String {
        let path = try #require(r["path"]?.string)
        let q = (r["query"]?.object ?? [:]).sorted { $0.key < $1.key }.compactMap { k, v in v.string.map { "\(k)=\($0)" } }
        return q.isEmpty ? path : path + "?" + q.joined(separator: "&")
    }

    func replay(_ f: Fixtures.File, _ c: Fixtures.Case) async throws {
        let id = caseID(f, c)
        let now = try #require(c.given["now_ms"]?.int, "\(id) now_ms")
        let resp = c.response, req = c.request
        // Entropy: the relay mints the challenge or the token the fixture shows.
        var script: [Data] = []
        if f.fileName == "session_challenge.json", c.name == "success" { script = [try #require(resp["json"]?["challenge"]?.string.flatMap { B64U.decode($0) })] }
        if f.fileName == "session_login.json", c.name == "success" { script = [try #require(resp["json"]?["token"]?.string.flatMap { B64U.decode($0) })] }
        var limits = RelayLimits()
        if let ra = resp["headers"]?["Retry-After"]?.string, let n = Int(ra) { limits.retryAfterSeconds = n }
        if f.fileName == "session_challenge.json", c.name == "refusal_429_rate_limited" { limits.maxOutstandingChallenges = 0 }   // the outstanding-challenge cap is full
        let relay = FakeRelay(testingContext: try RealmContext.live(origin: fixtureOrigin), clock: ContinuousClock(),
                              wall: FixedWall(nowMs: now), entropy: ScriptedEntropy(script), limits: limits)

        // given.scenario -> seeds
        let challenge = req["json"]?["challenge"]?.string.flatMap { B64U.decode($0) }
        let key = try Self.deviceKey()
        switch f.fileName {
        case "session_challenge.json":
            guard ["success", "refusal_400_malformed", "refusal_413_too_large", "refusal_429_rate_limited"].contains(c.name) else {
                Issue.record("\(id): no seed for this scenario"); return
            }
        case "session_login.json":
            var dirKey = key
            var verdict: RelayRefusal.Code?
            switch c.name {
            case "success", "refusal_400_malformed", "refusal_413_too_large": break
            case "refusal_400_cert_expired": verdict = .certExpired
            case "refusal_400_cert_invalid": verdict = .certInvalid
            case "refusal_401_bad_signature":
                dirKey = try #require(try vectorSigningKeys().values.first { $0.x963 != key.x963 })
            case "refusal_401_expired": break
            case "refusal_401_unknown_challenge": break
            case "refusal_403_revoked": await relay.seedRevoked(fixtureDevice)
            case "refusal_429_quota_exceeded":
                for i in 0..<8 {
                    await relay.seedSession(token: "live-\(i)", kind: .device, id: fixtureDevice, expiresMs: now + 20_000 + Int64(i) * 1000)
                }
            default: Issue.record("\(id): no seed for this scenario"); return
            }
            await relay.seedLoginDirectory(device: fixtureDevice, key: dirKey, verdict: verdict)
            if let challenge, c.name != "refusal_401_unknown_challenge", c.name != "refusal_413_too_large" {
                await relay.seedChallenge(challenge, expiresMs: c.name == "refusal_401_expired" ? now - 1 : now + 60_000)
            }
        case "session_logout.json":
            switch c.name {
            case "success": await relay.seedSession(token: "FAKE-device", kind: .device, id: fixtureDevice, expiresMs: now + 900_000)
            case "refusal_400_malformed", "refusal_413_too_large", "expired_token_retry": break
            default: Issue.record("\(id): no seed for this scenario"); return
            }
        default:
            Issue.record("\(id): file is listed replayable but has no replay seeds"); return
        }
        try await check(f, c, relay, Self.body(req), Self.target(req))
        if f.fileName == "session_logout.json", c.name == "success" {
            #expect(await relay.liveSessionTokens.isEmpty, "\(id): the token is gone after logout")
        }
        if f.fileName == "session_login.json", c.name == "success" {
            #expect(await relay.outstandingChallenges.isEmpty, "\(id): the challenge is consumed")
            #expect(await relay.liveSessionTokens.count == 1)
        }
        if f.fileName == "session_login.json", c.name == "refusal_429_quota_exceeded" {
            #expect(await relay.liveSessionTokens.count == 8, "\(id): existing tokens are preserved")
            #expect(await relay.outstandingChallenges.isEmpty, "\(id): the challenge is consumed")
        }
    }

    private func check(_ f: Fixtures.File, _ c: Fixtures.Case, _ relay: FakeRelay, _ body: Data, _ target: String) async throws {
        let id = caseID(f, c)
        var headers: [String: String] = [:]
        for (k, v) in c.request["headers"]?.object ?? [:] { if let s = v.string { headers[k] = s } }
        let reply = try await relay.send(WireRequest(method: c.request["method"]?.string ?? "", target: target, headers: headers, body: body, clientAddress: "fixture"))
        #expect(Int64(reply.status) == c.response["status"]?.int, "\(id) status \(reply.status) \(String(decoding: reply.body, as: UTF8.self))")
        for (k, v) in c.response["headers"]?.object ?? [:] {
            guard let want = v.string else { continue }
            #expect(reply.header(k)?.lowercased() == want.lowercased(), "\(id) header \(k): \(String(describing: reply.header(k)))")
        }
        #expect(reply.header("retry-after") == c.response["headers"]?["Retry-After"]?.string, "\(id) Retry-After")
        let got = try StrictJSON.parse(reply.body, maxBytes: .max)
        #expect(got == c.response["json"]?.jsonValue, "\(id) body \(String(decoding: reply.body, as: UTF8.self))")
        #expect(got.object?["host_api"] == nil)
    }

    @Test func replayableFixturesReplayAgainstFakeRelay() async throws {
        var n = 0
        for f in Self.files where FixtureCoverage.replayable.contains(f.fileName) {
            for c in f.cases { try await replay(f, c); n += 1 }
        }
        #expect(n == FixtureCoverage.replayable.reduce(0) { acc, name in acc + (Self.files.first { $0.fileName == name }?.cases.count ?? 0) })
        #expect(n > 0)
    }
}
