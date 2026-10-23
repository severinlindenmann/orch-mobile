import Foundation
import OrchProtocol

/// Why a hub call failed (never carries a token, a password or a reply body).
public enum HubAPIError: Error, Equatable, Sendable {
    /// The request did not complete (offline, timeout, reset, a reply too large or malformed at the wire level).
    case network
    /// The hub answered `{"error": code}` (orch-hub protocol 14, web API table).
    case refused(code: String, status: Int)
    /// A reply that does not have the shape the contract gives it (including a redirect or a non-JSON body).
    case badReply
}

/// A hub session bearer. Redacted from every textual rendering.
public struct HubBearer: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    package let token: String
    package init(_ token: String) { self.token = token }
    public var description: String { "HubBearer(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The hub web API (`/api/v1`, orch-hub protocol 6.4) over a `RequestSender` that is bound to ONE origin. Every request goes to
/// `origin`; there is no call that takes another one. The coordinator builds this client for the origin it verified at pairing
/// (the signed `hub.api_origin` equal to the link's), and every later client is built from the stored record, never from a later
/// link, push or answer (design B1).
public struct HubAPI: Sendable {
    public let origin: String
    let sender: any RequestSender
    static let clientAddress = "0.0.0.0"

    /// `sender.origin` must be exactly `origin`.
    public init(origin: String, sender: any RequestSender) throws {
        guard sender.origin == origin else { throw HubAPIError.badReply }
        self.origin = origin; self.sender = sender
    }

    func call(_ method: String, _ path: String, bearer: HubBearer? = nil, body: JSONValue? = nil) async throws -> [String: JSONValue] {
        var headers = ["accept": "application/json"]
        if method != "GET" { headers["x-orch-csrf"] = "1" }
        if let bearer { headers["authorization"] = "Bearer " + bearer.token }
        var data = Data()
        if let body { headers["content-type"] = "application/json"; data = try canonicalJSON(body) }
        let reply: WireReply
        do {
            reply = try await sender.send(try WireRequest(method: method, target: "/api/v1" + path, headers: headers, body: data,
                                                            clientAddress: Self.clientAddress))
        } catch is CancellationError { throw CancellationError() } catch { throw HubAPIError.network }
        guard let json = try? StrictJSON.parse(reply.body, maxBytes: 1 << 20), let obj = json.object else {
            throw reply.status == 200 ? HubAPIError.badReply : HubAPIError.refused(code: "malformed", status: reply.status)
        }
        guard reply.status == 200 else {
            guard let code = obj["error"]?.string, code.utf8.count <= 64, code.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F })
            else { throw HubAPIError.badReply }
            throw HubAPIError.refused(code: code, status: reply.status)
        }
        return obj
    }

    // MARK: calls

    /// `GET /hub/card` (no session): the held, signed card and the signed `hub.api_origin`. Unverified here.
    public func hubCard() async throws -> (card: JSONValue, apiOrigin: JSONValue) {
        let o = try await call("GET", "/hub/card")
        guard o.hasKeys(["card", "api_origin"]), let c = o["card"], let a = o["api_origin"] else { throw HubAPIError.badReply }
        return (c, a)
    }

    public struct SignedIn: Sendable, Equatable { public let bearer: HubBearer; public let userID: String; public let expiresMs: Int64 }

    /// `POST /session` with `client: "app"`: password + TOTP give a 15-minute PAIRING session (bearer, memory only).
    public func signIn(userID: String, password: String, totp: String) async throws -> SignedIn {
        let o = try await call("POST", "/session", body: ["user_id": .string(userID), "password": .string(password), "totp": .string(totp),
                                                          "client": "app"])
        guard let t = o["token"]?.string, Self.plausibleToken(t), let u = o["user_id"]?.string, Hex.decode(u, length: 16) != nil,
              let e = o["expires_ms"]?.int else { throw HubAPIError.badReply }
        return SignedIn(bearer: HubBearer(t), userID: u, expiresMs: e)
    }

    public func signOut(_ bearer: HubBearer) async { _ = try? await call("DELETE", "/session", bearer: bearer) }

    /// `POST /channels/register/begin` for a phone: the hub's challenge (the unsigned `hub.channel_register` object) and its id.
    public func registerBegin(bearer: HubBearer, keyPub: SigningPublicKey, pairingCode: String) async throws -> (challengeID: String, challenge: JSONValue) {
        let o = try await call("POST", "/channels/register/begin", bearer: bearer,
                               body: ["kind": "phone", "key_pub": .string(B64U.encode(keyPub.x963)), "pairing_code": .string(pairingCode)])
        guard let id = o["challenge_id"]?.string, let ch = o["challenge"] else { throw HubAPIError.badReply }
        return (id, ch)
    }

    /// `POST /channels/register/complete`: the signed `hub.channel_cert`. Unverified here.
    public func registerComplete(bearer: HubBearer, challengeID: String, signed: JSONValue) async throws -> JSONValue {
        let o = try await call("POST", "/channels/register/complete", bearer: bearer, body: ["challenge_id": .string(challengeID), "signed": signed])
        guard let cert = o["channel_cert"] else { throw HubAPIError.badReply }
        return cert
    }

    public struct Bound: Sendable, Equatable {
        public let bearer: HubBearer
        public let userID: String, channelID: String
        public let expiresMs: Int64
        public let channelCert: JSONValue, card: JSONValue
    }

    /// `POST /session/channel`: the signed `hub.channel_auth` turns the pairing session into a channel session (12 h).
    public func bindChannel(bearer: HubBearer, auth: JSONValue) async throws -> Bound {
        let o = try await call("POST", "/session/channel", bearer: bearer, body: ["auth": auth])
        guard let t = o["token"]?.string, Self.plausibleToken(t), let u = o["user_id"]?.string, let c = o["channel_id"]?.string,
              let e = o["expires_ms"]?.int, let cert = o["channel_cert"], let card = o["card"] else { throw HubAPIError.badReply }
        return Bound(bearer: HubBearer(t), userID: u, channelID: c, expiresMs: e, channelCert: cert, card: card)
    }

    /// `PUT /channels/{id}/push` (channel session of that channel): the APNs target, and the channel-key-signed `hub.channel_push` naming the push
    /// key, or `nil` to keep the key the hub holds (an APNs token change needs no new key). `token` is the b64u APNs device token.
    public func registerPush(bearer: HubBearer, channelID: String, env: String, topic: String, token: String, pushKey: JSONValue?) async throws {
        guard Hex.decode(channelID, length: 16) != nil else { throw HubAPIError.badReply }
        let o = try await call("PUT", "/channels/\(channelID)/push", bearer: bearer,
                               body: ["env": .string(env), "topic": .string(topic), "token": .string(token), "push_key": pushKey ?? .null])
        guard o["registered"] == true else { throw HubAPIError.badReply }
    }

    /// `GET /session` (who am I) with a channel session: a cheap authenticated question. A revoked channel answers `channel_revoked` (6.4).
    public func confirmSession(_ bearer: HubBearer) async throws {
        _ = try await call("GET", "/session", bearer: bearer)
    }

    // MARK: the person's home (channel session; design B2)

    /// `GET /me/workspaces`: the workspaces this user has a part in, with role, mode and whether the host is online.
    public func myWorkspaces(_ bearer: HubBearer) async throws -> [HubWorkspace] {
        try HubViewParse.workspaces(try await call("GET", "/me/workspaces", bearer: bearer))
    }

    /// `GET /me/needs-you`: needs-you rows (full: from the workspace view; selective: shared items only). Rows are checked against `workspaces`.
    public func needsYou(_ bearer: HubBearer, workspaces: [HubWorkspace]) async throws -> HubNeedsYou {
        try HubViewParse.needsYou(try await call("GET", "/me/needs-you", bearer: bearer), workspaces: workspaces)
    }

    /// `GET /workspaces/{ws}/items/{id}`. The ids are validated before they reach the path.
    public func item(_ bearer: HubBearer, workspaceID: String, itemID: String, workspaces: [HubWorkspace]) async throws -> HubItemDetail {
        guard HubViewParse.isWorkspaceID(workspaceID), HubViewParse.isItemID(itemID) else { throw HubAPIError.badReply }
        let o = try await call("GET", "/workspaces/\(workspaceID)/items/\(itemID)", bearer: bearer)
        let d = try HubViewParse.detail(o, workspaces: workspaces)
        guard d.row.workspaceID == workspaceID, d.row.itemID == itemID else { throw HubAPIError.badReply }
        return d
    }

    static func plausibleToken(_ t: String) -> Bool { (1...256).contains(t.utf8.count) && t.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F } }
}

private extension Dictionary where Key == String, Value == JSONValue {
    /// The reply carries (at least) these keys; extra members are tolerated for forward compatibility of the web API.
    func hasKeys(_ keys: Set<String>) -> Bool { keys.isSubset(of: Set(self.keys)) }
}
