import CryptoKit
import Foundation
import OrchProtocol

public enum CustodyError: Error, Equatable, Sendable {
    /// Temporarily unreachable (device locked). Not a loss: do not wipe anything (challenge C4).
    case locked
    /// No device identity in this realm. Callers that expected one fail closed.
    case missing
    /// Keys exist but only partly, or cannot be restored. Fail closed.
    case orphaned
    case alreadyExists
    /// No Secure Enclave on a build that requires one. Never falls back to software.
    case unavailable
    case vault(VaultError)
}

/// `present`: usable now. `locked`: exists but unreachable for now. `missing` and `orphaned` fail closed: the
/// caller cleans dependent stores and push keys. `locked` never does.
public enum CustodyStatus: Equatable, Sendable {
    case present, locked, missing, orphaned
    public var failsClosed: Bool { self == .missing || self == .orphaned }
}

public struct DevicePublicKeys: Equatable, Sendable {
    public let sig: SigningPublicKey
    public let kx: AgreementPublicKey
}

/// `dk_sig` (signing) and `dk_kx` (key agreement): two P-256 keys, one device identity (decision A6).
public struct DeviceIdentity: Sendable {
    public let sig: any Signer
    public let kx: any KeyAgreer
    public var publicKeys: DevicePublicKeys { DevicePublicKeys(sig: sig.publicKey, kx: kx.publicKey) }
}

/// Custody of the device keys. There is deliberately no way to read a private key back.
public protocol DeviceKeyCustody: Sendable {
    /// Create both keys. Throws `alreadyExists` rather than replacing a key.
    func create(realm: Realm) throws -> DeviceIdentity
    /// Throws `missing`, `orphaned` or `locked` when the identity is not usable.
    func load(realm: Realm) throws -> DeviceIdentity
    func publicKeys(realm: Realm) throws -> DevicePublicKeys
    func delete(realm: Realm) throws
    func status(realm: Realm) -> CustodyStatus
}

enum KeyPurpose {
    static let sig = "dk_sig"
    static let kx = "dk_kx"
}

/// Shared storage logic: two blobs in the `.keys` group, restored by backend-specific closures.
struct KeyBlobStore: Sendable {
    let vault: SecretVault

    init(vault: SecretVault) { precondition(vault.group == .keys, "device keys belong in the .keys group"); self.vault = vault }

    func id(_ realm: Realm, _ purpose: String) -> SecretID { try! SecretID(realm: realm, purpose: purpose) }

    func read(_ realm: Realm, _ purpose: String) throws -> Data? {
        do { return try vault.get(id(realm, purpose)) }
        catch VaultError.notFound { return nil }
        catch VaultError.locked { throw CustodyError.locked }
        catch let e as VaultError { throw CustodyError.vault(e) }
    }

    func write(_ realm: Realm, _ purpose: String, _ data: Data) throws {
        do { try vault.put(data, for: id(realm, purpose)) }
        catch VaultError.locked { throw CustodyError.locked }
        catch let e as VaultError { throw CustodyError.vault(e) }
    }

    /// Both blobs, or the right error: `missing` (neither), `orphaned` (one), `locked`.
    func readBoth(_ realm: Realm) throws -> (sig: Data, kx: Data) {
        let s = try read(realm, KeyPurpose.sig), k = try read(realm, KeyPurpose.kx)
        switch (s, k) {
        case let (s?, k?): return (s, k)
        case (nil, nil): throw CustodyError.missing
        default: throw CustodyError.orphaned
        }
    }

    func exists(_ realm: Realm) throws -> Bool {
        try read(realm, KeyPurpose.sig) != nil || read(realm, KeyPurpose.kx) != nil
    }

    func deleteBoth(_ realm: Realm) throws {
        do {
            try vault.delete(id(realm, KeyPurpose.sig))
            try vault.delete(id(realm, KeyPurpose.kx))
        } catch VaultError.locked { throw CustodyError.locked }
        catch let e as VaultError { throw CustodyError.vault(e) }
    }

    func status(_ realm: Realm, restore: (Data, Data) throws -> Void) -> CustodyStatus {
        do {
            let (s, k) = try readBoth(realm)
            do { try restore(s, k) } catch { return .orphaned }
            return .present
        } catch CustodyError.locked { return .locked }
        catch CustodyError.missing { return .missing }
        catch { return .orphaned }
    }
}

public extension DeviceKeyCustody {
    func publicKeys(realm: Realm) throws -> DevicePublicKeys { try load(realm: realm).publicKeys }
}
