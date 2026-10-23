import CryptoKit
import Foundation
import OrchCustody
import OrchProtocol

/// Why a mailbox request failed. The relay's answers are NOT signed (protocol 10.8.4): `channelRevoked` is a claim, not proof.
public enum HubRelayError: Error, Equatable, Sendable {
    /// 403 `channel_revoked`: the relay refuses this channel. Never a wipe by itself (L2B-2): the caller asks its hub.
    case channelRevoked
    case network
    case refused(code: String, status: Int)
    case badReply
}

/// The channel's own mailbox at the relay (protocol 10.8.4): `GET .../mailbox`, `GET .../mailbox/{id}`, `DELETE .../mailbox/{id}`, each signed by the
/// channel key through `HubChannelSigner.relayRequest` (no other call exists) with the channel certificate in a header, body empty. The sender is
/// bound to ONE origin: the relay named by the hub's verified card.
public struct HubChannelRelay: Sendable {
    public struct Entry: Equatable, Sendable { public let id: String; public let expiresMs: Int64 }

    let hubID: String
    let signer: HubChannelSigner
    let certHeader: String
    let sender: any RequestSender
    let wall: any WallClock
    let entropy: any Entropy

    /// - Parameter channelCert: the signed `hub.channel_cert` the phone verified at pairing (its b64u must fit the 4096-character header).
    public init(hubID: String, signer: HubChannelSigner, channelCert: JSONValue, sender: any RequestSender,
                wall: any WallClock = SystemWallClock(), entropy: any Entropy = SystemEntropy()) throws {
        guard Hex.decode(hubID, length: 16) != nil else { throw HubRelayError.badReply }
        let header = B64U.encode(try canonicalJSON(channelCert))
        guard header.utf8.count <= 4096 else { throw HubRelayError.badReply }
        self.hubID = hubID; self.signer = signer; self.certHeader = header; self.sender = sender; self.wall = wall; self.entropy = entropy
    }

    var base: String { "/v2/hub-channels/\(hubID)/\(signer.channelID)/mailbox" }

    func call(_ method: String, _ target: String) async throws -> (status: Int, body: [String: JSONValue]) {
        let ts = wall.nowMs, nonce = entropy.bytes(16)
        let sig = try signer.relayRequest(hubID: hubID, method: method, target: target, tsMs: ts, nonce: nonce)
        let headers = ["orch-channel-cert": certHeader, "orch-channel-ts": String(ts), "orch-channel-nonce": Hex.encode(nonce),
                       "orch-channel-signature": sig, "accept": "application/json"]
        let reply: WireReply
        do {
            reply = try await sender.send(try WireRequest(method: method, target: target, headers: headers, body: Data(), clientAddress: HubAPI.clientAddress))
        } catch is CancellationError { throw CancellationError() } catch { throw HubRelayError.network }
        guard let obj = (try? StrictJSON.parse(reply.body, maxBytes: 1 << 20))?.object else {
            if reply.status == 404 { return (404, [:]) }
            throw reply.status == 200 ? HubRelayError.badReply : HubRelayError.refused(code: "malformed", status: reply.status)
        }
        if reply.status == 200 || reply.status == 404 { return (reply.status, obj) }
        let code = obj["error"]?.string.flatMap { $0.utf8.count <= 64 && $0.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F } ? $0 : nil } ?? "malformed"
        if reply.status == 403, code == "channel_revoked" { throw HubRelayError.channelRevoked }
        throw HubRelayError.refused(code: code, status: reply.status)
    }

    /// Every held message (at most 256), sorted by id.
    public func list() async throws -> [Entry] {
        let r = try await call("GET", base)
        guard r.status == 200, let items = r.body["messages"]?.array, items.count <= 256 else { throw HubRelayError.badReply }
        return try items.map { v in
            guard let o = v.object, let id = o["id"]?.string, Hex.decode(id, length: 16) != nil, let e = o["expires_ms"]?.int else { throw HubRelayError.badReply }
            return Entry(id: id, expiresMs: e)
        }
    }

    /// The sealed message `c` (b64u), nil when it is gone (404).
    public func get(_ id: String) async throws -> String? {
        let r = try await call("GET", base + "/" + id)
        if r.status == 404 { return nil }
        guard r.body["id"]?.string == id, let c = r.body["c"]?.string, B64U.decode(c) != nil else { throw HubRelayError.badReply }
        return c
    }

    /// Deletes a handled message (200 also when it is absent).
    public func delete(_ id: String) async throws {
        let r = try await call("DELETE", base + "/" + id)
        guard r.status == 200 else { throw HubRelayError.badReply }
    }
}
