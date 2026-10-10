import CryptoKit
import Foundation
import OrchProtocol

public enum CustodyError: Error, Equatable, Sendable {
    /// Temporarily unreachable (device locked). Not a loss: do not wipe anything (challenge C4).
    case locked
    /// No device identity in this realm. Callers that expected one fail closed.
    case missing
    /// Only one of the two keys exists, or a stored key is confirmed undecodable. Fail closed.
    case orphaned
    case alreadyExists
    /// No Secure Enclave on a build that requires one. Never falls back to software.
    case unavailable
    case vault(VaultError)
}

/// `present`: usable now. `locked`: exists but unreachable for now. `unavailable`: the state cannot be determined
/// (unknown keychain error, key blob that cannot be restored yet): refuse to sign, but never clean up. `missing`
/// and `orphaned` fail closed: the caller cleans dependent stores and push keys. `locked` and `unavailable` never do.
/// `orphaned` is only reported for exactly one blob present or a confirmed decode failure.
public enum CustodyStatus: Equatable, Sendable {
    case present, locked, unavailable, missing, orphaned
    public var failsClosed: Bool { self == .missing || self == .orphaned }
}

public struct DevicePublicKeys: Equatable, Sendable {
    public let sig: SigningPublicKey
    public let kx: AgreementPublicKey
}

/// `dk_sig` (signing) and `dk_kx` (key agreement): two P-256 keys, one device identity (decision A6).
public struct DeviceIdentity: Sendable {
    package let sig: any Signer
    package let kx: any KeyAgreer
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

    /// Add-only: never replaces a stored key. `alreadyExists` if the item is there.
    func writeNew(_ realm: Realm, _ purpose: String, _ data: Data) throws {
        do { try vault.putNew(data, for: id(realm, purpose)) }
        catch VaultError.duplicate { throw CustodyError.alreadyExists }
        catch VaultError.locked { throw CustodyError.locked }
        catch let e as VaultError { throw CustodyError.vault(e) }
    }

    /// Serializes `create` inside the process, so two racing creates cannot interleave their two writes.
    static let createLock = NSLock()

    /// Add both blobs or neither. Only items this call added are rolled back.
    func createPair(_ realm: Realm, sig: Data, kx: Data) throws {
        Self.createLock.lock(); defer { Self.createLock.unlock() }
        guard try !exists(realm) else { throw CustodyError.alreadyExists }
        try writeNew(realm, KeyPurpose.sig, sig)
        do { try writeNew(realm, KeyPurpose.kx, kx) }
        catch {
            try? vault.delete(id(realm, KeyPurpose.sig))
            throw error
        }
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

    /// `restore` throws `CustodyError.orphaned` for a confirmed decode failure; any other error means "cannot tell".
    func status(_ realm: Realm, restore: (Data, Data) throws -> Void) -> CustodyStatus {
        do {
            let (s, k) = try readBoth(realm)
            do { try restore(s, k) }
            catch CustodyError.orphaned { return .orphaned }
            catch CustodyError.locked { return .locked }
            catch { return .unavailable }
            return .present
        } catch CustodyError.locked { return .locked }
        catch CustodyError.missing { return .missing }
        catch CustodyError.orphaned { return .orphaned }
        catch { return .unavailable }
    }
}

public extension DeviceKeyCustody {
    func publicKeys(realm: Realm) throws -> DevicePublicKeys { try load(realm: realm).publicKeys }
}
