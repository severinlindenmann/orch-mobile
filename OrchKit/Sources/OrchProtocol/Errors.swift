import Foundation

/// Refusal and failure codes of protocol v2 that the pure functions in this module can produce
/// (section 14). Raw values are the wire spelling.
public enum Refusal: String, Error, Sendable, Equatable {
    case malformed
    case badSignature = "bad_signature"
    case certInvalid = "cert_invalid"
    case certExpired = "cert_expired"
    case revoked
    case otherPerson = "other_person"
    case wrongSuite = "wrong_suite"
}

/// Failures of the byte-level primitives (encodings, keys, AEAD).
public enum CryptoFailure: Error, Sendable, Equatable {
    case invalidKey
    case invalidLength
    case authenticationFailed
    case degenerateSharedSecret
    case unsupported
}

/// Strict JSON parse failure (section 2.3). `why` is for diagnostics only.
public struct JSONError: Error, Equatable, Sendable { public let why: String }
