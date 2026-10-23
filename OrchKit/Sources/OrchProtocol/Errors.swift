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
    /// Q10: a list at the relay's current epoch whose `wk_commit` differs from the stored list's (409 at the relay).
    case wkCommitChanged = "wk_commit_changed"
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
    /// Local alarm (never on the wire, Q10): two `WSK`-verified member lists at one epoch commit to different `WK`s. One `WK`
    /// per epoch, ever: only a host that equivocates (or a stolen `WSK`) can sign both.
    case wkCommitConflict = "wk_commit_conflict"
    /// Local (G2b D4): a key for an epoch above the head list's, or before any verified list. Epochs move only on a verified list.
    case futureEpoch = "future_epoch"
    // Hub contract (orch-hub protocol section 14, V3 stream B). Wire spellings.
    case otherHub = "other_hub"
    case hubIDMismatch = "hub_id_mismatch"
    case staleOpCert = "stale_op_cert"
    case devRefused = "dev_refused"
    case devMismatch = "dev_mismatch"
    /// Local (phone, never on the wire): the hub's signed API origin is not the pairing link's. Nothing was sent.
    case otherOrigin = "other_origin"
    case otherUser = "other_user"
    case staleTimestamp = "stale_timestamp"
    case challengeInvalid = "challenge_invalid"
    case factorMismatch = "factor_mismatch"
    /// Custodial signing (protocol 8.4): the hub's prepared request is not the one the phone computed or asked for. Nothing is signed.
    case eventChanged = "event_changed"
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
