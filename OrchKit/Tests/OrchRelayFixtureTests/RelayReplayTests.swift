import CryptoKit
import Foundation
import Testing
import OrchClient
@testable import OrchFakeHost
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
private let bridgeOtherDevice = ID16(hex: "ed2a9b65180497dd0022753339a5a378")!
private let fixtureWorkspace = ID16(hex: "705d40abbb8c1c90354a1acaa94c935c")!
private let fixtureRid = ID16(hex: "fde154f24ef24b8eccff1cb87c930438")!

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
    let root = try StrictJSON.parse(Vectors.data, maxBytes: .max, maxDepth: 64)
    for (name, k) in root.object?["suites"]?.object?["2"]?.object?["keys"]?.object ?? [:] where name.hasSuffix(".sig") {
        guard let seed = k.object?["seed"]?.string.flatMap({ Hex.decode($0) }) else { continue }
        let signer = try SoftwareSigner(testScalar: scalar(fromSeed: seed))
        if Identifiers.personID(signer.publicKey) == person { return signer }
    }
    throw Refusal.otherPerson
}

@Suite struct FixtureReplayTests {
    static let files = FixtureSchemaTests.files
    /// 4 session_challenge + 10 session_login + 4 session_logout cases (PR2), the 121 cases of the twelve PR3 directory and
    /// membership files (121 since G2b added wk_commit_changed), the 103 cases of the nine PR4 files, and
    /// 15 bridge_device_post + 9 bridge_device_poll + 14 bridge_host_post cases (PR5; the two Q11 cases of the d3816ea copy are pending).
    static let expectedReplayed = 18 + 121 + 103 + 38

    /// The instant of every fixture case that has one (all 386a6cb cases use 1790000000000). The three condition-only cases
    /// (victim_person_without_member, other_workspace_person_refused x2) carry no `given.now_ms`; they replay at that same instant.
    static let conditionOnlyNowMs: Int64 = 1_790_000_000_000

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
            now = Self.conditionOnlyNowMs
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
        // Bridge budgets (P3-D17): the fixtures show the "full" state of each with Retry-After 20.
        if f.fileName.hasPrefix("bridge_") {
            limits.retryAfterSeconds = 20
            switch (f.fileName, c.name) {
            case ("bridge_device_post.json", "refusal_429_quota_exceeded"): limits.maxLiveMailboxesPerDevice = 0
            case ("bridge_device_poll.json", "refusal_429_quota_exceeded"): limits.maxLongPollsPerDevice = 0
            case ("bridge_device_poll.json", "refusal_503_overloaded"): limits.maxLongPolls = 0
            case ("bridge_host_post.json", "refusal_429_quota_exceeded"): limits.maxResponseBytesPerDevice = 0
            case ("bridge_host_post.json", "refusal_429_rate_limited"): limits.hostPostsPerSecond = 0
            case (_, "refusal_503_overloaded"): limits.maxQueuedBodyBytes = 0
            default: break
            }
        }
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
        case "bridge_device_post.json", "bridge_device_poll.json", "bridge_host_post.json":
            guard try await seedBridge(f, c, relay: relay, wall: wall, now: now) else { Issue.record("\(id): no seed for this scenario"); return }
        default:
            if PR3Replay.files.contains(f.fileName) {
                guard try await PR3Replay.seed(f, c, relay) else { Issue.record("\(id): no seed for this scenario"); return }
            } else {
                guard try await Self.seedPR4(f, c, relay, wall, now) else { Issue.record("\(id): no seed for this scenario"); return }
            }
        }

        let sent = try Self.body(c.request)
        if c.given["scenario"]?.string == "exact_bytes_already_committed" { try await check(f, c, relay, body: sent) }   // the first, committing send
        try await check(f, c, relay, body: sent)
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
        try await checkBridgePostState(f, c, relay)
    }

    /// The fixture device's real certificate (device_put.json), published through the relay's own verifying path; `expired` signs
    /// the same certificate with an expiry just before `now` (stored while it was valid).
    func publishFixtureCertificate(_ relay: FakeRelay, wall: MutableWall, now: Int64, expired: Bool = false) async throws {
        let cert = try #require(try Self.file("device_put.json").cases[0].request["json"]?["cert"]?.jsonValue)
        let certO = try #require(cert.object?["o"]?.object)
        let signer = try personSigner(try #require(certO["person_id"]?.string.flatMap { ID16(hex: $0) }))
        await relay.registerOwner(signer.publicKey)
        guard expired else { try await relay.publishCertificate(cert); return }
        var o = certO; o["expires_ms"] = .int(now - 1)
        wall.set(1_789_913_600_001)
        try await relay.publishCertificate(try SignedObject.sign(o, kind: .deviceCert, signer: signer).json)
        wall.set(now)
    }

    /// Bridge preconditions (section 19.3): sessions, membership and epoch, the rid's replay record and the holder generation.
    /// Membership is a package seed (the bridge fixtures are not about lists); the device certificate is real.
    func seedBridge(_ f: Fixtures.File, _ c: Fixtures.Case, relay: FakeRelay, wall: MutableWall, now: Int64) async throws -> Bool {
        let body = try Self.body(c.request)
        let digest = Data(SHA256.hash(data: body))
        func record(digest: Data, requeues: Int = 0, lastRequeueMs: Int64? = nil, copies: [RelayRidRecord.Copy] = [],
                    chunks: [UInt64: RelayRidRecord.Chunk] = [:]) -> RelayRidRecord {
            RelayRidRecord(digest: digest, reqEpoch: 1, firstMs: now - 1_000, requeues: requeues, lastRequeueMs: lastRequeueMs ?? now - 1_000,
                           keepUntilMs: now + 899_000, copies: copies, chunks: chunks)
        }
        let other = Data(repeating: 0xEE, count: 32)
        var members: Set<ID16> = [fixtureDevice], epoch: UInt32 = 1
        switch f.fileName {
        case "bridge_device_post.json", "bridge_device_poll.json":
            try await publishFixtureCertificate(relay, wall: wall, now: now, expired: c.name == "refusal_400_cert_expired")
            await relay.seedSession(token: "FAKE-device", kind: .device, id: c.name == "refusal_403_not_for_this_device" ? bridgeOtherDevice : fixtureDevice,
                                    expiresMs: now + 900_000)
            switch c.name {
            case "success" where f.fileName == "bridge_device_poll.json", "after_first_chunk":
                // the host's answer chunk is stored for the rid (the poll fixture shows it)
                let chunk = try #require(try Self.file("bridge_device_poll.json").cases[0].response["json"]?["chunks"]?.array?.first?["envelope"]?.string
                    .flatMap { B64U.decode($0) })
                await relay.seedRid(workspace: fixtureWorkspace, device: fixtureDevice, rid: fixtureRid, record: record(digest: other, copies: [.init(n: 1, expiresMs: now + 59_000)],
                    chunks: [0: .init(digest: Data(SHA256.hash(data: chunk)), flags: 1, expiresMs: now + 59_000, envelope: chunk)]))
            case "success", "refusal_400_cert_expired", "refusal_400_malformed", "refusal_400_too_large", "refusal_400_wrong_suite",
                 "refusal_401_unauthenticated", "refusal_403_not_for_this_device", "refusal_429_quota_exceeded", "refusal_503_overloaded": break
            case "refusal_403_not_eligible": members = [bridgeOtherDevice]
            case "refusal_403_revoked": await relay.seedRevoked(fixtureDevice)
            case "refusal_409_retry_exhausted":
                // eight requeues used, every copy acknowledged by the holder: no undelivered copy is left
                let copies = (1...9).map { RelayRidRecord.Copy(n: UInt64($0), expiresMs: now + 1_000) }
                await relay.seedRid(workspace: fixtureWorkspace, device: fixtureDevice, rid: fixtureRid, record: record(digest: digest, requeues: 8, copies: copies))
                await relay.seedHolder(fixtureWorkspace, generation: 1); await relay.seedHolderCursor(workspace: fixtureWorkspace, cursor: 9)
            case "refusal_409_rid_conflict":
                await relay.seedRid(workspace: fixtureWorkspace, device: fixtureDevice, rid: fixtureRid, record: record(digest: other, copies: [.init(n: 1, expiresMs: now + 1_000)]))
            case "refusal_409_stale_epoch": epoch = 2
            case "refusal_429_rate_limited":
                // acknowledged, no live copy, 1001 ms left of the ten-second requeue interval: Retry-After 2
                await relay.seedRid(workspace: fixtureWorkspace, device: fixtureDevice, rid: fixtureRid,
                                    record: record(digest: digest, lastRequeueMs: now - 8_999, copies: [.init(n: 1, expiresMs: now + 51_001)]))
                await relay.seedHolder(fixtureWorkspace, generation: 1); await relay.seedHolderCursor(workspace: fixtureWorkspace, cursor: 1)
            default: return false
            }
        default:   // bridge_host_post.json
            await relay.seedSession(token: "FAKE-workspace", kind: .workspace, id: fixtureWorkspace, expiresMs: now + 900_000)
            await relay.seedHolder(fixtureWorkspace, generation: 1)
            var known: RelayRidRecord? = record(digest: other, copies: [.init(n: 1, expiresMs: now + 59_000)])
            switch c.name {
            case "success", "refusal_400_malformed", "refusal_400_too_large", "refusal_400_wrong_suite", "refusal_401_unauthenticated",
                 "refusal_409_fenced", "refusal_429_quota_exceeded", "refusal_429_rate_limited", "refusal_503_overloaded": break
            case "refusal_403_not_eligible": members = [bridgeOtherDevice]
            case "refusal_403_revoked": await relay.seedRevoked(fixtureDevice)
            case "refusal_409_chunk_conflict": known?.chunks[0] = .init(digest: other, flags: 1, expiresMs: now + 59_000)
            case "refusal_409_stale_epoch": epoch = 2          // a LAST chunk (not LAST | REFUSAL) at the request's old epoch
            case "refusal_410_expired": known = nil            // the rid is unknown
            default: return false
            }
            if let known { await relay.seedRid(workspace: fixtureWorkspace, device: fixtureDevice, rid: fixtureRid, record: known) }
        }
        await relay.seedMembership(workspace: fixtureWorkspace, devices: members, epoch: epoch)
        return true
    }

    func check(_ f: Fixtures.File, _ c: Fixtures.Case, _ relay: FakeRelay, body sent: Data? = nil) async throws {
        let id = caseID(f, c)
        var headers: [String: String] = [:]
        for (k, v) in c.request["headers"]?.object ?? [:] { if let s = v.string { headers[k] = s } }
        let reply = try await relay.send(WireRequest(method: c.request["method"]?.string ?? "", target: try Self.target(c.request), headers: headers,
                                                     body: try sent ?? Self.body(c.request), clientAddress: "fixture"))
        let text = String(decoding: reply.body, as: UTF8.self)
        #expect(Int64(reply.status) == c.response["status"]?.int, "\(id) status \(reply.status) \(text)")
        // headers: exactly the fixture's response headers (names case-insensitive), nothing extra
        let want = Dictionary(uniqueKeysWithValues: (c.response["headers"]?.object ?? [:]).compactMap { k, v in v.string.map { (k.lowercased(), $0) } })
        #expect(reply.headers == want, "\(id) headers \(reply.headers)")
        // the fixtures are cj bytes, so the relay's bytes must be identical
        let expected = try canonicalJSON(try #require(c.response["json"]?.jsonValue))
        #expect(reply.body == expected, "\(id) body \(text)")
    }

    /// Post-state of the bridge cases: a refusal stores nothing; an accepted request is one queued copy; an accepted chunk is stored.
    func checkBridgePostState(_ f: Fixtures.File, _ c: Fixtures.Case, _ relay: FakeRelay) async throws {
        let id = caseID(f, c)
        let rec = await relay.ridRecord(workspace: fixtureWorkspace, device: fixtureDevice, rid: fixtureRid)
        switch (f.fileName, c.name) {
        case ("bridge_device_post.json", "success"):
            #expect(rec?.copies.count == 1 && rec?.requeues == 0 && rec?.reqEpoch == 1, "\(id): one queued copy")
        case ("bridge_device_post.json", "refusal_409_retry_exhausted"), ("bridge_device_post.json", "refusal_429_rate_limited"):
            #expect(rec?.copies.count == (c.name == "refusal_429_rate_limited" ? 1 : 9) && rec?.requeues == (c.name == "refusal_429_rate_limited" ? 0 : 8), "\(id): nothing requeued")
        case ("bridge_device_post.json", _):
            #expect(c.name == "refusal_409_rid_conflict" ? rec?.copies.count == 1 : rec == nil, "\(id): nothing queued")
        case ("bridge_host_post.json", "success"):
            #expect(rec?.chunks[0]?.envelope == (try Self.body(c.request)), "\(id): the chunk is stored")
        case ("bridge_host_post.json", "refusal_409_chunk_conflict"):
            #expect(rec?.chunks[0]?.digest == Data(repeating: 0xEE, count: 32), "\(id): the stored chunk is kept")
        case ("bridge_host_post.json", _):
            #expect(rec?.chunks.isEmpty ?? true, "\(id): nothing stored")
        default: break
        }
    }

    @Test func replayableFixturesReplayAgainstFakeRelay() async throws {
        var n = 0
        for f in Self.files where FixtureCoverage.replayable.contains(f.fileName) {
            for c in f.cases where FixtureCoverage.caseOverrides[caseID(f, c)] == nil { try await replay(f, c); n += 1 }
        }
        #expect(n == Self.expectedReplayed)
        // Split up: the one-expression form exceeds Xcode 16.4's type-checker time limit.
        var pendingCases = 0
        for name in FixtureCoverage.pending.keys {
            pendingCases += Self.files.first(where: { $0.fileName == name })?.cases.count ?? 0
        }
        let expected: Int = FixtureCoverage.expectedCaseCount - FixtureCoverage.caseOverrides.count - pendingCases
        #expect(Self.expectedReplayed == expected)
    }
}
