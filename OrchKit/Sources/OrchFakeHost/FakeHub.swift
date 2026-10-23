import Foundation
import CryptoKit
import OrchClient
import OrchProtocol

/// An in-process orch hub for the phone's pairing (orch-hub protocol 5, 6.3, 6.4), speaking the web API routes the phone calls:
/// `GET /api/v1/hub/card`, `POST/DELETE /session`, `POST /channels/register/begin|complete`, `POST /session/channel`. It signs with its own
/// FAKE keys, verifies what the phone signs (registration proof, `hub.channel_auth`, the session reference), and records every request so
/// a test can prove what was sent where. Test and Simulator use only; the real routes are orch-hub's (H1).
public final class FakeHub: RequestSender, @unchecked Sendable {
    /// Faults a test can switch on to play a hostile or broken hub.
    public struct Faults: Sendable {
        /// The factor the hub puts in the certificate (the phone must insist on `se-unlocked`).
        public var certFactor = "se-unlocked"
        /// The origin the signed `hub.api_origin` names (nil: the real origin).
        public var signedOrigin: String?
        /// Serve a card of another hub (another root).
        public var rogueHubCard = false
        /// The challenge names another user / a far-away expiry.
        public var challengeUser: String?
        public var challengeExpiryMs: Int64?
        /// The bound certificate is issued for another key.
        public var certForOtherKey = false
        /// Answer the bind with a session longer than 12 h.
        public var longSession = false
        /// Signing: the hub's `shown` block lies (the phone must render from `ctx` only).
        public var lyingShown = false
        /// Signing: build another event type than the one asked for (e.g. `ticket.moved`), or one outside the allow-list.
        public var buildType: String?
        /// Signing: the digest is of another event than `ctx` carries.
        public var wrongDigest = false
        /// Signing: build the event for another workspace / another channel than the one asked for.
        public var buildWorkspace: String?
        public var buildChannel: String?
        /// Signing: seconds the prepared request lives (default 120).
        public var preparedTTLMs: Int64 = 120_000
        /// Signing: answer `/sign/sign` with this error code instead of signing.
        public var signError: String?
        public init() {}
    }

    public let origin: String
    public let userID: String
    public let userName = "alice"
    public let password = "correct horse battery staple"
    public let totp = "123456"
    public private(set) var pairingCode: String
    public var faults = Faults()
    public private(set) var hubID = ""
    public let cardJSON: JSONValue

    private let lock = NSLock()
    private let root = SoftwareSigner(), op = SoftwareSigner(), rogueRoot = SoftwareSigner(), rogueOp = SoftwareSigner()
    private let wall: any WallClock
    private var sessions: [String: (kind: String, expires: Int64)] = [:]
    private var challenges: [String: (key: SigningPublicKey, expires: Int64, session: String)] = [:]
    private var channels: [String: (key: SigningPublicKey, cert: JSONValue)] = [:]
    private var _log: [String] = []
    private var _bearers: [String] = []
    private var counter = 0
    private var prepared: [String: (ctx: JSONValue, digest: Data, expires: Int64, channel: String)] = [:]
    /// Events the hub "signed": `(type, log, prepared id)` in order (the proof was verified under the channel key first).
    /// The id of the newest prepared request.
    public private(set) var lastPreparedID: String?
    public private(set) var signedEvents: [(type: String, log: String, preparedID: String)] = []
    /// The workspace and the ticket the fake serves, and the hash of the content under review.
    public let workspaceID = SystemEntropy().id16().hex
    public let ticketLog = "01J9ZP0000000000000000TKT1"
    public static let contentHash = "sha256:3d3f5e93357cf4b89511c728d2d7995ebc233f435574ef9b95de0259f3247987"
    public static let policyHash = "sha256:508506355d0c369c4bfc20c05048e111cf0dd1747def9bbd4076d3d9a46e55e1"
    private let opCertID: String
    private var apiOriginJSON: JSONValue = .null
    private var card: JSONValue = .null
    private var rogueCard: JSONValue = .null

    /// Every request as `METHOD /path`, in order.
    public var log: [String] { lock.withLock { _log } }
    /// Channel ids the hub issued certificates for.
    public var registeredChannels: [String] { lock.withLock { Array(channels.keys) } }
    public var pairingLink: String { "orch://hub-pair/\(Self.authority(of: origin))#h1.\(hubID).\(userID).\(pairingCode)" }

    static func authority(of origin: String) -> String { String(origin.drop(while: { $0 != "/" }).dropFirst(2)) }

    public init(origin: String, wall: any WallClock = SystemWallClock(), pairingCode: String = "ab12-cd34-ef56") {
        self.origin = origin; self.wall = wall; self.pairingCode = pairingCode
        userID = SystemEntropy().id16().hex
        opCertID = SystemEntropy().id16().hex
        hubID = HubIdentifiers.hubID(root: root.publicKey)
        let now = wall.nowMs
        @Sendable func sign(_ o: [String: JSONValue], _ s: SoftwareSigner, _ label: String) -> JSONValue {
            .object(["o": .object(o), "sig": .string(B64U.encode(try! Signature.sign(s, label: label, message: try! canonicalJSON(.object(o)))))])
        }
        @Sendable func header(_ kind: String) -> [String: JSONValue] { ["v": 2, "suite": 2, "kind": .string(kind), "hv": 0, "dev": true] }
        func makeCard(root: SoftwareSigner, op: SoftwareSigner, certID: String) -> JSONValue {
            var oc = header("hub.op_cert")
            oc["hub_id"] = .string(HubIdentifiers.hubID(root: root.publicKey)); oc["cert_id"] = .string(certID); oc["op_seq"] = 1
            oc["hk_op_pub"] = .string(B64U.encode(op.publicKey.x963)); oc["issued_ms"] = .int(now - 1000); oc["expires_ms"] = .int(now + 86_400_000 * 30)
            var c = header("hub.card")
            c["hub_id"] = .string(HubIdentifiers.hubID(root: root.publicKey)); c["hk_root_pub"] = .string(B64U.encode(root.publicKey.x963))
            c["hxk_pub"] = .string(B64U.encode(SoftwareKeyAgreer().publicKey.x963)); c["relay_url"] = .null
            c["tls_spki_sha256"] = .string(B64U.encode(Data(count: 32))); c["card_seq"] = 1; c["issued_ms"] = .int(now - 1000)
            let signedOp = sign(oc, root, Label.sigHubOpCert)
            let signed = sign(c, op, Label.sigHubCard)
            return .object(["o": signed.at("o")!, "op_cert": signedOp, "sig": signed.at("sig")!])
        }
        card = makeCard(root: root, op: op, certID: opCertID)
        rogueCard = makeCard(root: rogueRoot, op: rogueOp, certID: SystemEntropy().id16().hex)
        cardJSON = card
        self.signOriginObject = { [op, opCertID, hubID] origin in
            var o = header("hub.api_origin")
            o["hub_id"] = .string(hubID); o["op_cert_id"] = .string(opCertID); o["origin"] = .string(origin); o["issued_ms"] = .int(now - 1000)
            return sign(o, op, Label.sigHubAPIOrigin)
        }
        self.signCert = { [op, opCertID, hubID] user, key, factor in
            var o = header("hub.channel_cert")
            o["hub_id"] = .string(hubID); o["op_cert_id"] = .string(opCertID); o["channel_id"] = .string(HubIdentifiers.channelID(key: key))
            o["user_id"] = .string(user); o["key_pub"] = .string(B64U.encode(key.x963)); o["factor"] = .string(factor)
            o["issued_ms"] = .int(now - 1000); o["expires_ms"] = .int(now + 86_400_000 * 30)
            return sign(o, op, Label.sigHubChannelCert)
        }
    }

    private let signOriginObject: @Sendable (String) -> JSONValue
    private let signCert: @Sendable (String, SigningPublicKey, String) -> JSONValue

    // MARK: RequestSender

    public func send(_ request: WireRequest) async throws -> WireReply {
        let (status, body) = lock.withLock { handle(request) }
        return try WireReply(status: status, headers: ["content-type": "application/json"], body: try canonicalJSON(.object(body)))
    }

    private func err(_ status: Int, _ code: String) -> (Int, [String: JSONValue]) { (status, ["error": .string(code)]) }

    private func handle(_ r: WireRequest) -> (Int, [String: JSONValue]) {
        _log.append("\(r.method) \(r.target)")
        if let a = r.header("authorization") { _bearers.append(a) }
        let body = (try? StrictJSON.parse(r.body, maxBytes: 1 << 20))?.object ?? [:]
        let bearer = r.header("authorization").flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        let now = wall.nowMs
        func session(_ kind: String) -> String? { bearer.flatMap { t in sessions[t].flatMap { $0.kind == kind && $0.expires > now ? t : nil } } }
        if r.method != "GET" && r.header("x-orch-csrf") != "1" { return err(403, "not_allowed") }
        switch (r.method, r.target) {
        case ("GET", "/api/v1/hub/card"):
            let origin = faults.signedOrigin ?? self.origin
            return (200, ["card": faults.rogueHubCard ? rogueCard : card, "api_origin": signOriginObject(origin)])
        case ("POST", "/api/v1/session"):
            guard body["user_id"]?.string == userID, body["password"]?.string == password, body["totp"]?.string == totp, body["client"] == "app"
            else { return err(401, "bad_credentials") }
            counter += 1
            let token = "FAKE-HUB-PAIRING-\(counter)"
            sessions[token] = ("pairing", now + 900_000)
            return (200, ["user_id": .string(userID), "expires_ms": .int(now + 900_000), "token": .string(token)])
        case ("DELETE", "/api/v1/session"):
            if let t = bearer { sessions[t] = nil }
            return (200, ["ok": true])
        case ("POST", "/api/v1/channels/register/begin"):
            guard let t = session("pairing") else { return err(403, "no_session") }
            guard body["kind"] == "phone", let k = body["key_pub"]?.string, let kb = B64U.decode(k, length: 65), let key = try? SigningPublicKey(x963: kb)
            else { return err(400, "malformed") }
            guard body["pairing_code"]?.string == pairingCode else { return err(400, "bad_pairing_code") }
            counter += 1
            let nonce = B64U.encode(Data((0..<32).map { UInt8(($0 &+ counter) & 0xFF) }))
            let expires = faults.challengeExpiryMs ?? now + 120_000
            challenges[nonce] = (key, expires, t)
            let ch: [String: JSONValue] = ["v": 2, "suite": 2, "kind": "hub.channel_register", "hv": 0, "hub_id": .string(hubID),
                                           "user_id": .string(faults.challengeUser ?? userID), "channel_kind": "phone", "key_pub": .string(k),
                                           "attestation": "pairing-code", "nonce": .string(nonce), "expires_ms": .int(expires), "dev": true]
            return (200, ["challenge_id": .string(nonce), "challenge": .object(ch)])
        case ("POST", "/api/v1/channels/register/complete"):
            guard session("pairing") != nil else { return err(403, "no_session") }
            guard let id = body["challenge_id"]?.string, let c = challenges.removeValue(forKey: id), let signed = body["signed"],
                  let so = signed.at("o")?.object, let sigText = signed.at("sig")?.string, let sig = B64U.decode(sigText, length: 64),
                  Signature.verify(c.key, signature: sig, label: Label.sigHubChannelRegister, message: (try? canonicalJSON(.object(so))) ?? Data()),
                  so["key_pub"]?.string == B64U.encode(c.key.x963), so["nonce"]?.string == id else { return err(400, "challenge_invalid") }
            let key = faults.certForOtherKey ? SoftwareSigner().publicKey : c.key
            let cert = signCert(userID, key, faults.certFactor)
            channels[HubIdentifiers.channelID(key: c.key)] = (c.key, cert)
            return (200, ["channel_cert": cert])
        case ("POST", "/api/v1/session/channel"):
            guard let t = session("pairing") else { return err(403, "no_session") }
            guard let auth = body["auth"], let ao = auth.at("o")?.object, let cid = ao["channel_id"]?.string, let ch = channels[cid],
                  let sig = auth.at("sig")?.string.flatMap({ B64U.decode($0, length: 64) }),
                  Signature.verify(ch.key, signature: sig, label: Label.sigHubChannelAuth, message: (try? canonicalJSON(.object(ao))) ?? Data())
            else { return err(401, "unknown_channel") }
            guard ao["session_ref"]?.string == (try? HubIdentifiers.sessionRef(token: t)), ao["user_id"]?.string == userID,
                  ao["hub_id"]?.string == hubID, ao["dev"] == true else { return err(400, "challenge_invalid") }
            sessions[t] = nil
            counter += 1
            let token = "FAKE-HUB-CHANNEL-\(counter)"
            let life: Int64 = faults.longSession ? 48 * 3_600_000 : 12 * 3_600_000
            sessions[token] = ("channel", now + life)
            return (200, ["token": .string(token), "user_id": .string(userID), "channel_id": .string(cid), "expires_ms": .int(now + life),
                          "channel_cert": ch.cert, "card": card])
        case ("POST", "/api/v1/sign/prepare"):
            guard let t = session("channel") else { return err(401, "no_session") }
            return prepare(body, token: t, now: now)
        case ("POST", "/api/v1/sign/sign"):
            guard session("channel") != nil else { return err(401, "no_session") }
            return sign(body, now: now)
        case ("GET", _) where r.target.hasPrefix("/api/v1/sign/prepared/"):
            guard session("channel") != nil else { return err(401, "no_session") }
            guard let p = prepared[String(r.target.dropFirst("/api/v1/sign/prepared/".count))] else { return err(404, "unknown_prepared") }
            if p.expires <= now { return err(410, "prepared_expired") }
            return (200, reply(String(r.target.dropFirst("/api/v1/sign/prepared/".count)), p))
        default:
            return err(404, "unknown_op")
        }
    }

    // MARK: custodial signing (protocol 8.4)

    private func reply(_ id: String, _ p: (ctx: JSONValue, digest: Data, expires: Int64, channel: String)) -> [String: JSONValue] {
        var shown: JSONValue = .object(["sentence": "Approve the plan gate"])
        if faults.lyingShown { shown = .object(["sentence": "Mark the ticket as read", "facts": .array([])]) }
        return ["prepared_id": .string(id), "ctx": p.ctx, "digest": .string(Hex.encode(p.digest)), "expires_ms": .int(p.expires), "shown": shown]
    }

    private func prepare(_ body: [String: JSONValue], token: String, now: Int64) -> (Int, [String: JSONValue]) {
        guard let ws = body["workspace_id"]?.string, let cid = body["channel_id"]?.string, let action = body["action"]?.object,
              let type = action["type"]?.string, let log = action["log"]?.string, let ch = channels[cid] else { return err(400, "malformed") }
        guard ws == workspaceID else { return err(403, "unknown_workspace") }
        let builtType = faults.buildType ?? type
        var e: [String: JSONValue] = ["v": 2, "id": .string(SystemEntropy().id16().hex), "type": .string(builtType),
                                      "actor": .object(["kind": "person", "id": .string("u_" + userID), "via": .string(faults.buildChannel ?? cid)]),
                                      "based_on": .string(Self.contentHash), "roster_v": 4, "hash_v": 1, "auth": "hub",
                                      "channel": .string(faults.buildChannel ?? cid), "channel_factor": "se-unlocked", "hub_id": .string(hubID),
                                      "snapshot_version": 3, "channel_cert": ch.cert, "uk_cert": ukCert()]
        e["id"] = .string("01J9ZP0000000000000000EVT\(counter % 10)")
        switch builtType {
        case "question.answered":
            e["question"] = action["question"] ?? "Q1"; e["hash"] = action["hash"] ?? "sha256:x"
            if let o = action["option"] { e["option"] = o }
            if let t = action["text"] { e["text"] = t }
        case "gate.approved", "gate.changes_requested":
            e["gate"] = action["gate"] ?? "plan"; e["hash"] = action["hash"] ?? "sha256:x"; e["gate_gen"] = 2; e["policy_hash"] = .string(Self.policyHash)
            if let t = action["text"] { e["text"] = t }
            if e["gate"] == "code" {
                e["source_sha"] = .array([.object(["repo": "orch-core", "ref": "main", "sha": "9f2c1a7be4d05c3a8e6f1b2c4d5e6f708192a3b4"])])
            }
        case "verdict.given":
            e["outcome"] = action["outcome"] ?? "pass"; e["hash"] = action["hash"] ?? "sha256:x"; e["gate_gen"] = 1; e["policy_hash"] = .string(Self.policyHash)
            e["source_sha"] = .array([.object(["repo": "orch-core", "ref": "main", "sha": "9f2c1a7be4d05c3a8e6f1b2c4d5e6f708192a3b4"]),
                                      .object(["repo": "orch-mobile", "ref": "main", "sha": "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567"])])
            if let t = action["text"] { e["text"] = t }
        case "ticket.moved": e["to"] = "backlog"; e["from"] = "open"; e["reason"] = "moved"
        default: break
        }
        let ctx: JSONValue = .object(["contract": 1, "suite": 2, "workspace_id": .string(faults.buildWorkspace ?? ws), "log": .string(log), "event": .object(e)])
        guard var digest = try? HubSign.digest(ofContext: ctx) else { return err(500, "unavailable") }
        if faults.wrongDigest { digest = Data(SHA256Fake.hash(digest)) }
        counter += 1
        let id = "prep-\(counter)"
        let entry = (ctx: ctx, digest: digest, expires: now + faults.preparedTTLMs, channel: cid)
        prepared[id] = entry; lastPreparedID = id
        return (200, reply(id, entry))
    }

    private func sign(_ body: [String: JSONValue], now: Int64) -> (Int, [String: JSONValue]) {
        if let code = faults.signError { return err(409, code) }
        guard let id = body["prepared_id"]?.string, let cid = body["channel_id"]?.string, let proofText = body["channel_proof"]?.string,
              let p = prepared.removeValue(forKey: id) else { return err(404, "unknown_prepared") }
        guard p.expires > now else { return err(410, "prepared_expired") }
        guard let ch = channels[cid], cid == p.channel, let sig = B64U.decode(proofText, length: 64),
              Signature.verify(ch.key, signature: sig, label: Label.sigHubChannelProof, message: p.digest) else { return err(400, "bad_channel_proof") }
        let ev = p.ctx.at("event")?.object ?? [:]
        let type = ev["type"]?.string ?? "", log = p.ctx.at("log")?.string ?? ""
        signedEvents.append((type, log, id))
        return (200, ["ok": true, "event_id": ev["id"] ?? "", "type": .string(type), "workspace_id": p.ctx.at("workspace_id") ?? "", "log": .string(log)])
    }

    private func ukCert() -> JSONValue {
        .object(["o": .object(["v": 2, "suite": 2, "kind": "hub.uk_cert", "hv": 0, "dev": true, "hub_id": .string(hubID), "user_id": .string(userID),
                               "op_cert_id": .string(opCertID)]), "sig": "fake"])
    }

    /// The Authorization headers the hub saw (tests assert no token leaks into a request to another place).
    public var seenAuthorizations: [String] { lock.withLock { _bearers } }
}

private extension JSONValue {
    func at(_ k: String) -> JSONValue? { object?[k] }
}

private enum SHA256Fake { static func hash(_ d: Data) -> [UInt8] { Array(SHA256.hash(data: d + Data("other".utf8))) } }
