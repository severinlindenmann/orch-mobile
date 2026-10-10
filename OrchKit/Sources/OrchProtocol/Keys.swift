import CryptoKit
import Foundation

/// A suite-2 signing public key: 65-byte uncompressed point, checked to be on the curve (section 1.2).
public struct SigningPublicKey: Hashable, Sendable {
    public let x963: Data
    let key: P256.Signing.PublicKey

    public init(x963: Data) throws {
        guard x963.count == Suite2.publicKeyLength, x963.first == 0x04 else { throw CryptoFailure.invalidKey }
        guard let k = try? P256.Signing.PublicKey(x963Representation: x963) else { throw CryptoFailure.invalidKey }
        self.x963 = Data(x963); self.key = k
    }

    public static func == (a: Self, b: Self) -> Bool { a.x963 == b.x963 }
    public func hash(into h: inout Hasher) { h.combine(x963) }
}

/// A suite-2 key-agreement public key: 65-byte uncompressed point, checked to be on the curve.
public struct AgreementPublicKey: Hashable, Sendable {
    public let x963: Data
    let key: P256.KeyAgreement.PublicKey

    public init(x963: Data) throws {
        guard x963.count == Suite2.publicKeyLength, x963.first == 0x04 else { throw CryptoFailure.invalidKey }
        guard let k = try? P256.KeyAgreement.PublicKey(x963Representation: x963) else { throw CryptoFailure.invalidKey }
        self.x963 = Data(x963); self.key = k
    }

    public static func == (a: Self, b: Self) -> Bool { a.x963 == b.x963 }
    public func hash(into h: inout Hasher) { h.combine(x963) }
}

/// Anything that can produce suite-2 signatures: a software key here, a Secure Enclave key in OrchCustody.
/// The private scalar never crosses this protocol.
public protocol Signer: Sendable {
    var publicKey: SigningPublicKey { get }
    /// Raw 64-byte `r || s` over `message` (ECDSA P-256 with SHA-256, IEEE P1363).
    func rawSignature(over message: Data) throws -> Data
}

/// Anything that can do ECDH P-256 with a peer key: software or Secure Enclave.
public protocol KeyAgreer: Sendable {
    var publicKey: AgreementPublicKey { get }
    /// The 32-byte x-coordinate. All-zero output must be refused by callers (`Sealing` does).
    func sharedSecret(with peer: AgreementPublicKey) throws -> Data
}

/// A software signing key. Generates a fresh key by default; there is no public way to import a raw scalar.
public struct SoftwareSigner: Signer {
    let key: P256.Signing.PrivateKey
    public let publicKey: SigningPublicKey

    public init() {
        key = P256.Signing.PrivateKey()
        publicKey = try! SigningPublicKey(x963: key.publicKey.x963Representation)
    }

    /// TEST-ONLY: import a raw 32-byte scalar. Internal on purpose; reachable from tests through `@testable`.
    init(testScalar: Data) throws {
        key = try P256.Signing.PrivateKey(rawRepresentation: testScalar)
        publicKey = try SigningPublicKey(x963: key.publicKey.x963Representation)
    }

    public func rawSignature(over message: Data) throws -> Data {
        try key.signature(for: message).rawRepresentation
    }
}

public struct SoftwareKeyAgreer: KeyAgreer {
    let key: P256.KeyAgreement.PrivateKey
    public let publicKey: AgreementPublicKey

    public init() {
        key = P256.KeyAgreement.PrivateKey()
        publicKey = try! AgreementPublicKey(x963: key.publicKey.x963Representation)
    }

    /// TEST-ONLY: import a raw 32-byte scalar (also used to reproduce the vectors' fixed ephemeral keys).
    init(testScalar: Data) throws {
        key = try P256.KeyAgreement.PrivateKey(rawRepresentation: testScalar)
        publicKey = try AgreementPublicKey(x963: key.publicKey.x963Representation)
    }

    public func sharedSecret(with peer: AgreementPublicKey) throws -> Data {
        try key.sharedSecretFromKeyAgreement(with: peer.key).withUnsafeBytes { Data($0) }
    }
}

extension SymmetricKey {
    /// The raw bytes, for persisting a key (WK, PVK, ...) in custody storage.
    public var rawBytes: Data { withUnsafeBytes { Data($0) } }
}

/// ECDSA over P-256, raw `r || s` (section 1.2, suite 2).
public enum Signature {
    static let order: [UInt8] = Array(Hex.decode("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")!)

    static func lessThanOrder(_ x: ArraySlice<UInt8>) -> Bool { x.lexicographicallyPrecedes(order) }

    /// Section 1.2: 64 bytes, `r` and `s` in `1 ... n-1`, valid on-curve key, then ECDSA/SHA-256. A high-`s` twin
    /// verifies (vector `high_s_twin_verifies`): ECDSA is malleable, so no signature is ever used as an identifier.
    public static func verify(_ key: SigningPublicKey, signature: Data, message: Data) -> Bool {
        guard signature.count == Suite2.signatureLength else { return false }
        let bytes = Array(signature)
        for half in [bytes[0..<32], bytes[32..<64]] {
            if half.allSatisfy({ $0 == 0 }) || !lessThanOrder(half) { return false }
        }
        guard let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.key.isValidSignature(sig, for: message)
    }

    /// Verify over `label || message` (domain separation, section 3).
    public static func verify(_ key: SigningPublicKey, signature: Data, label: String, message: Data) -> Bool {
        verify(key, signature: signature, message: Data(label.utf8) + message)
    }

    /// Sign `label || message`.
    public static func sign(_ signer: some Signer, label: String, message: Data) throws -> Data {
        let sig = try signer.rawSignature(over: Data(label.utf8) + message)
        guard sig.count == Suite2.signatureLength else { throw CryptoFailure.invalidLength }
        return sig
    }
}
