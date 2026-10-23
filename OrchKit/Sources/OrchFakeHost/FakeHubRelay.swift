import Foundation
import OrchClient
import OrchCustody
import OrchProtocol

/// An in-process relay mailbox for hub channels (orch-hub protocol 10.8.4), for tests and the Simulator: it checks a channel-signed request in the
/// relay's order (header syntax, clock, certificate under the hub's card, signature, revocation, nonce replay), holds the messages the "hub"
/// leaves, and records every request. Fake keys only.
public final class FakeHubRelay: RequestSender, @unchecked Sendable {
    public let origin: String
    private let hub: FakeHub
    private let wall: any WallClock
    private let lock = NSLock()
    private var messages: [String: [String: (c: String, expiresMs: Int64)]] = [:]
    private var revokedChannels: Set<String> = []
    private var nonces: Set<String> = []
    private var _log: [String] = []

    /// Every request as `METHOD /path`, in order.
    public var log: [String] { lock.withLock { _log } }
    /// When set, every channel request is refused with this status/code first (a hostile or broken relay).
    public var forcedRefusal: (status: Int, code: String)?

    public init(origin: String, hub: FakeHub, wall: any WallClock = SystemWallClock()) {
        self.origin = origin; self.hub = hub; self.wall = wall
    }

    /// What the hub's `PUT /v2/hubs/{hub}/mailbox/{ch}/{id}` does.
    public func put(channelID: String, id: String, c: String, ttlSeconds: Int64 = 3600) {
        lock.withLock { messages[channelID, default: [:]][id] = (c, wall.nowMs + ttlSeconds * 1000) }
    }

    /// The hub's signed purge on revocation: from then on the relay refuses the channel (permanently).
    public func purgeAndRevoke(channelID: String) {
        lock.withLock { _ = revokedChannels.insert(channelID); messages[channelID] = nil }
    }

    public func held(channelID: String) -> [String] { lock.withLock { (messages[channelID] ?? [:]).keys.sorted() } }

    private func fail(_ status: Int, _ code: String) throws -> WireReply {
        try WireReply(status: status, headers: ["content-type": "application/json"], body: try canonicalJSON(["error": .string(code)]))
    }

    private func ok(_ body: [String: JSONValue]) throws -> WireReply {
        try WireReply(status: 200, headers: ["content-type": "application/json"], body: try canonicalJSON(.object(body)))
    }

    public func send(_ r: WireRequest) async throws -> WireReply {
        try lock.withLock { try handle(r) }
    }

    private func handle(_ r: WireRequest) throws -> WireReply {
        _log.append("\(r.method) \(r.target)")
        if let f = forcedRefusal { return try fail(f.status, f.code) }
        // 1. syntax: method, canonical target under /v2/hub-channels/<hub>/<ch>/, an empty body
        let parts = r.target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 6, parts[0] == "", parts[1] == "v2", parts[2] == "hub-channels", Hex.decode(parts[3], length: 16) != nil,
              Hex.decode(parts[4], length: 16) != nil, parts[5] == "mailbox", parts.count <= 7, r.body.isEmpty, !r.target.contains("?"),
              r.method == "GET" || r.method == "DELETE",
              let certText = r.header("orch-channel-cert"), certText.utf8.count <= 4096, let tsText = r.header("orch-channel-ts"), let ts = Int64(tsText),
              let nonceText = r.header("orch-channel-nonce"), let nonce = Hex.decode(nonceText, length: 16),
              let sigText = r.header("orch-channel-signature"), let sig = B64U.decode(sigText, length: 64),
              let certBytes = B64U.decode(certText), let cert = try? StrictJSON.parse(certBytes, maxBytes: 4096)
        else { return try fail(400, "malformed") }
        let hubID = parts[3], ch = parts[4]
        // 2. clock
        guard abs(ts - wall.nowMs) <= 120_000 else { return try fail(401, "stale_timestamp") }
        // 3-4. the hub's card and the certificate under it
        guard hubID == hub.hubID, let held = try? HubVerifier(devMode: true).verifyCard(hub.cardJSON, nowMs: wall.nowMs) else { return try fail(401, "unknown_hub") }
        guard let c = try? HubVerifier(devMode: true).verifyChannelCert(cert, held: held, nowMs: wall.nowMs) else { return try fail(401, "cert_invalid") }
        guard c.channelID == ch else { return try fail(403, "other_user") }
        // 5. the signature, over the exact bytes of 10.8.4
        let tail = parts.count == 7 ? "/" + parts[6] : ""
        guard let bytes = try? HubChannelSigner.relayRequestBytes(hubID: hubID, channelID: ch, tsMs: ts, nonce: nonce, method: r.method,
                                                                  target: "/v2/hub-channels/\(hubID)/\(ch)/mailbox" + tail),
              Signature.verify(c.keyPub, signature: sig, message: bytes) else { return try fail(401, "bad_channel_signature") }
        // 6. revoked by the hub's signed purge
        if revokedChannels.contains(ch) { return try fail(403, "channel_revoked") }
        // 7. replay
        guard nonces.insert("\(ch)/\(nonceText)").inserted else { return try fail(401, "replay") }
        // 8. routes
        let now = wall.nowMs
        messages[ch] = (messages[ch] ?? [:]).filter { $0.value.expiresMs > now }
        switch (r.method, parts.count) {
        case ("GET", 6):
            let list = (messages[ch] ?? [:]).sorted { $0.key < $1.key }.map { JSONValue.object(["id": .string($0.key), "expires_ms": .int($0.value.expiresMs)]) }
            return try ok(["messages": .array(list)])
        case ("GET", 7):
            guard Hex.decode(parts[6], length: 16) != nil, let m = messages[ch]?[parts[6]] else { return try fail(404, "not_found") }
            return try ok(["id": .string(parts[6]), "c": .string(m.c), "expires_ms": .int(m.expiresMs)])
        case ("DELETE", 7):
            guard Hex.decode(parts[6], length: 16) != nil else { return try fail(404, "not_found") }
            messages[ch]?[parts[6]] = nil
            return try ok(["id": .string(parts[6]), "deleted": true])
        default:
            return try fail(404, "not_found")
        }
    }
}
