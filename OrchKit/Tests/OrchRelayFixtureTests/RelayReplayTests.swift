import Foundation
import Testing
import OrchClient
import OrchFakeHost
@testable import OrchProtocol
import OrchTestVectors

/// Executable replay of the relay HTTP v2 fixtures against the in-process FakeRelay. Each case's `given` is seeded (real signed
/// certificates and revocations through the relay's own publish paths where a case is about them; package-scope seeds only for
/// state that history would build, such as outstanding challenges and live tokens), the request is sent byte for byte, and status,
/// headers, the exact response bytes (fixtures are `cj` bytes) and the post-state are compared. Files in `FixtureCoverage.replayable`
/// are replayed in full; an unseeded case fails rather than being skipped.
final class MutableWall: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64
    init(_ ms: Int64) { self.ms = ms }
    var nowMs: Int64 { lock.lock(); defer { lock.unlock() }; return ms }
    func set(_ v: Int64) { lock.lock(); ms = v; lock.unlock() }
}

final class ScriptedEntropy: Entropy, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data]
    init(_ queue: [Data]) { self.queue = queue }
    func bytes(_ count: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        if !queue.isEmpty { return queue.removeFirst() }
        return Data(count: count)
    }
}

let fixtureOrigin = "https://relay.dev.severin.io"
private let otherOrigin = "https://other.relay.example.org"
let fixtureDevice = ID16(hex: "4177b27d8e4ac182e8d388b247d2b136")!

/// The vectors' `seed` is not the raw scalar: the reference derives `d = int(seed) mod (n-1) + 1`.
func scalar(fromSeed seed: Data) -> Data {
    let n = Array(Hex.decode("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")!)
    func cmp(_ a: [UInt8], _ b: [UInt8]) -> Int { for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }; return 0 }
    func sub(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = a, borrow = 0
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            var d = Int(a[i]) - Int(b[i]) - borrow
            borrow = d < 0 ? 1 : 0
            if d < 0 { d += 256 }
            out[i] = UInt8(d)
        }
        return out
    }
    let nMinus1 = sub(n, [UInt8](repeating: 0, count: 31) + [1])
    var s = Array(seed)
    while cmp(s, nMinus1) >= 0 { s = sub(s, nMinus1) }
    for i in stride(from: 31, through: 0, by: -1) { if s[i] == 255 { s[i] = 0 } else { s[i] += 1; break } }
    return Data(s)
}

/// The vector person key (with its private scalar) whose person id is `person`: it signs the fixture-derived certificates.
func personSigner(_ person: ID16) throws -> SoftwareSigner {
    let root = try StrictJSON.parse(Vectors.data, maxBytes: .max)
    for (name, k) in root.object?["suites"]?.object?["2"]?.object?["keys"]?.object ?? [:] where name.hasSuffix(".sig") {
        guard let seed = k.object?["seed"]?.string.flatMap({ Hex.decode($0) }) else { continue }
        let signer = try SoftwareSigner(testScalar: scalar(fromSeed: seed))
        if Identifiers.personID(signer.publicKey) == person { return signer }
    }
    throw Refusal.otherPerson
}

@Suite struct FixtureReplayTests {
    static let files = FixtureSchemaTests.files
    /// 4 session_challenge + 10 session_login + 4 session_logout cases (PR2), the 120 cases of the twelve PR3 directory and
    /// membership files, and the 104 cases of the nine PR4 files.
    static let expectedReplayed = 18 + 120 + 104

    static func file(_ name: String) throws -> Fixtures.File { try #require(files.first { $0.fileName == name }) }

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
        // the three late-added condition-only cases carry no now_ms; they share every other case's instant
        let now: Int64
        if let n = c.given["now_ms"]?.int { now = n } else {
            #expect(c.given["condition"] != nil && c.given["scenario"] == nil, "\(id) now_ms")
            now = 1_790_000_000_000
        }
        let req = c.request, resp = c.response
        var script: [Data] = []     // the relay mints the challenge or the token the fixture shows
        if f.fileName == "session_challenge.json", c.name == "success" { script = [try #require(resp["json"]?["challenge"]?.string.flatMap { B64U.decode($0) })] }
        if f.fileName == "session_login.json", c.name == "success" { script = [try #require(resp["json"]?["token"]?.string.flatMap { B64U.decode($0) })] }
        var limits = RelayLimits()
        let wall = MutableWall(now)
        let origin = (["session_login.json", "accounts.json"].contains(f.fileName) && c.name == "refusal_401_bad_signature") ? otherOrigin : fixtureOrigin
        Self.pr4Limits(f, c, &limits)
        let challengeCapCase = f.fileName == "session_challenge.json" && c.name == "refusal_429_rate_limited"
        if challengeCapCase { limits.maxOutstandingChallenges = 3 }
        let relay = FakeRelay(testingContext: try RealmContext.live(origin: origin), clock: ContinuousClock(), wall: wall,
                              entropy: ScriptedEntropy(script), limits: limits)
        let challenge = req["json"]?["challenge"]?.string.flatMap { B64U.decode($0) }
        var mustBeConsumed = false

        switch f.fileName {
        case "session_challenge.json":
            switch c.name {
            case "success", "refusal_400_malformed", "refusal_413_too_large": break
            case "refusal_429_rate_limited":
                // the cap is full; it frees when the earliest outstanding challenge expires (20 s from now): the fake derives Retry-After from that
                for (i, left) in [20_000, 30_000, 40_000].enumerated() { await relay.seedChallenge(Data(repeating: UInt8(i + 1), count: 32), expiresMs: now + Int64(left)) }
            default: Issue.record("\(id): no seed for this scenario"); return
            }
        case "session_login.json":
            let put = try Self.file("device_put.json")
            let cert = try #require(put.cases[0].request["json"]?["cert"]?.jsonValue)
            let certO = try #require(cert.object?["o"]?.object)
            let signer = try personSigner(try #require(certO["person_id"]?.string.flatMap { ID16(hex: $0) }))
            await relay.registerOwner(signer.publicKey)
            func resign(_ edit: (inout [String: JSONValue]) -> Void) throws -> JSONValue {
                var o = certO; edit(&o)
                return try SignedObject.sign(o, kind: .deviceCert, signer: signer).json
            }
            switch c.name {
            case "success", "refusal_400_malformed", "refusal_413_too_large", "refusal_401_bad_signature", "refusal_401_expired", "refusal_401_unknown_challenge":
                try await relay.publishCertificate(cert)
            case "refusal_400_cert_expired":
                // a real certificate that expired after the relay stored it
                wall.set(1_789_913_600_001)
                try await relay.publishCertificate(try resign { $0["expires_ms"] = .int(now - 1) })
                wall.set(now)
            case "refusal_400_cert_invalid":
                // a real certificate dated beyond the clock-skew window at login time
                let created = now + 2 * Suite2.skewMs
                wall.set(created)
                try await relay.publishCertificate(try resign { $0["created_ms"] = .int(created) })
                wall.set(now)
            case "refusal_403_revoked":
                try await relay.publishCertificate(cert)
                let rev = try Self.file("revocations_post.json").cases[0].request["json"]?["record"]?.jsonValue
                try await relay.publishRevocation(try #require(rev))
            case "refusal_429_quota_exceeded":
                try await relay.publishCertificate(cert)
                for i in 0..<8 { await relay.seedSession(token: "live-\(i)", kind: .device, id: fixtureDevice, expiresMs: now + 20_000 + Int64(i) * 1000) }
            default: Issue.record("\(id): no seed for this scenario"); return
            }
            if let challenge, c.name != "refusal_401_unknown_challenge", c.name != "refusal_413_too_large" {
                await relay.seedChallenge(challenge, expiresMs: c.name == "refusal_401_expired" ? now - 1 : now + 60_000)
                #expect(await relay.outstandingChallenges.contains(challenge), "\(id): the intended challenge is outstanding")
            } else {
                #expect(await relay.outstandingChallenges.isEmpty, "\(id): no challenge is outstanding")
            }
            mustBeConsumed = !["refusal_400_malformed", "refusal_413_too_large", "refusal_401_unknown_challenge"].contains(c.name)
        case "session_logout.json":
            switch c.name {
            case "success": await relay.seedSession(token: "FAKE-device", kind: .device, id: fixtureDevice, expiresMs: now + 900_000)
            case "refusal_400_malformed", "refusal_413_too_large", "expired_token_retry": break
            default: Issue.record("\(id): no seed for this scenario"); return
            }
        default:
            if PR3Replay.files.contains(f.fileName) {
                guard try await PR3Replay.seed(f, c, relay) else { Issue.record("\(id): no seed for this scenario"); return }
            } else {
                guard try await Self.seedPR4(f, c, relay, wall, now) else { Issue.record("\(id): no seed for this scenario"); return }
            }
        }

        if c.given["scenario"]?.string == "exact_bytes_already_committed" { try await check(f, c, relay) }   // the first, committing send
        try await check(f, c, relay)
        if mustBeConsumed, let challenge { #expect(!(await relay.outstandingChallenges.contains(challenge)), "\(id): the challenge is consumed") }
        if f.fileName == "session_logout.json", c.name == "success" {
            #expect(await relay.liveSessionTokens.isEmpty, "\(id): the token is gone after logout")
        }
        if f.fileName == "session_login.json", c.name == "success" { #expect(await relay.liveSessionTokens.count == 1) }
        if f.fileName == "session_login.json", c.name == "refusal_429_quota_exceeded" {
            #expect(await relay.liveSessionTokens.count == 8, "\(id): existing tokens are preserved")
        }
        try await Self.checkPR4PostState(f, c, relay)
        if f.fileName == "session_challenge.json", challengeCapCase { #expect(await relay.outstandingChallenges.count == 3, "\(id): nothing is evicted") }
    }

    func check(_ f: Fixtures.File, _ c: Fixtures.Case, _ relay: FakeRelay) async throws {
        let id = caseID(f, c)
        var headers: [String: String] = [:]
        for (k, v) in c.request["headers"]?.object ?? [:] { if let s = v.string { headers[k] = s } }
        let reply = try await relay.send(WireRequest(method: c.request["method"]?.string ?? "", target: try Self.target(c.request), headers: headers,
                                                     body: try Self.body(c.request), clientAddress: "fixture"))
        let text = String(decoding: reply.body, as: UTF8.self)
        #expect(Int64(reply.status) == c.response["status"]?.int, "\(id) status \(reply.status) \(text)")
        // headers: exactly the fixture's response headers (names case-insensitive), nothing extra
        let want = Dictionary(uniqueKeysWithValues: (c.response["headers"]?.object ?? [:]).compactMap { k, v in v.string.map { (k.lowercased(), $0) } })
        #expect(reply.headers == want, "\(id) headers \(reply.headers)")
        // the fixtures are cj bytes, so the relay's bytes must be identical
        let expected = try canonicalJSON(try #require(c.response["json"]?.jsonValue))
        #expect(reply.body == expected, "\(id) body \(text)")
    }

    @Test func replayableFixturesReplayAgainstFakeRelay() async throws {
        var n = 0
        for f in Self.files where FixtureCoverage.replayable.contains(f.fileName) {
            for c in f.cases { try await replay(f, c); n += 1 }
        }
        #expect(n == Self.expectedReplayed)
        #expect(Self.expectedReplayed == FixtureCoverage.expectedCaseCount - FixtureCoverage.pending.keys.reduce(0) { acc, name in
            acc + (Self.files.first { $0.fileName == name }?.cases.count ?? 0) })
    }
}
