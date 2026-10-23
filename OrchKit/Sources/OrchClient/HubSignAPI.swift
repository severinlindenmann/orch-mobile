import Foundation
import OrchProtocol

// The custodial routes of the hub web API (orch-hub protocol 8.4 and the web API table): `POST /sign/prepare`, `GET /sign/prepared/{id}`,
// `POST /sign/sign`. The hub's `shown` block (its own rendering of the event) is deliberately NOT read: the phone renders from `ctx` only.

public struct HubPrepared: Sendable, Equatable {
    public let preparedID: String
    /// `ctx(E without channel_proof)`: the bytes the phone hashes and renders. Unverified until `HubSign.checkPrepared`.
    public let ctx: JSONValue
    public let digestHex: String
    public let expiresMs: Int64
}

public struct HubSignedReply: Sendable, Equatable {
    public let eventID: String
    public let type: String
    public let workspaceID: String
    public let log: String
}

extension HubAPI {
    static func plausiblePreparedID(_ s: String) -> Bool {
        (1...64).contains(s.utf8.count) && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
    }

    private func parsePrepared(_ o: [String: JSONValue]) throws -> HubPrepared {
        // `shown` (and anything else) is ignored; only these four members are read.
        guard let id = o["prepared_id"]?.string, Self.plausiblePreparedID(id), let ctx = o["ctx"], ctx.object != nil,
              let d = o["digest"]?.string, let e = o["expires_ms"]?.int else { throw HubAPIError.badReply }
        return HubPrepared(preparedID: id, ctx: ctx, digestHex: d, expiresMs: e)
    }

    /// `POST /sign/prepare`: the hub builds the event for `action` (one of the four decisions) and replies with `ctx`, its digest and the expiry.
    public func prepare(bearer: HubBearer, workspaceID: String, channelID: String, action: JSONValue) async throws -> HubPrepared {
        try parsePrepared(try await call("POST", "/sign/prepare", bearer: bearer,
                                        body: ["workspace_id": .string(workspaceID), "channel_id": .string(channelID), "action": action]))
    }

    /// `GET /sign/prepared/{id}`: a request this user prepared (a push carries only the id). Read-only: it does not consume it.
    public func prepared(bearer: HubBearer, preparedID: String) async throws -> HubPrepared {
        guard Self.plausiblePreparedID(preparedID) else { throw HubAPIError.badReply }
        return try parsePrepared(try await call("GET", "/sign/prepared/" + preparedID, bearer: bearer))
    }

    /// `POST /sign/sign`: hands the channel proof to the hub, which signs with the user's key.
    public func sign(bearer: HubBearer, preparedID: String, channelID: String, proof: String) async throws -> HubSignedReply {
        guard Self.plausiblePreparedID(preparedID) else { throw HubAPIError.badReply }
        let o = try await call("POST", "/sign/sign", bearer: bearer,
                               body: ["prepared_id": .string(preparedID), "channel_id": .string(channelID), "channel_proof": .string(proof)])
        guard o["ok"] == true, let e = o["event_id"]?.string, let t = o["type"]?.string, let w = o["workspace_id"]?.string, let l = o["log"]?.string
        else { throw HubAPIError.badReply }
        return HubSignedReply(eventID: e, type: t, workspaceID: w, log: l)
    }
}
