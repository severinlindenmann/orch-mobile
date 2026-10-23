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
        /// Signing: build another verdict outcome than asked; add a field the phone does not know.
        public var buildOutcome: String?
        public var extraField = false
        public var buildChannel: String?
        /// Signing: seconds the prepared request lives (default 120).
        public var preparedTTLMs: Int64 = 120_000
        /// Signing: answer `/sign/sign` with this error code instead of signing.
        public var signError: String?
        /// Selective signing: leave `item_hash` out of the built event; add an `option` to a built answer; build with another `gate_gen` than the
        /// item's `f1` shows (a stale value); build with another item's hash.
        public var dropItemHash = false
        public var staleGateGen = false
        /// Selective signing: put `source_sha` on every gate event (a hub that does not follow 8.5), or leave it off a code approval.
        public var sourceOnEveryGate = false
        public var dropSource = false
        public var otherItemHash = false
        /// The hub is unreachable (every request fails at the transport).
        public var down = false
        /// Answer every channel-session request with this error code instead (`no_session`, `channel_revoked`, `cert_expired`, ...).
        public var channelAnswer: String?
        /// Answer `POST /session/channel` with this error code (a revoked channel cannot bind again).
        public var bindAnswer: String?
        /// Answer `POST /channels/{id}/revoke` with this error code instead of revoking.
        public var revokeAnswer: String?
        /// Answer the lists with a body of the wrong shape.
        public var garbledLists = false
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

    /// The data behind `GET /me/workspaces`, `GET /me/needs-you` and the item route (raw rows, as the hub's web API sends them).
    public var workspaceRows: [JSONValue] = []
    public var needsYouRows: [JSONValue] = []
    /// Shared items of a selective workspace the fake can build on (protocol 8.6), by item id: the signed item's members the build reads.
    public struct SharedItem: Sendable {
        public let log: String, head: String, itemHash: String, f1: JSONValue?
    }
    public var sharedItems: [String: SharedItem] = [:]
    public var offlineIDs: [String] = []
    public var unavailableIDs: [String] = []
    /// `workspace_id/item_id` -> the item answer.
    public var itemAnswers: [String: JSONValue] = [:]

    private let lock = NSLock()
    private let root = SoftwareSigner(), op = SoftwareSigner(), rogueRoot = SoftwareSigner(), rogueOp = SoftwareSigner()
    private let wall: any WallClock
    private var sessions: [String: (kind: String, expires: Int64)] = [:]
    private var challenges: [String: (key: SigningPublicKey, expires: Int64, session: String)] = [:]
    private var channels: [String: (key: SigningPublicKey, cert: JSONValue)] = [:]
    private var pushTargets: [String: (env: String, topic: String, token: String)] = [:]
    private var pushKeys: [String: (pub: AgreementPublicKey, issuedMs: Int64)] = [:]
    private var revoked: Set<String> = []
    private var _log: [String] = []
    private var _bearers: [String] = []
    private var channelOfSession: [String: String] = [:]
    private var counter = 0
    private var prepared: [String: (ctx: JSONValue, digest: Data, expires: Int64, channel: String)] = [:]
    /// Events the hub "signed": `(type, log, prepared id)` in order (the proof was verified under the channel key first).
    /// The id of the newest prepared request.
    public private(set) var lastPreparedID: String?
    public private(set) var signedEvents: [(type: String, log: String, preparedID: String)] = []
    /// The workspace and the ticket the fake serves, and the hash of the content under review.
    public let workspaceID = FakeHub.wsPlatform
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
    /// Channel ids revoked at the hub (by the phone's own revoke call).
    public var revokedChannels: Set<String> { lock.withLock { revoked } }
    public var pairingLink: String { "orch://hub-pair/\(Self.authority(of: origin))#h1.\(hubID).\(userID).\(pairingCode)" }

    static func authority(of origin: String) -> String { String(origin.drop(while: { $0 != "/" }).dropFirst(2)) }

    public init(origin: String, wall: any WallClock = SystemWallClock(), pairingCode: String = "ab12-cd34-ef56", relayURL: String? = nil) {
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
            c["hxk_pub"] = .string(B64U.encode(SoftwareKeyAgreer().publicKey.x963)); c["relay_url"] = relayURL.map { JSONValue.string($0) } ?? .null
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
        if lock.withLock({ faults.down }) { throw TransportError.disconnected }
        let (status, body) = lock.withLock { handle(request) }
        return try WireReply(status: status, headers: ["content-type": "application/json"], body: try canonicalJSON(.object(body)))
    }

    /// A channel-session route: the configured fault, else `no_session` without a live channel session.
    private func channelFault(_ token: String?) -> (Int, [String: JSONValue])? {
        if let c = faults.channelAnswer { return err(403, c) }
        guard let token else { return err(403, "no_session") }
        if let ch = channelOfSession[token], revoked.contains(ch) { return err(403, "channel_revoked") }
        return nil
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
            if let c = faults.bindAnswer { return err(403, c) }
            if let cid = body["auth"]?.at("o")?.object?["channel_id"]?.string, revoked.contains(cid) { return err(403, "channel_revoked") }
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
            channelOfSession[token] = cid
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
        case ("GET", "/api/v1/session"):
            guard let t = session("channel") else { return err(403, "no_session") }
            if let cid = channelOfSession[t], revoked.contains(cid) { return err(403, "channel_revoked") }
            return (200, ["user_id": .string(userID), "name": .string(userName), "is_admin": false])
        case ("PUT", _) where r.target.hasPrefix("/api/v1/channels/") && r.target.hasSuffix("/push"):
            return handlePush(r, body: body, session: session("channel"))
        case ("GET", "/api/v1/me/workspaces"), ("GET", "/api/v1/me/needs-you"):
            if let e = channelFault(session("channel")) { return e }
            if faults.garbledLists { return (200, ["workspaces": "nope", "items": 7]) }
            if r.target.hasSuffix("workspaces") { return (200, ["workspaces": .array(workspaceRows)]) }
            return (200, ["items": .array(needsYouRows), "offline": .array(offlineIDs.map { .string($0) }),
                          "unavailable": .array(unavailableIDs.map { .string($0) })])
        case ("GET", _) where r.target.hasPrefix("/api/v1/workspaces/") && r.target.contains("/items/"):
            if let e = channelFault(session("channel")) { return e }
            let parts = r.target.dropFirst("/api/v1/workspaces/".count).components(separatedBy: "/items/")
            guard parts.count == 2, let a = itemAnswers[parts[0] + "/" + parts[1]] else { return err(404, "unknown_item") }
            return (200, a.object ?? [:])
        case ("POST", _) where r.target.hasPrefix("/api/v1/channels/") && r.target.hasSuffix("/revoke"):
            let id = String(r.target.dropFirst("/api/v1/channels/".count).dropLast("/revoke".count))
            if session("pairing") != nil { return err(403, "forbidden_role") }       // a pairing session may not revoke
            if let e = channelFault(session("channel")) { return e }
            if let c = faults.revokeAnswer { return err(503, c) }
            guard let t = session("channel"), channelOfSession[t] == id else { return err(403, "other_user") }
            revoked.insert(id)
            return (200, ["ok": true])
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
        if let item = action["item"] { return prepareSelective(body, item: item, ws: ws, cid: cid, token: token, now: now) }
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
            if e["gate"] == "code", builtType == "gate.approved" {
                e["source_sha"] = .array([.object(["repo": "orch-core", "ref": "main", "sha": "9f2c1a7be4d05c3a8e6f1b2c4d5e6f708192a3b4"])])
            }
        case "verdict.given":
            e["outcome"] = faults.buildOutcome.map { .string($0) } ?? action["outcome"] ?? "pass"; e["hash"] = action["hash"] ?? "sha256:x"; e["gate_gen"] = 1; e["policy_hash"] = .string(Self.policyHash)
            e["source_sha"] = .array([.object(["repo": "orch-core", "ref": "main", "sha": "9f2c1a7be4d05c3a8e6f1b2c4d5e6f708192a3b4"]),
                                      .object(["repo": "orch-mobile", "ref": "main", "sha": "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567"])])
            if let t = action["text"] { e["text"] = t }
        case "ticket.moved": e["to"] = "backlog"; e["from"] = "open"; e["reason"] = "moved"
        default: break
        }
        if faults.extraField { e["sections"] = "smuggled" }
        let ctx: JSONValue = .object(["contract": 1, "suite": 2, "workspace_id": .string(faults.buildWorkspace ?? ws), "log": .string(log), "event": .object(e)])
        guard var digest = try? HubSign.digest(ofContext: ctx) else { return err(500, "unavailable") }
        if faults.wrongDigest { digest = Data(SHA256Fake.hash(digest)) }
        counter += 1
        let id = "prep-\(counter)"
        let entry = (ctx: ctx, digest: digest, expires: now + faults.preparedTTLMs, channel: cid)
        prepared[id] = entry; lastPreparedID = id
        return (200, reply(id, entry))
    }

    /// protocol 8.6 `build_selective`: the event core from one shared item and its `f1`, no option, `item_hash` in the event.
    private func prepareSelective(_ body: [String: JSONValue], item: JSONValue, ws: String, cid: String, token: String, now: Int64) -> (Int, [String: JSONValue]) {
        guard ws == Self.wsShared, let ch = channels[cid], let action = body["action"]?.object, let type = action["type"]?.string,
              let log = action["log"]?.string, let id = item.string else { return err(400, "malformed") }
        guard let it = sharedItems[id], it.log == log else { return err(404, "unknown_item") }
        guard let f1 = it.f1?.object else { return err(409, "unavailable") }
        guard ["question.answered", "gate.approved", "gate.changes_requested", "verdict.given"].contains(type) else { return err(400, "not_custodial") }
        var e: [String: JSONValue] = ["v": 2, "id": .string("01J9ZP0000000000000000EVT\(counter % 10)"), "type": .string(type),
                                      "actor": .object(["kind": "person", "id": .string("u_" + userID), "via": .string(cid)]),
                                      "based_on": .string(it.head), "roster_v": f1["roster_v"] ?? 0, "hash_v": 1, "auth": "hub",
                                      "channel": .string(cid), "channel_factor": "se-unlocked", "hub_id": .string(hubID),
                                      "snapshot_version": 3, "channel_cert": ch.cert, "uk_cert": ukCert()]
        if !faults.dropItemHash { e["item_hash"] = .string(faults.otherItemHash ? Self.contentHash : it.itemHash) }
        if type == "question.answered" {
            if action["option"] != nil { return err(400, "malformed") }
            guard let q = action["question"]?.string, let entry = f1["questions"]?.object?[q]?.object else { return err(404, "unknown_item") }
            guard entry["hash"] == action["hash"] else { return err(409, "event_changed") }
            e["question"] = .string(q); e["hash"] = entry["hash"]; e["text"] = action["text"]
        } else {
            let gate = type == "verdict.given" ? "verify" : (action["gate"]?.string ?? "")
            guard let g = f1["gates"]?.object?[gate]?.object else { return err(404, "unknown_item") }
            guard g["hash"] == action["hash"] else { return err(409, "event_changed") }
            e["hash"] = g["hash"]; e["gate_gen"] = faults.staleGateGen ? .int((g["gen"]?.int ?? 0) + 1) : g["gen"]; e["policy_hash"] = g["policy_hash"]
            if type == "verdict.given" { e["outcome"] = action["outcome"] } else { e["gate"] = .string(gate) }
            if let t = action["text"] { e["text"] = t }
            if (type == "verdict.given" || (type == "gate.approved" && gate == "code") || faults.sourceOnEveryGate) && !faults.dropSource { e["source_sha"] = g["source_sha"] }
        }
        let ctx: JSONValue = .object(["contract": 1, "suite": 2, "workspace_id": .string(ws), "log": .string(log), "event": .object(e)])
        guard let digest = try? HubSign.digest(ofContext: ctx) else { return err(500, "unavailable") }
        counter += 1
        let pid = "prep-\(counter)"
        let entry = (ctx: ctx, digest: digest, expires: now + faults.preparedTTLMs, channel: cid)
        prepared[pid] = entry; lastPreparedID = pid
        return (200, reply(pid, entry))
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

    // MARK: push (protocol 6.4 `PUT /channels/{id}/push`, 10.8.2 sealing)

    private func handlePush(_ r: WireRequest, body: [String: JSONValue], session token: String?) -> (Int, [String: JSONValue]) {
        guard let token, let sessionChannel = channelOfSession[token] else { return err(403, "no_session") }
        let parts = r.target.split(separator: "/").map(String.init)
        guard parts.count == 5, parts[3] == sessionChannel else { return err(403, "other_user") }
        guard !revoked.contains(sessionChannel), let ch = channels[sessionChannel] else { return err(403, "channel_revoked") }
        guard let env = body["env"]?.string, let topic = body["topic"]?.string, let tok = body["token"]?.string, body.keys.contains("push_key"),
              Set(body.keys) == ["env", "topic", "token", "push_key"], B64U.decode(tok) != nil else { return err(400, "malformed") }
        let held = pushKeys[sessionChannel]
        var newKey: (AgreementPublicKey, Int64)?
        if let pk = body["push_key"], !pk.isNull {
            guard let po = pk.at("o")?.object, let sig = pk.at("sig")?.string.flatMap({ B64U.decode($0, length: 64) }),
                  Signature.verify(ch.key, signature: sig, label: Label.sigHubChannelPush, message: (try? canonicalJSON(.object(po))) ?? Data())
            else { return err(400, "bad_signature") }
            guard po["kind"] == "hub.channel_push", po["hub_id"]?.string == hubID, po["channel_id"]?.string == sessionChannel,
                  let issued = po["issued_ms"]?.int, let pubText = po["push_pub"]?.string, let pubBytes = B64U.decode(pubText, length: 65),
                  let pub = try? AgreementPublicKey(x963: pubBytes), po["dev"] == true else { return err(400, "malformed") }
            guard abs(issued - wall.nowMs) <= 120_000 else { return err(400, "stale_timestamp") }
            guard pubBytes != ch.key.x963 else { return err(400, "malformed") }
            if let held, issued <= held.issuedMs { return err(400, "replay") }
            newKey = (pub, issued)
        } else if held == nil { return err(400, "malformed") }
        if let newKey { pushKeys[sessionChannel] = (newKey.0, newKey.1) }
        pushTargets[sessionChannel] = (env, topic, tok)
        return (200, ["registered": true])
    }

    /// The push target the phone registered for a channel, if any.
    public func pushTarget(channelID: String) -> (env: String, topic: String, token: String)? { lock.withLock { pushTargets[channelID] } }
    /// The `issued_ms` of the push key the hub holds for a channel.
    public func heldPushIssuedMs(channelID: String) -> Int64? { lock.withLock { pushKeys[channelID]?.issuedMs } }
    public func heldPushPub(channelID: String) -> AgreementPublicKey? { lock.withLock { pushKeys[channelID]?.pub } }

    /// Revokes a channel at the hub (its web API then answers `channel_revoked`).
    public func revoke(channelID: String) { lock.withLock { _ = revoked.insert(channelID) } }

    /// The hub seals a hint to the channel's PUSH key (10.8.2) and returns the relay's `outer` as the JSON string APNs would carry, plus the
    /// sealed message `c` for the mailbox. Nil when the hub holds no push key (it then sends nothing).
    public func sealHint(channelID: String, type: String, ref: String?, tsMs: Int64? = nil, messageID: String? = nil)
        -> (id: String, c: String, outer: String)? {
        lock.withLock {
            guard let held = pushKeys[channelID], let ch = ID16(hex: channelID), let hub = ID16(hex: hubID) else { return nil }
            let id = ID16(hex: messageID ?? SystemEntropy().id16().hex)!
            let pt = (try? canonicalJSON(["v": 2, "hv": 0, "kind": "hub.push", "type": .string(type), "ts_ms": .int(tsMs ?? wall.nowMs),
                                          "ref": ref.map { JSONValue.string($0) } ?? .null]))!
            let sealed = B64U.encode(try! Sealing.sealHubPush(to: held.pub, channel: ch, message: id, hub: hub, plaintext: pt))
            let outer = try! canonicalJSON(["v": 2, "hub": .string(hubID), "ch": .string(channelID), "id": .string(id.hex), "c": .string(sealed)])
            return (id.hex, sealed, String(decoding: outer, as: UTF8.self))
        }
    }

    /// The held, signed channel certificate (what a phone puts in `Orch-Channel-Cert`).
    public func certificate(channelID: String) -> JSONValue? { lock.withLock { channels[channelID]?.cert } }

    /// The Authorization headers the hub saw (tests assert no token leaks into a request to another place).
    public var seenAuthorizations: [String] { lock.withLock { _bearers } }
}

private extension JSONValue {
    func at(_ k: String) -> JSONValue? { object?[k] }
}

private enum SHA256Fake { static func hash(_ d: Data) -> [UInt8] { Array(SHA256.hash(data: d + Data("other".utf8))) } }
// MARK: sample data for the phone's home (B2)

extension FakeHub {
    /// The hub's item id of a question is its `qid` (core `questionID`); the phone checks it.
    public static let q1Item = (try? F1Question.questionID(question: "Q1", ticketUID: "01J9ZP0000000000000000TKT1", workspace: ID16(hex: wsPlatform)!)) ?? ""
    public static let q2Item = (try? F1Question.questionID(question: "Q2", ticketUID: "01J9ZP0000000000000000TKT1", workspace: ID16(hex: wsPlatform)!)) ?? ""

    public static func questionItem(_ item: String, number: String, text: String, key: String, options: JSONValue, spec: JSONValue) -> JSONValue {
        let log = "01J9ZP0000000000000000TKT1"
        let hash = (try? F1Question.questionHash(qid: item, ticketUID: log, text: .string(text), options: options, spec: spec)) ?? ""
        return .object(["workspace_id": .string(wsPlatform), "mode": "full", "item_id": .string(item), "kind": "question", "type": "question", "key": .string(key),
                        "title": .string(text), "deadline": .null, "signable": true, "log": .string(log), "hash": .string(hash),
                        "content": .object(["text": .string(text), "question": .string(number), "options": options, "spec": spec])])
    }

    public static let wsPlatform = String(repeating: "a1", count: 16)
    public static let wsBilling = String(repeating: "b2", count: 16)
    public static let wsShared = String(repeating: "c3", count: 16)

    public static func workspaceRow(id: String, name: String, mode: String, role: String, online: Bool) -> JSONValue {
        .object(["workspace_id": .string(id), "name": .string(name), "mode": .string(mode), "role": .string(role), "online": .bool(online),
                 "hub_reads": .string(mode == "full" ? "everything" : "shared items and summaries"),
                 "can_start": .bool(mode == "full" && role != "read")])
    }

    public static func needsRow(ws: String, mode: String = "full", item: String, kind: String, title: String, signable: Bool = false,
                                summaryOnly: Bool = false, key: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["workspace_id": .string(ws), "mode": .string(mode), "item_id": .string(item), "kind": .string(kind),
                                      "type": .string(kind), "key": .string(key ?? "T-" + item), "title": .string(title), "deadline": .null,
                                      "signable": .bool(signable)]
        if mode == "selective" { o["item_version"] = 1; o["summary_only"] = .bool(summaryOnly) }
        return .object(o)
    }

    /// Three workspaces (full and online, full and paused, selective) with a few needs-you rows and one item answer each.
    public func seedHome() {
        workspaceRows = [Self.workspaceRow(id: Self.wsPlatform, name: "Platform", mode: "full", role: "edit", online: true),
                         Self.workspaceRow(id: Self.wsBilling, name: "Billing", mode: "full", role: "read", online: false),
                         Self.workspaceRow(id: Self.wsShared, name: "Acme (shared)", mode: "selective", role: "owner", online: true)]
        needsYouRows = [Self.needsRow(ws: Self.wsPlatform, item: Self.q1Item, kind: "question", title: "Which region should the pilot run in?", signable: true, key: "T-q1"),
                        Self.needsRow(ws: Self.wsPlatform, item: "g1", kind: "gate", title: "Approve the plan for the export feature", signable: true),
                        Self.needsRow(ws: Self.wsShared, mode: "selective", item: "s1", kind: "ticket", title: "Review the launch checklist"),
                        Self.needsRow(ws: Self.wsShared, mode: "selective", item: "s2", kind: "needs_you", title: "A decision is waiting in the workspace",
                                      summaryOnly: true),
                        Self.needsRow(ws: Self.wsPlatform, item: Self.q2Item, kind: "question", title: "Which rollout plan should we use?", signable: true, key: "T-q2")]
        offlineIDs = [Self.wsBilling]
        itemAnswers = [
            Self.wsPlatform + "/" + Self.q1Item: Self.questionItem(Self.q1Item, number: "Q1", text: "Which region should the pilot run in?", key: "T-q1",
                                                                  options: [["key": "eu_west", "label": "EU West"], ["key": "us_east", "label": "US East"]],
                                                                  spec: ["kind": "choice"]),
            // answered on the Mac only: `recommended` is a hash-bound part the phone does not show yet
            Self.wsPlatform + "/" + Self.q2Item: Self.questionItem(Self.q2Item, number: "Q2", text: "Which rollout plan should we use?", key: "T-q2",
                                                                  options: [["key": "big_bang", "label": "Big bang"], ["key": "phased", "label": "Phased"]],
                                                                  spec: ["kind": "choice", "recommended": "phased"]),
            Self.wsPlatform + "/g1": .object(["workspace_id": .string(Self.wsPlatform), "mode": "full", "item_id": "g1", "kind": "gate",
                                              "type": "gate", "key": "T-g1", "title": "Approve the plan for the export feature", "deadline": .null,
                                              "signable": true, "log": "01J9ZP0000000000000000TKT1", "hash": .string(Self.contentHash),
                                              "content": .object(["gate": "plan", "gate_gen": 2])]),
            Self.wsShared + "/s1": .object(["workspace_id": .string(Self.wsShared), "mode": "selective", "item_id": "s1", "kind": "ticket",
                                            "type": "ticket", "key": "T-s1", "title": "Review the launch checklist", "deadline": .null,
                                            "item_version": 1, "summary_only": false, "signable": false,
                                            "content": .object(["title": "Review the launch checklist", "body": "Shared with the hub by the workspace owner."]),
                                            "item_hash": "sha256:00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"]),
        ]
    }
}

// MARK: shared items with `f1` (B5; protocol 8.6, 10.2b)

extension FakeHub {
    public static let sharedQuestionItem = String(repeating: "d4", count: 16)
    public static let sharedGateItem = String(repeating: "e5", count: 16)
    public static let sharedCodeItem = String(repeating: "f6", count: 16)
    public static let sharedNoF1Item = String(repeating: "a7", count: 16)
    public static let sharedItemHash = "sha256:" + String(repeating: "5a", count: 32)
    public static let sharedQuestionHash = "sha256:" + String(repeating: "7b", count: 32)
    public static let sharedGateHash = "sha256:" + String(repeating: "9c", count: 32)
    static let sharedHead = "sha256:" + String(repeating: "1d", count: 32)
    static let sharedSource: JSONValue = .array([.object(["repo": "orch-core", "ref": "refs/heads/main", "sha": "9f2c1a7be4d05c3a8e6f1b2c4d5e6f708192a3b4"])])

    /// Adds four shared items to the selective workspace: a question and a plan gate with an `f1` that names them, a code gate (with its source
    /// list) and a ticket the host shared WITHOUT `f1` (visible, never signable). Call after `seedHome()`.
    public func seedSelective() {
        func answer(_ item: String, kind: String, key: String, title: String, content: JSONValue, f1: JSONValue?, hash: String) -> JSONValue {
            var o: [String: JSONValue] = ["workspace_id": .string(Self.wsShared), "mode": "selective", "item_id": .string(item), "kind": .string(kind),
                                          "type": .string(kind), "key": .string(key), "title": .string(title), "deadline": .null, "item_version": 1,
                                          "summary_only": false, "signable": false, "content": content, "item_hash": .string(hash),
                                          "chain": .object(["log": .string(ticketLog), "seq": 7, "head": .string(Self.sharedHead)])]
            if let f1 { o["f1"] = f1 }
            return .object(o)
        }
        func f1(gates: [String: JSONValue] = [:], questions: [String: JSONValue] = [:]) -> JSONValue {
            .object(["roster_v": 4, "gates": .object(gates), "questions": .object(questions)])
        }
        let policy = "sha256:" + String(repeating: "3e", count: 32)
        let plan = f1(gates: ["plan": .object(["gen": 2, "hash": .string(Self.sharedGateHash), "policy_hash": .string(policy)])])
        let code = f1(gates: ["code": .object(["gen": 1, "hash": .string(Self.sharedGateHash), "policy_hash": .string(policy), "source_sha": Self.sharedSource])])
        let question = f1(questions: ["Q2": .object(["hash": .string(Self.sharedQuestionHash)])])
        let items: [(String, String, String, String, JSONValue, JSONValue?)] = [
            (Self.sharedQuestionItem, "question", "T-q2", "Which region should the pilot run in?",
             .object(["key": "T-q2", "type": "feature", "id": "Q2", "title": "Export", "text": "Which region should the pilot run in?", "deadline": .null]), question),
            (Self.sharedGateItem, "ticket", "T-g2", "Approve the plan for the export feature",
             .object(["key": "T-g2", "type": "feature", "title": "Export", "status": "plan", "labels": .array([]), "deadline": .null]), plan),
            (Self.sharedCodeItem, "ticket", "T-c2", "Approve the code for the export feature",
             .object(["key": "T-c2", "type": "feature", "title": "Export", "status": "review", "labels": .array([]), "deadline": .null]), code),
            (Self.sharedNoF1Item, "ticket", "T-n2", "Shared without decision values",
             .object(["key": "T-n2", "type": "feature", "title": "Export", "status": "plan", "labels": .array([]), "deadline": .null]), nil),
        ]
        for (item, kind, key, title, content, f) in items {
            needsYouRows.append(Self.needsRow(ws: Self.wsShared, mode: "selective", item: item, kind: kind, title: title, key: key))
            itemAnswers[Self.wsShared + "/" + item] = answer(item, kind: kind, key: key, title: title, content: content, f1: f, hash: Self.sharedItemHash)
            sharedItems[item] = SharedItem(log: ticketLog, head: Self.sharedHead, itemHash: Self.sharedItemHash, f1: f)
        }
    }
}
