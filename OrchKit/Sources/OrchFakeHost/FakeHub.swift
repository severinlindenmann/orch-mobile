import Foundation
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
        /// The hub is unreachable (every request fails at the transport).
        public var down = false
        /// Answer every channel-session request with this error code instead (`no_session`, `channel_revoked`, `cert_expired`, ...).
        public var channelAnswer: String?
        /// Answer `POST /session/channel` with this error code (a revoked channel cannot bind again).
        public var bindAnswer: String?
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
        return token == nil ? err(403, "no_session") : nil
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
        default:
            return err(404, "unknown_op")
        }
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

// MARK: sample data for the phone's home (B2)

extension FakeHub {
    public static let wsPlatform = String(repeating: "a1", count: 16)
    public static let wsBilling = String(repeating: "b2", count: 16)
    public static let wsShared = String(repeating: "c3", count: 16)

    public static func workspaceRow(id: String, name: String, mode: String, role: String, online: Bool) -> JSONValue {
        .object(["workspace_id": .string(id), "name": .string(name), "mode": .string(mode), "role": .string(role), "online": .bool(online),
                 "hub_reads": .string(mode == "full" ? "everything" : "shared items and summaries"),
                 "can_start": .bool(mode == "full" && role != "read")])
    }

    public static func needsRow(ws: String, mode: String = "full", item: String, kind: String, title: String, signable: Bool = false,
                                summaryOnly: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["workspace_id": .string(ws), "mode": .string(mode), "item_id": .string(item), "kind": .string(kind),
                                      "type": .string(kind), "key": .string("T-" + item), "title": .string(title), "deadline": .null,
                                      "signable": .bool(signable)]
        if mode == "selective" { o["item_version"] = 1; o["summary_only"] = .bool(summaryOnly) }
        return .object(o)
    }

    /// Three workspaces (full and online, full and paused, selective) with a few needs-you rows and one item answer each.
    public func seedHome() {
        workspaceRows = [Self.workspaceRow(id: Self.wsPlatform, name: "Platform", mode: "full", role: "edit", online: true),
                         Self.workspaceRow(id: Self.wsBilling, name: "Billing", mode: "full", role: "read", online: false),
                         Self.workspaceRow(id: Self.wsShared, name: "Acme (shared)", mode: "selective", role: "owner", online: true)]
        needsYouRows = [Self.needsRow(ws: Self.wsPlatform, item: "q1", kind: "question", title: "Which region should the pilot run in?", signable: true),
                        Self.needsRow(ws: Self.wsPlatform, item: "g1", kind: "gate", title: "Approve the plan for the export feature", signable: true),
                        Self.needsRow(ws: Self.wsShared, mode: "selective", item: "s1", kind: "ticket", title: "Review the launch checklist"),
                        Self.needsRow(ws: Self.wsShared, mode: "selective", item: "s2", kind: "needs_you", title: "A decision is waiting in the workspace",
                                      summaryOnly: true)]
        offlineIDs = [Self.wsBilling]
        itemAnswers = [
            Self.wsPlatform + "/q1": .object(["workspace_id": .string(Self.wsPlatform), "mode": "full", "item_id": "q1", "kind": "question",
                                              "type": "question", "key": "T-q1", "title": "Which region should the pilot run in?", "deadline": .null,
                                              "signable": true, "content": .object(["text": "Which region should the pilot run in?",
                                                                                      "options": .array(["eu-west", "us-east"])])]),
            Self.wsShared + "/s1": .object(["workspace_id": .string(Self.wsShared), "mode": "selective", "item_id": "s1", "kind": "ticket",
                                            "type": "ticket", "key": "T-s1", "title": "Review the launch checklist", "deadline": .null,
                                            "item_version": 1, "summary_only": false, "signable": false,
                                            "content": .object(["title": "Review the launch checklist", "body": "Shared with the hub by the workspace owner."]),
                                            "item_hash": "sha256:00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"]),
        ]
    }
}
