import CryptoKit
import Foundation
import Testing
import OrchClient
@testable import OrchFakeHost
@testable import OrchProtocol
import OrchTestVectors

/// PR4 fixture files (accounts, pairing mailboxes, the cert_pending queues): their seeds and post-state checks. The fixture world
/// is workspace 705d… (card_get.json's real card, `WSK` = wsk_a) of person 5c05…, whose primary device is 6a29…; the phone is
/// 4177…. The card and the person's account go through the relay's own publish paths; queue records, sessions, holder generations
/// and budget fill levels are package seeds (state that history would build).
extension FixtureReplayTests {
    static let ws = ID16(hex: "705d40abbb8c1c90354a1acaa94c935c")!
    static let otherWS = ID16(hex: "282193f85af5b8d07610fbb3a8448857")!
    static let person = ID16(hex: "5c0574d08d9b869beaa7b630cc83893d")!
    static let otherPerson = ID16(hex: "42f83168aabd846982483297b14e7301")!
    static let primaryDevice = ID16(hex: "6a29d184e6be89bf89cb4864ecd6a507")!
    static let otherDevice = ID16(hex: "146f7f5f8b0000000000000000000001")!
    static let rid = ID16(hex: "1995f17e92ddbfe28475cc5ad02be4c9")!
    /// Parsed once: the vector file is large.
    nonisolated(unsafe) static let personKey: SoftwareSigner = try! personSigner(person)
    nonisolated(unsafe) static let wskA: SigningPublicKey = try! vectorSigningKeys()["wsk_a.sig"]!
    static let pr4Files: Set<String> = ["accounts.json", "pair_device_post.json", "pair_host_post.json", "pair_poll.json", "cert_challenge.json",
                                        "cert_rejection.json", "cert_request_get.json", "cert_requests_poll.json", "cert_requests_post.json"]

    static func json(_ fileName: String, _ caseName: String, _ path: (Fixtures.JSON) -> Fixtures.JSON?) throws -> JSONValue {
        let c = try #require(try Self.file(fileName).cases.first { $0.name == caseName })
        return try #require(path(Fixtures.JSON.object(["request": c.request, "response": c.response]))?.jsonValue)
    }
    static var request: JSONValue { get throws { try json("cert_requests_post.json", "success") { $0["request"]?["json"]?["request"] } } }
    static var challenge: JSONValue { get throws { try json("cert_challenge.json", "success") { $0["request"]?["json"]?["challenge"] } } }
    static var rejection: JSONValue { get throws { try json("cert_rejection.json", "success") { $0["request"]?["json"]?["rejection"] } } }
    static var signedView: JSONValue { get throws { try json("cert_request_get.json", "signed") { $0["response"]?["json"] } } }

    /// Stored state is trusted by the relay: a different object stands for "other bytes" without needing a valid signature.
    static func altered(_ v: JSONValue, _ key: String, _ value: JSONValue) throws -> JSONValue {
        var m = try #require(v.object), o = try #require(m["o"]?.object)
        o[key] = value; m["o"] = .object(o)
        return .object(m)
    }

    static func record(_ state: CertQueue.State, request: JSONValue? = nil, challenge: JSONValue? = nil, cert: JSONValue? = nil,
                       rejection: JSONValue? = nil, id: ID16 = rid, workspace: ID16 = ws, person p: ID16 = person) throws -> CertQueue.Record {
        CertQueue.Record(request: try request ?? Self.request, requestID: id, workspace: workspace, person: p, primary: primaryDevice,
                         expiresMs: 1_790_000_600_000, state: state, challenge: challenge, cert: cert, rejection: rejection)
    }

    static func pr4Limits(_ f: Fixtures.File, _ c: Fixtures.Case, _ limits: inout RelayLimits) {
        guard pr4Files.contains(f.fileName) else { return }
        limits.retryAfterSeconds = 20
        let poll = f.fileName == "pair_poll.json" || f.fileName == "cert_requests_poll.json"
        switch c.name {
        case "refusal_429_rate_limited":
            if f.fileName == "pair_poll.json" { limits.pairPollsPerMinutePerAddress = 0 }
            else if f.fileName == "pair_host_post.json" { limits.pairPostsPerMinuteGlobal = 0 }
            else { limits.pairPostsPerMinutePerWorkspace = 0 }
        case "refusal_429_quota_exceeded":
            if poll { limits.maxConcurrentPollsPerPrincipal = 0 } else { limits.maxQueuedPairBytesPerWorkspace = 0 }
        case "refusal_503_overloaded":
            if poll { limits.maxConcurrentPollsGlobal = 0 } else { limits.maxQueuedBytesGlobal = 0 }
        default: break
        }
    }

    /// The person's account and the real card of the workspace, published through the relay's own checks.
    static func publishWorld(_ relay: FakeRelay) async throws {
        await relay.registerOwner(personKey.publicKey)
        try await relay.publishCard(try json("card_get.json", "success") { $0["response"]?["json"]?["card"] })
    }

    /// Returns false for an unmapped case.
    static func seedPR4(_ f: Fixtures.File, _ c: Fixtures.Case, _ relay: FakeRelay, _ wall: MutableWall, _ now: Int64) async throws -> Bool {
        let name = c.name
        let expiresAt: Int64 = 1_790_000_600_000
        switch f.fileName {
        case "accounts.json":
            let challenge = c.request["json"]?["challenge"]?.string.flatMap { B64U.decode($0) }
            let pk = personKey.publicKey
            switch name {
            case "success", "refusal_400_malformed", "refusal_400_wrong_suite", "refusal_401_bad_signature", "refusal_413_too_large": break
            case "refusal_400_cert_invalid":
                // the same certificate, judged at a time before its created_ms minus the skew window
                let created = try #require(c.request["json"]?["device_cert"]?["o"]?["created_ms"]?.int)
                wall.set(created - 2 * Suite2.skewMs)
            case "refusal_401_expired", "refusal_401_unknown_challenge", "refusal_403_not_eligible": break
            case "refusal_409_account_exists": await relay.seedAccount(person: person, key: pk, digest: Data(repeating: 1, count: 32))
            case "exact_retry": await relay.seedAccount(person: person, key: pk, digest: Data(SHA256.hash(data: try body(c.request))))
            default: return false
            }
            if name != "refusal_403_not_eligible" { await relay.createInvite("FAKE-single-use-invite") }
            if name != "refusal_401_unknown_challenge", let challenge {
                await relay.seedChallenge(challenge, expiresMs: name == "refusal_401_expired" ? wall.nowMs - 1 : wall.nowMs + 60_000)
            }
            return true

        case "pair_device_post.json":
            if name != "refusal_401_unknown_workspace" { try await publishWorld(relay) }
            return ["success", "refusal_400_malformed", "refusal_400_too_large", "refusal_400_wrong_suite", "refusal_401_unknown_workspace",
                    "refusal_429_quota_exceeded", "refusal_429_rate_limited", "refusal_503_overloaded"].contains(name)

        case "pair_host_post.json":
            if name != "refusal_401_unknown_workspace" { try await publishWorld(relay) }
            await relay.seedHolder(ws, generation: 1)
            await relay.seedSession(token: "FAKE-workspace", kind: .workspace, id: name == "refusal_403_not_eligible" ? otherWS : ws, expiresMs: now + 900_000)
            return ["success", "refusal_400_malformed", "refusal_400_too_large", "refusal_400_wrong_suite", "refusal_401_unauthenticated",
                    "refusal_401_unknown_workspace", "refusal_403_not_eligible", "refusal_409_fenced", "refusal_429_quota_exceeded",
                    "refusal_429_rate_limited", "refusal_503_overloaded"].contains(name)

        case "pair_poll.json":
            let chunk = try #require(try file("pair_poll.json").cases[0].response["json"]?["chunks"]?.array?.first)
            let env = try #require(chunk["envelope"]?.string.flatMap { B64U.decode($0) })
            let parts = (try #require(c.request["path"]?.string)).split(separator: "/").map(String.init)
            await relay.seedPairResponse(ws: try #require(ID16(hex: parts[2])), offer: try #require(ID16(hex: parts[4])), rid: try #require(ID16(hex: parts[5])), envelope: env)
            return ["success", "refusal_400_malformed", "refusal_429_quota_exceeded", "refusal_429_rate_limited", "refusal_503_overloaded",
                    "after_first_chunk"].contains(name)

        case "cert_requests_post.json":
            try await publishWorld(relay)
            await relay.seedHolder(ws, generation: 1)
            await relay.seedSession(token: "FAKE-workspace", kind: .workspace, id: name == "refusal_409_other_workspace" ? otherWS : ws, expiresMs: now + 900_000)
            if name != "refusal_403_not_for_this_device" { await relay.seedDevice(primaryDevice, person: person) }
            switch name {
            case "success", "refusal_400_malformed", "refusal_400_wrong_suite", "refusal_401_unauthenticated", "refusal_409_fenced", "refusal_413_too_large",
                 "refusal_403_not_for_this_device": break
            case "refusal_401_bad_signature": await relay.seedWorkspaceKey(ws, wsk: SoftwareSigner().publicKey, owner: person, replacingCard: true)
            case "refusal_403_not_eligible": await relay.seedWorkspaceKey(ws, wsk: wskA, owner: otherPerson, replacingCard: true)
            case "refusal_403_other_person": await relay.forgetAccount(person)
            case "refusal_409_other_workspace": await relay.seedWorkspaceKey(otherWS, wsk: wskA, owner: person)
            case "refusal_409_replayed": await relay.seedCertRecord(try record(.open, request: try altered(try request, "created_ms", .int(now - 1))))
            case "refusal_409_request_open": await relay.seedCertRecord(try record(.open, id: ID16(hex: "f2600ef4ea0405124cc2b37a234cb186")!))
            case "refusal_410_expired": wall.set(expiresAt)
            case "refusal_429_quota_exceeded":
                for i in 0..<CertQueue.maxOpenPerPerson {
                    var b = [UInt8](repeating: 0x5a, count: 16); b[15] = UInt8(i)
                    await relay.seedCertRecord(try record(.open, id: ID16(bytes: Data(b))!, workspace: ID16(bytes: Data(b.reversed()))!))
                }
            default: return false
            }
            return true

        case "cert_requests_poll.json", "cert_challenge.json", "cert_rejection.json":
            try await publishWorld(relay)
            var session = primaryDevice
            switch name {
            case "refusal_400_cert_expired": await relay.seedDevice(primaryDevice, person: person, expiresMs: now - 1)
            case "refusal_403_not_eligible": await relay.seedDevice(primaryDevice, person: otherPerson)
            case "refusal_403_not_for_this_device":
                await relay.seedDevice(otherDevice, person: person); session = otherDevice
                await relay.seedDevice(primaryDevice, person: person)
            case "refusal_403_revoked": await relay.seedDevice(primaryDevice, person: person); await relay.seedRevoked(primaryDevice)
            default: await relay.seedDevice(primaryDevice, person: person)
            }
            await relay.seedSession(token: "FAKE-primary", kind: .device, id: session, expiresMs: now + 900_000)
            if f.fileName == "cert_requests_poll.json" {
                await relay.seedCertRecord(try record(.open))
                return ["success", "refusal_400_cert_expired", "refusal_400_malformed", "refusal_401_unauthenticated", "refusal_403_not_eligible",
                        "refusal_403_revoked", "refusal_429_quota_exceeded", "refusal_503_overloaded"].contains(name)
            }
            let isChallenge = f.fileName == "cert_challenge.json"
            let stored = isChallenge ? try challenge : try rejection
            let otherStored = try altered(stored, isChallenge ? "primary_nonce" : "request_id",
                                          .string(isChallenge ? B64U.encode(Data(repeating: 7, count: 32)) : "f8210bb5a1d9895b130721f032ad3ab4"))
            switch name {
            case "success", "refusal_400_cert_expired", "refusal_400_malformed", "refusal_400_wrong_suite", "refusal_401_unauthenticated",
                 "refusal_403_not_eligible", "refusal_403_not_for_this_device", "refusal_403_revoked", "refusal_413_too_large":
                await relay.seedCertRecord(try record(.open))
            case "refusal_401_bad_signature":
                await relay.seedCertRecord(try record(.open))
                await relay.seedAccount(person: person, key: SoftwareSigner().publicKey)          // the trusted account key is another one
            case "refusal_403_other_person":
                await relay.seedCertRecord(try record(.open)); await relay.forgetAccount(person)  // no account for the person
            case "refusal_404_not_found": break
            case "refusal_409_already_signed":
                let v = try signedView
                await relay.seedCertRecord(try record(.signed, challenge: isChallenge ? otherStored : v.object?["challenge"], cert: v.object?["cert"]))
            case "refusal_409_other_workspace":
                await relay.seedCertRecord(try record(.open, request: try altered(try request, "workspace_id", .string(otherWS.hex)), workspace: otherWS))
            case "refusal_409_replayed":
                await relay.seedCertRecord(isChallenge ? try record(.challenged, challenge: otherStored) : try record(.rejected, rejection: otherStored))
            case "refusal_410_expired":
                await relay.seedCertRecord(try record(.open)); wall.set(expiresAt)
            case "resigned_identical", "exact_retry":
                await relay.seedCertRecord(isChallenge ? try record(.challenged, challenge: stored) : try record(.rejected, rejection: stored))
            default: return false
            }
            return true

        case "cert_request_get.json":
            try await publishWorld(relay)
            await relay.seedSession(token: "FAKE-workspace", kind: .workspace, id: name == "refusal_403_not_eligible" ? otherWS : ws, expiresMs: now + 900_000)
            let view = try #require(c.response["json"]?.jsonValue?.object)
            func field(_ k: String) -> JSONValue? { view[k].flatMap { $0.isNull ? nil : $0 } }
            switch name {
            case "success": await relay.seedCertRecord(try record(.challenged, challenge: field("challenge")))
            case "open", "refusal_400_malformed", "refusal_401_unauthenticated", "refusal_403_not_eligible": await relay.seedCertRecord(try record(.open))
            case "signed": await relay.seedCertRecord(try record(.signed, challenge: field("challenge"), cert: field("cert")))
            case "rejected": await relay.seedCertRecord(try record(.rejected, rejection: field("rejection")))
            case "expired": await relay.seedCertRecord(try record(.open)); wall.set(expiresAt)
            case "refusal_404_not_found": break
            default: return false
            }
            return true
        default: return false
        }
    }

    /// What a PR4 case leaves behind at the relay.
    static func checkPR4PostState(_ f: Fixtures.File, _ c: Fixtures.Case, _ relay: FakeRelay) async throws {
        let id = caseID(f, c), ok = c.response["status"]?.int.map { $0 < 300 } ?? false
        switch f.fileName {
        case "accounts.json":
            let pk = personKey.publicKey
            if c.name == "success" { #expect(await relay.accountKey(person) == pk, "\(id): the account exists") }
            if !ok, c.name != "refusal_409_account_exists" { #expect(await relay.accountKey(person) == nil, "\(id): no account") }
        case "cert_requests_post.json":
            if c.name == "success" { #expect(await relay.certRecord(rid)?.state == .open, "\(id): the request is queued") }
            if c.name == "refusal_401_bad_signature" || c.name == "refusal_409_fenced" { #expect(await relay.certRecord(rid) == nil, "\(id)") }
        case "cert_challenge.json":
            let r = await relay.certRecord(rid), challenge = try Self.challenge
            if c.name == "success" { #expect(r?.state == .challenged && r?.challenge == challenge, "\(id)") }
            if c.name == "resigned_identical" { #expect(r?.challenge == challenge, "\(id): the stored challenge is unchanged") }
            if c.name == "refusal_401_bad_signature" { #expect(r?.state == .open, "\(id): unchanged") }
        case "cert_rejection.json":
            let r = await relay.certRecord(rid), rejection = try Self.rejection
            if c.name == "success" { #expect(r?.state == .rejected && r?.rejection == rejection, "\(id)") }
            if c.name == "resigned_identical" { #expect(r?.rejection == rejection, "\(id): the stored rejection is unchanged") }
            if c.name == "refusal_409_already_signed" { #expect(r?.state == .signed, "\(id)") }
        default: break
        }
    }
}
