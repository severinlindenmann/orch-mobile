import CryptoKit
import Foundation
import OrchProtocol

/// The result of `HubChannelSigner.proof`: the digest the signer computed itself and the proof over it.
public struct HubProof: Sendable, Equatable {
    public let digest: Data
    /// `b64u(Sign(channel_key, "orch/v2/hub-channel-proof|" || digest))`
    public let proof: String
}

/// The hub channel key of this phone (design B1, D-B2): a P-256 signing key that signs exactly FIVE things, each through its own typed
/// call, and nothing else. There is no "sign these bytes" call (like the hub's `ChannelSigner`): every label is chosen here, and every
/// input is checked against the hub this key was made for.
///
/// 1. `hub.channel_register` (the proof of possession), only for a challenge that `HubVerifier.checkRegistrationChallenge` accepted for
///    THIS key;
/// 2. `hub.channel_auth` (binds a pairing session to this channel);
/// 3. `hub.channel_push` (names the push key; never this key itself);
/// 4. the channel to relay request bytes (the channel's own mailbox, empty body);
/// 5. the custodial proof, over a digest this type computes itself from the context it is given.
public struct HubChannelSigner: Sendable {
    let signer: any Signer
    public let publicKey: SigningPublicKey
    public let channelID: String
    /// Which custody made the key (a Secure Enclave key on a device, a software key in the Simulator and on macOS).
    public let custody: CustodyKind

    package init(signer: any Signer, custody: CustodyKind) {
        self.signer = signer
        self.publicKey = signer.publicKey
        self.channelID = HubIdentifiers.channelID(key: signer.publicKey)
        self.custody = custody
    }

    private func signObject(_ o: [String: JSONValue], label: String) throws -> JSONValue {
        let sig = try Signature.sign(signer, label: label, message: try canonicalJSON(.object(o)))
        return .object(["o": .object(o), "sig": .string(B64U.encode(sig))])
    }

    private static func header(_ kind: String) -> [String: JSONValue] { ["v": 2, "suite": 2, "kind": .string(kind), "hv": 0] }

    // MARK: 1. registration

    /// Proof of possession for the registration the hub opened (protocol 6.3). The challenge can only come from the verifier's check, which
    /// bound it to this key, so a challenge for another key is refused here as well.
    public func register(_ challenge: HubRegistrationChallenge) throws -> JSONValue {
        guard challenge.keyPub == publicKey else { throw Refusal.challengeInvalid }
        return try signObject(challenge.object, label: Label.sigHubChannelRegister)
    }

    // MARK: 2. channel_auth

    /// `hub.channel_auth` (protocol 6.4): binds the pairing session (named by the hash of its token, never by the token) to this channel.
    public func channelAuth(hubID: String, userID: String, sessionToken: String, nowMs: Int64) throws -> JSONValue {
        guard Hex.decode(hubID, length: 16) != nil, Hex.decode(userID, length: 16) != nil, nowMs >= 0 else { throw Refusal.malformed }
        var o = Self.header("hub.channel_auth")
        o["hub_id"] = .string(hubID); o["user_id"] = .string(userID); o["channel_id"] = .string(channelID)
        o["session_ref"] = .string(try HubIdentifiers.sessionRef(token: sessionToken)); o["ts_ms"] = .int(nowMs); o["dev"] = .bool(HubBuild.isDev)
        return try signObject(o, label: Label.sigHubChannelAuth)
    }

    // MARK: 3. channel_push

    /// `hub.channel_push` (protocol 6.4): names the push key the hub seals hints to. One key, one use: never this key itself.
    public func pushKey(hubID: String, pushPub: AgreementPublicKey, nowMs: Int64) throws -> JSONValue {
        guard Hex.decode(hubID, length: 16) != nil, nowMs >= 0, pushPub.x963 != publicKey.x963 else { throw Refusal.malformed }
        var o = Self.header("hub.channel_push")
        o["hub_id"] = .string(hubID); o["channel_id"] = .string(channelID); o["push_pub"] = .string(B64U.encode(pushPub.x963))
        o["issued_ms"] = .int(nowMs); o["dev"] = .bool(HubBuild.isDev)
        return try signObject(o, label: Label.sigHubChannelPush)
    }

    // MARK: 4. channel to relay request

    /// The signed bytes of a channel's own mailbox request (protocol 10.8.4): `GET .../mailbox`, `GET .../mailbox/<id>` or
    /// `DELETE .../mailbox/<id>`, of THIS channel at `hubID`, body empty. Anything else is `malformed`.
    package static func relayRequestBytes(hubID: String, channelID: String, tsMs: Int64, nonce: Data, method: String, target: String) throws -> Data {
        guard let hub = Hex.decode(hubID, length: 16), let ch = Hex.decode(channelID, length: 16), nonce.count == 16, tsMs >= 0,
              target.utf8.allSatisfy({ $0 >= 0x21 && $0 < 0x7F }), target.utf8.count <= 256 else { throw Refusal.malformed }
        let prefix = "/v2/hub-channels/\(hubID)/\(channelID)/mailbox"
        let isList = target == prefix
        let isItem = target.hasPrefix(prefix + "/") && Hex.decode(String(target.dropFirst(prefix.count + 1)), length: 16) != nil
        guard (isList && method == "GET") || (isItem && (method == "GET" || method == "DELETE")) else { throw Refusal.malformed }
        return Data(Label.sigHubChannelRelayReq.utf8) + Bytes.u8(Suite2.id) + hub + ch + Bytes.u64(UInt64(tsMs)) + nonce
            + Bytes.lp16(Data(method.utf8)) + Bytes.lp16(Data(target.utf8)) + Data(SHA256.hash(data: Data()))
    }

    /// `b64u` signature for the `Orch-Channel-Signature` header of a mailbox request of this channel.
    public func relayRequest(hubID: String, method: String, target: String, tsMs: Int64, nonce: Data) throws -> String {
        let bytes = try Self.relayRequestBytes(hubID: hubID, channelID: channelID, tsMs: tsMs, nonce: nonce, method: method, target: target)
        return B64U.encode(try signer.rawSignature(over: bytes))
    }

    // MARK: 5. custodial proof

    /// The digest the channel signs (protocol 8.2): `H("orch/v2/hub-event-digest|" || cj(ctx))` where `ctx.event` has no `channel_proof`.
    /// The caller passes the CONTEXT it rendered and checked; the digest is computed here, never taken from the hub.
    public static func digest(ofContext ctx: JSONValue) throws -> Data { try HubSign.digest(ofContext: ctx) }

    /// The custodial proof over a digest computed here from `ctx` (design B3: only after the sign view model rendered and checked it).
    /// Package-level on purpose (L2-B1-4): B3 reaches it only through its four-type allow-list sign view model, never from app code.
    package func proof(context ctx: JSONValue) throws -> HubProof {
        let digest = try Self.digest(ofContext: ctx)
        let sig = try Signature.sign(signer, label: Label.sigHubChannelProof, message: digest)
        return HubProof(digest: digest, proof: B64U.encode(sig))
    }
}
