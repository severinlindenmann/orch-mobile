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
    case otherWorkspace = "other_workspace"
    case staleList = "stale_list"
    case badEpoch = "bad_epoch"
    case rotationRequired = "rotation_required"
    case scopeExceeded = "scope_exceeded"
    case missingGrant = "missing_grant"
    case delegationMismatch = "delegation_mismatch"
    case staleCard = "stale_card"
    case wskChanged = "wsk_changed"
    case delegationChanged = "delegation_changed"
    case wxkChangedWithoutVersion = "wxk_changed_without_version"
    case badWxkVersion = "bad_wxk_version"
    case notForThisDevice = "not_for_this_device"
    case expired
    case replayed
    case requestOpen = "request_open"
    case alreadySigned = "already_signed"
    case rejected
    case unknownRequest = "unknown_request"
    /// Local (never on the wire): a snapshot that contradicts the one already accepted under the same sequence.
    case conflictingSnapshot = "conflicting_snapshot"
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
