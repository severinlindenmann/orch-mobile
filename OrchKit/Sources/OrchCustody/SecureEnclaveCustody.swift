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
        let ac = try Self.accessControl()
        let sig: SecureEnclave.P256.Signing.PrivateKey, kx: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            sig = try SecureEnclave.P256.Signing.PrivateKey(accessControl: ac)
            kx = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac)
        } catch { throw CustodyError.unavailable }
        try blobs.createPair(realm, sig: sig.dataRepresentation, kx: kx.dataRepresentation)
        return try Self.identity(sigBlob: sig.dataRepresentation, kxBlob: kx.dataRepresentation, realm: realm)
    }

    public func load(realm: Realm) throws -> DeviceIdentity {
        let (s, k) = try blobs.readBoth(realm)
        return try Self.identity(sigBlob: s, kxBlob: k, realm: realm)
    }

    static func identity(sigBlob: Data, kxBlob: Data, realm: Realm) throws -> DeviceIdentity {
        do {
            return DeviceIdentity(
                sig: try SecureEnclaveSigner(blob: sigBlob), kx: try SecureEnclaveKeyAgreer(blob: kxBlob), realm: realm)
        } catch {
            // A blob that the Secure Enclave will not restore could be a lock, a transient failure or a dead
            // key (passcode removed): it cannot be told apart here, so refuse to use it without declaring it lost.
            throw CustodyError.unavailable
        }
    }

    public func delete(realm: Realm) throws { try blobs.deleteBoth(realm) }

    public func status(realm: Realm) -> CustodyStatus {
        blobs.status(realm) { s, k in _ = try Self.identity(sigBlob: s, kxBlob: k, realm: realm) }
    }
}

struct SecureEnclaveSigner: Signer {
    let key: SecureEnclave.P256.Signing.PrivateKey
    let publicKey: SigningPublicKey

    init(blob: Data) throws {
        key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        publicKey = try SigningPublicKey(x963: key.publicKey.x963Representation)
    }

    func rawSignature(over message: Data) throws -> Data {
        do { return try key.signature(for: message).rawRepresentation } catch { throw mapSecureEnclaveError(error) }
    }
}

struct SecureEnclaveKeyAgreer: KeyAgreer {
    let key: SecureEnclave.P256.KeyAgreement.PrivateKey
    let publicKey: AgreementPublicKey

    init(blob: Data) throws {
        key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
        publicKey = try AgreementPublicKey(x963: key.publicKey.x963Representation)
    }

    func sharedSecret(with peer: AgreementPublicKey) throws -> Data {
        do {
            return try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peer.x963))
                .withUnsafeBytes { Data($0) }
        } catch { throw mapSecureEnclaveError(error) }
    }
}

/// A Secure Enclave operation that fails because the device is locked surfaces as errSecInteractionNotAllowed,
/// either as a CryptoKit core-crypto status or as an OSStatus NSError. Those become `.locked`; anything else
/// passes through unchanged.
func mapSecureEnclaveError(_ error: Error) -> Error {
    if case CryptoKitError.underlyingCoreCryptoError(let code) = error, code == errSecInteractionNotAllowed { return CustodyError.locked }
    let ns = error as NSError
    if ns.domain == NSOSStatusErrorDomain, ns.code == Int(errSecInteractionNotAllowed) { return CustodyError.locked }
    return error
}
