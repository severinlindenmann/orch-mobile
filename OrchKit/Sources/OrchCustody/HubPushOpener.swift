import CryptoKit
import Foundation
import OrchProtocol

/// A hub push hint, after the seal opened and its fields were checked (protocol 10.8.2). A hint, never an authority.
public struct HubPushHint: Sendable, Equatable {
    public enum Kind: String, Sendable { case prepare, needsYou = "needs_you" }
    public let type: Kind
    public let tsMs: Int64
    /// 32 hex, opaque (a prepared id or ticket uid), or nil.
    public let ref: String?
}

/// The software P-256 KEY-AGREEMENT key hints are sealed to (design D-B2). It is created agreement-only (a CryptoKit
/// `KeyAgreement` key cannot sign), lives in the `.push` group (readable on a locked phone, by the app and the notification extension),
/// and its only operation is `openPush`. It is never handed to a signer.
public struct HubPushOpener: Sendable {
    let key: P256.KeyAgreement.PrivateKey
    public let publicKey: AgreementPublicKey

    init(raw: Data) throws {
        key = try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
        publicKey = try AgreementPublicKey(x963: key.publicKey.x963Representation)
    }

    private struct Agreer: KeyAgreer {
        let key: P256.KeyAgreement.PrivateKey
        let publicKey: AgreementPublicKey
        func sharedSecret(with peer: AgreementPublicKey) throws -> Data {
            try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peer.x963)).withUnsafeBytes { Data($0) }
        }
    }

    /// Opens `outer.c` (protocol 10.8.2): purpose `hub-push`, recipient id = `channelID`, object id = the message `id`, epoch 0, extra =
    /// `hub_id`. The caller has checked `outer.hub` and `outer.ch` are its own. The plaintext must be exactly
    /// `{v: 2, hv: 0, kind: "hub.push", type, ts_ms, ref}` with a known `type`; anything else is `malformed`.
    public func openPush(sealed: String, hubID: String, channelID: String, messageID: String) throws -> HubPushHint {
        guard let hub = ID16(hex: hubID), let ch = ID16(hex: channelID), let id = ID16(hex: messageID),
              let blob = B64U.decode(sealed) else { throw Refusal.malformed }
        let pt: Data
        do {
            pt = try Sealing.openHubPush(with: Agreer(key: key, publicKey: publicKey), channel: ch, message: id, hub: hub, sealed: blob)
        } catch { throw Refusal.malformed }
        guard let o = (try? StrictJSON.parse(pt, maxBytes: 4096))?.object, o.hasExactlyKeys(["v", "hv", "kind", "type", "ts_ms", "ref"]),
              o["v"] == .int(2), o["hv"] == .int(0), o["kind"] == "hub.push", let t = o["type"]?.string,
              let kind = HubPushHint.Kind(rawValue: t), let ts = o["ts_ms"]?.int, ts >= 0 else { throw Refusal.malformed }
        var ref: String?
        if let r = o["ref"] {
            if !r.isNull { guard let s = r.string, Hex.decode(s, length: 16) != nil else { throw Refusal.malformed }; ref = s }
        }
        return HubPushHint(type: kind, tsMs: ts, ref: ref)
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    fileprivate func hasExactlyKeys(_ keys: Set<String>) -> Bool {
        Set(self.keys) == keys && self.keys.allSatisfy { $0.utf8.allSatisfy { $0 < 0x80 } }
    }
}
