import CryptoKit
import Foundation
import OrchProtocol
import Security

/// Device custody: P-256 keys generated inside the Secure Enclave (decision A6, D49).
///
/// Access control is `WhenPasscodeSetThisDeviceOnly` plus `.privateKeyUsage`: the key signs whenever the phone is
/// unlocked, with no per-signature Face ID (`.userPresence` / biometry are deliberately absent, D49) and cannot
/// be created or used without a passcode. The only thing stored is the opaque `dataRepresentation` blob.
public struct SecureEnclaveCustody: DeviceKeyCustody {
    let blobs: KeyBlobStore

    public init(vault: SecretVault) { blobs = KeyBlobStore(vault: vault) }

    static func accessControl() throws -> SecAccessControl {
        var err: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .privateKeyUsage, &err) else { throw CustodyError.unavailable }
        return ac
    }

    public func create(realm: Realm) throws -> DeviceIdentity {
        guard SecureEnclave.isAvailable else { throw CustodyError.unavailable }
        guard try !blobs.exists(realm) else { throw CustodyError.alreadyExists }
        let ac = try Self.accessControl()
        let sig: SecureEnclave.P256.Signing.PrivateKey, kx: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            sig = try SecureEnclave.P256.Signing.PrivateKey(accessControl: ac)
            kx = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac)
        } catch { throw CustodyError.unavailable }
        try blobs.write(realm, KeyPurpose.sig, sig.dataRepresentation)
        do { try blobs.write(realm, KeyPurpose.kx, kx.dataRepresentation) }
        catch { try? blobs.deleteBoth(realm); throw error }
        return try Self.identity(sigBlob: sig.dataRepresentation, kxBlob: kx.dataRepresentation)
    }

    public func load(realm: Realm) throws -> DeviceIdentity {
        let (s, k) = try blobs.readBoth(realm)
        return try Self.identity(sigBlob: s, kxBlob: k)
    }

    static func identity(sigBlob: Data, kxBlob: Data) throws -> DeviceIdentity {
        do {
            return DeviceIdentity(
                sig: try SecureEnclaveSigner(blob: sigBlob), kx: try SecureEnclaveKeyAgreer(blob: kxBlob))
        } catch { throw CustodyError.orphaned }
    }

    public func delete(realm: Realm) throws { try blobs.deleteBoth(realm) }

    public func status(realm: Realm) -> CustodyStatus {
        blobs.status(realm) { s, k in _ = try Self.identity(sigBlob: s, kxBlob: k) }
    }
}

struct SecureEnclaveSigner: Signer, @unchecked Sendable {
    let key: SecureEnclave.P256.Signing.PrivateKey
    let publicKey: SigningPublicKey

    init(blob: Data) throws {
        key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        publicKey = try SigningPublicKey(x963: key.publicKey.x963Representation)
    }

    func rawSignature(over message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}

struct SecureEnclaveKeyAgreer: KeyAgreer, @unchecked Sendable {
    let key: SecureEnclave.P256.KeyAgreement.PrivateKey
    let publicKey: AgreementPublicKey

    init(blob: Data) throws {
        key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
        publicKey = try AgreementPublicKey(x963: key.publicKey.x963Representation)
    }

    func sharedSecret(with peer: AgreementPublicKey) throws -> Data {
        try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peer.x963)).withUnsafeBytes { Data($0) }
    }
}
