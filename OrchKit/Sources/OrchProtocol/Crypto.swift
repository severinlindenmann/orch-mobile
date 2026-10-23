import CryptoKit
import Foundation

/// HKDF-SHA-256 derivations of section 3. Every use of a long-lived key goes through HKDF with its own label.
public enum KDF {
    /// `label` followed by each field preceded by `|` (an id as 32 hex characters, a decimal integer, or a purpose).
    public static func info(_ label: String, _ fields: [String]) -> Data {
        Data((label + fields.map { "|" + $0 }.joined()).utf8)
    }

    /// RFC 5869 HKDF-SHA-256. An empty salt means 32 zero bytes (what CryptoKit does too).
    package static func hkdf(ikm: SymmetricKey, salt: Data, info: Data, length: Int = 32) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: length)
    }

    static func derive(_ ikm: SymmetricKey, _ label: String, _ fields: [String]) -> SymmetricKey {
        hkdf(ikm: ikm, salt: Data(), info: info(label, fields))
    }

    /// `K_bridge` from `WK_e`.
    public static func kBridge(wk: SymmetricKey, workspace: ID16, epoch: UInt32) -> SymmetricKey {
        derive(wk, Label.kdfBridge, [workspace.hex, String(epoch)])
    }
    /// `K_push` from `WK_e` (section 9). All a push receiver needs; it never needs `WK_e` itself.
    public static func kPush(wk: SymmetricKey, workspace: ID16, epoch: UInt32) -> SymmetricKey {
        derive(wk, Label.kdfPush, [workspace.hex, String(epoch)])
    }
    public static func kWrapWK(wk: SymmetricKey, workspace: ID16, epoch: UInt32) -> SymmetricKey {
        derive(wk, Label.kdfWrapWK, [workspace.hex, String(epoch)])
    }
    public static func kWrapSK(sk: SymmetricKey, space: ID16, epoch: UInt32) -> SymmetricKey {
        derive(sk, Label.kdfWrapSK, [space.hex, String(epoch)])
    }
    /// `K_pair`, the epoch-0 channel key, from the link secret `S`.
    public static func kPair(secret: SymmetricKey, workspace: ID16, offer: ID16) -> SymmetricKey {
        derive(secret, Label.kdfPair, [workspace.hex, offer.hex])
    }
    public static func kCard(ck: SymmetricKey, workspace: ID16, cardSeq: UInt32) -> SymmetricKey {
        derive(ck, Label.kdfCard, [workspace.hex, String(cardSeq)])
    }
    public static func kDropContent(dek: SymmetricKey, object: ID16, version: UInt32) -> SymmetricKey {
        derive(dek, Label.kdfDropContent, [object.hex, String(version)])
    }
    public static func kDropMeta(dek: SymmetricKey, object: ID16, version: UInt32) -> SymmetricKey {
        derive(dek, Label.kdfDropMeta, [object.hex, String(version)])
    }
    /// The label key from the personal vault key `PVK` (section 5.4).
    public static func kLabel(pvk: SymmetricKey, person: ID16) -> SymmetricKey {
        derive(pvk, Label.kdfLabel, [person.hex])
    }
    /// One envelope's key: HKDF(K, salt, msg_label) (section 5.1 / 8.2).
    public static func messageKey(base: SymmetricKey, salt: Data, msgLabel: String) -> SymmetricKey {
        hkdf(ikm: base, salt: salt, info: Data(msgLabel.utf8))
    }
}

/// AES-256-GCM with a 12-zero-byte nonce. Safe only because every key is used once (SALTED-AEAD, sealing).
enum ZeroNonceGCM {
    static let nonce = try! AES.GCM.Nonce(data: Data(count: 12))

    /// `ciphertext || tag`
    static func seal(key: SymmetricKey, plaintext: Data, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func open(key: SymmetricKey, blob: Data, aad: Data) throws -> Data {
        guard blob.count >= 16 else { throw CryptoFailure.authenticationFailed }
        let ct = blob.prefix(blob.count - 16), tag = blob.suffix(16)
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag), using: key, authenticating: aad)
        } catch { throw CryptoFailure.authenticationFailed }
    }
}

/// SALTED-AEAD (section 5.1): `salt (16) || AES-256-GCM(HKDF(K, salt, msg_label), zero nonce, pt, aad)`.
public enum SaltedAEAD {
    public static let saltLength = 16

    /// Draws a fresh random salt for every seal.
    public static func seal(key: SymmetricKey, msgLabel: String, aad: Data, plaintext: Data) throws -> Data {
        var g = SystemRandomNumberGenerator()
        let salt = Data((0..<saltLength).map { _ in UInt8.random(in: 0...255, using: &g) })
        return try seal(key: key, msgLabel: msgLabel, aad: aad, plaintext: plaintext, salt: salt)
    }

    /// TEST-ONLY seam: a caller-chosen salt reproduces the vectors. A salt must never repeat under one key.
    static func seal(key: SymmetricKey, msgLabel: String, aad: Data, plaintext: Data, salt: Data) throws -> Data {
        guard salt.count == saltLength else { throw CryptoFailure.invalidLength }
        let k = KDF.messageKey(base: key, salt: salt, msgLabel: msgLabel)
        return salt + (try ZeroNonceGCM.seal(key: k, plaintext: plaintext, aad: aad))
    }

    public static func open(key: SymmetricKey, msgLabel: String, aad: Data, blob: Data) throws -> Data {
        guard blob.count >= saltLength + 16 else { throw CryptoFailure.authenticationFailed }
        let b = Data(blob)
        let k = KDF.messageKey(base: key, salt: b.prefix(saltLength), msgLabel: msgLabel)
        return try ZeroNonceGCM.open(key: k, blob: b.dropFirst(saltLength), aad: aad)
    }
}

/// The closed list of sealing purposes (section 5.3).
public enum SealPurpose: String, Sendable, CaseIterable {
    case wk, sk, card
    case certRequest = "cert-request"
    case dropDEK = "drop-dek"
    case wsEnvelope = "ws-envelope"
    case vault
}

/// Sealing to a device `dk_kx` or a workspace `WXK` (section 5.3), HPKE-shaped base mode: no sender authentication.
/// Wherever the sender matters, the blob sits inside something the sender signs.
public enum Sealing {
    static func aad(purpose: SealPurpose, object: ID16, epoch: UInt32, extra: Data) -> Data {
        aad(purposeName: purpose.rawValue, object: object, epoch: epoch, extra: extra)
    }

    /// The purpose of a hub push hint (orch-hub protocol 10.8.2). It is not in `SealPurpose` (the closed list of direct-mode purposes).
    static let hubPushPurpose = "hub-push"

    static func aad(purposeName: String, object: ID16, epoch: UInt32, extra: Data) -> Data {
        let p = Data(purposeName.utf8)
        return Data(Label.aadSeal.utf8) + Bytes.u8(Suite2.id) + Bytes.u8(UInt8(p.count)) + p + object.bytes
            + Bytes.u32(epoch) + extra
    }

    static func key(sharedSecret: Data, ephPub: Data, recipientPub: Data, purpose: SealPurpose, recipientID: ID16) -> SymmetricKey {
        key(sharedSecret: sharedSecret, ephPub: ephPub, recipientPub: recipientPub, purposeName: purpose.rawValue, recipientID: recipientID)
    }

    static func key(sharedSecret: Data, ephPub: Data, recipientPub: Data, purposeName: String, recipientID: ID16) -> SymmetricKey {
        KDF.hkdf(ikm: SymmetricKey(data: sharedSecret), salt: ephPub + recipientPub,
                 info: KDF.info(Label.kdfSeal, [purposeName, recipientID.hex]))
    }

    /// Opens a hub push hint sealed to a channel's push key (protocol 10.8.2): purpose `hub-push`, recipient id = the channel id, object id =
    /// the message id, epoch 0, extra = the 16-byte hub id.
    package static func openHubPush(with recipient: some KeyAgreer, channel: ID16, message: ID16, hub: ID16, sealed: Data) throws -> Data {
        guard sealed.count >= Suite2.publicKeyLength + 16 else { throw CryptoFailure.authenticationFailed }
        let blob = Data(sealed)
        let ephPub = blob.prefix(Suite2.publicKeyLength)
        let eph = try AgreementPublicKey(x963: ephPub)
        let ss = try recipient.sharedSecret(with: eph)
        guard ss.contains(where: { $0 != 0 }) else { throw CryptoFailure.degenerateSharedSecret }
        let k = key(sharedSecret: ss, ephPub: Data(ephPub), recipientPub: recipient.publicKey.x963, purposeName: hubPushPurpose, recipientID: channel)
        return try ZeroNonceGCM.open(key: k, blob: blob.dropFirst(Suite2.publicKeyLength),
                                     aad: aad(purposeName: hubPushPurpose, object: message, epoch: 0, extra: hub.bytes))
    }

    /// Seals a hub push hint to a channel's push key (protocol 10.8.2). Only the HUB seals; the phone never does. Package-level for the fake hub and
    /// the tests (the ephemeral key is generated here and used once).
    package static func sealHubPush(to recipient: AgreementPublicKey, channel: ID16, message: ID16, hub: ID16, plaintext: Data) throws -> Data {
        let eph = SoftwareKeyAgreer()
        let ss = try eph.sharedSecret(with: recipient)
        guard ss.contains(where: { $0 != 0 }) else { throw CryptoFailure.degenerateSharedSecret }
        let k = key(sharedSecret: ss, ephPub: eph.publicKey.x963, recipientPub: recipient.x963, purposeName: hubPushPurpose, recipientID: channel)
        return eph.publicKey.x963 + (try ZeroNonceGCM.seal(key: k, plaintext: plaintext,
                                                           aad: aad(purposeName: hubPushPurpose, object: message, epoch: 0, extra: hub.bytes)))
    }

    /// Product seal. The ephemeral key is generated here, used once and dropped; it is deliberately not a
    /// parameter, because the zero nonce is safe only while the key is single-use.
    public static func seal(to recipient: AgreementPublicKey, recipientID: ID16, purpose: SealPurpose, object: ID16,
                            epoch: UInt32, extra: Data = Data(), plaintext: Data) throws -> Data {
        try seal(ephemeral: SoftwareKeyAgreer(), to: recipient, recipientID: recipientID, purpose: purpose,
                 object: object, epoch: epoch, extra: extra, plaintext: plaintext)
    }

    /// TEST-ONLY seam: fixed ephemeral key, to reproduce the vectors. Never call it from product code.
    static func seal(ephemeral eph: some KeyAgreer, to recipient: AgreementPublicKey, recipientID: ID16,
                     purpose: SealPurpose, object: ID16, epoch: UInt32, extra: Data, plaintext: Data) throws -> Data {
        let ss = try eph.sharedSecret(with: recipient)
        guard ss.contains(where: { $0 != 0 }) else { throw CryptoFailure.degenerateSharedSecret }
        let k = key(sharedSecret: ss, ephPub: eph.publicKey.x963, recipientPub: recipient.x963, purpose: purpose, recipientID: recipientID)
        return eph.publicKey.x963 + (try ZeroNonceGCM.seal(key: k, plaintext: plaintext,
                                                           aad: aad(purpose: purpose, object: object, epoch: epoch, extra: extra)))
    }

    /// Opens a sealed blob. Any wrong purpose, recipient id, object, epoch, extra, key or tampering fails the tag.
    package static func open(with recipient: some KeyAgreer, recipientID: ID16, purpose: SealPurpose, object: ID16,
                            epoch: UInt32, extra: Data = Data(), sealed: Data) throws -> Data {
        guard sealed.count >= Suite2.publicKeyLength + 16 else { throw CryptoFailure.authenticationFailed }
        let blob = Data(sealed)
        let ephPub = blob.prefix(Suite2.publicKeyLength)
        let eph = try AgreementPublicKey(x963: ephPub)
        let ss = try recipient.sharedSecret(with: eph)
        guard ss.contains(where: { $0 != 0 }) else { throw CryptoFailure.degenerateSharedSecret }
        let k = key(sharedSecret: ss, ephPub: Data(ephPub), recipientPub: recipient.publicKey.x963, purpose: purpose, recipientID: recipientID)
        return try ZeroNonceGCM.open(key: k, blob: blob.dropFirst(Suite2.publicKeyLength),
                                     aad: aad(purpose: purpose, object: object, epoch: epoch, extra: extra))
    }
}

/// Sealed device labels (section 5.4): a certificate's `label_sealed`, readable only with `PVK`.
public enum SealedLabel {
    static func aad(device: ID16) -> Data { Data(Label.aadLabel.utf8) + Bytes.u8(Suite2.id) + device.bytes }

    public static func seal(label: String, pvk: SymmetricKey, person: ID16, device: ID16) throws -> Data {
        try SaltedAEAD.seal(key: KDF.kLabel(pvk: pvk, person: person), msgLabel: Label.kdfLabelMsg,
                            aad: aad(device: device), plaintext: Data(label.utf8))
    }

    static func seal(label: String, pvk: SymmetricKey, person: ID16, device: ID16, salt: Data) throws -> Data {
        try SaltedAEAD.seal(key: KDF.kLabel(pvk: pvk, person: person), msgLabel: Label.kdfLabelMsg,
                            aad: aad(device: device), plaintext: Data(label.utf8), salt: salt)
    }

    public static func open(sealed: Data, pvk: SymmetricKey, person: ID16, device: ID16) throws -> String {
        let pt = try SaltedAEAD.open(key: KDF.kLabel(pvk: pvk, person: person), msgLabel: Label.kdfLabelMsg,
                                     aad: aad(device: device), blob: sealed)
        // Exact decode: String(data:encoding:) would drop a leading U+FEFF; invalid UTF-8 fails the round trip.
        let s = String(decoding: pt, as: UTF8.self)
        guard s.utf8.elementsEqual(pt) else { throw Refusal.malformed }
        return s
    }
}
