import CryptoKit
import Foundation
import OrchProtocol

#if targetEnvironment(simulator) || os(macOS)
/// Simulator and macOS-test custody: CryptoKit software keys with a simulated lock (decision A6). Compiled only
/// where there is no Secure Enclave, so a device build has no software path to fall back to.
public struct SoftwareCustody: DeviceKeyCustody {
    let blobs: KeyBlobStore
    public let lock: SimulatedLock

    public init(vault: SecretVault, lock: SimulatedLock = SimulatedLock()) {
        blobs = KeyBlobStore(vault: vault); self.lock = lock
    }

    private func checkLock() throws { if lock.isLocked { throw CustodyError.locked } }

    public func create(realm: Realm) throws -> DeviceIdentity {
        try checkLock()
        let sig = P256.Signing.PrivateKey(), kx = P256.KeyAgreement.PrivateKey()
        try blobs.createPair(realm, sig: sig.rawRepresentation, kx: kx.rawRepresentation)
        return try Self.identity(sigBlob: sig.rawRepresentation, kxBlob: kx.rawRepresentation, realm: realm, lock: lock)
    }

    public func load(realm: Realm) throws -> DeviceIdentity {
        try checkLock()
        let (s, k) = try blobs.readBoth(realm)
        return try Self.identity(sigBlob: s, kxBlob: k, realm: realm, lock: lock)
    }

    static func identity(sigBlob: Data, kxBlob: Data, realm: Realm, lock: SimulatedLock) throws -> DeviceIdentity {
        do {
            return DeviceIdentity(sig: try LockedSigner(raw: sigBlob, lock: lock), kx: try LockedKeyAgreer(raw: kxBlob, lock: lock), realm: realm, custody: .software)
        } catch { throw CustodyError.orphaned }
    }

    public func delete(realm: Realm) throws { try checkLock(); try blobs.deleteBoth(realm) }

    public func status(realm: Realm) -> CustodyStatus {
        if lock.isLocked { return .locked }
        return blobs.status(realm) { s, k in _ = try Self.identity(sigBlob: s, kxBlob: k, realm: realm, lock: lock) }
    }
}

/// A software key that refuses to work while the simulated device is locked, like a Secure Enclave key.
struct LockedSigner: Signer {
    let key: P256.Signing.PrivateKey
    let lock: SimulatedLock
    let publicKey: SigningPublicKey

    init(raw: Data, lock: SimulatedLock) throws {
        key = try P256.Signing.PrivateKey(rawRepresentation: raw)
        self.lock = lock
        publicKey = try SigningPublicKey(x963: key.publicKey.x963Representation)
    }

    func rawSignature(over message: Data) throws -> Data {
        if lock.isLocked { throw CustodyError.locked }
        return try key.signature(for: message).rawRepresentation
    }
}

struct LockedKeyAgreer: KeyAgreer {
    let key: P256.KeyAgreement.PrivateKey
    let lock: SimulatedLock
    let publicKey: AgreementPublicKey

    init(raw: Data, lock: SimulatedLock) throws {
        key = try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
        self.lock = lock
        publicKey = try AgreementPublicKey(x963: key.publicKey.x963Representation)
    }

    func sharedSecret(with peer: AgreementPublicKey) throws -> Data {
        if lock.isLocked { throw CustodyError.locked }
        return try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peer.x963)).withUnsafeBytes { Data($0) }
    }
}
#endif
