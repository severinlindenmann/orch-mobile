import Foundation

/// The two storage realms (decision P3). Every key name carries one, so Demo can never address a live item.
public enum Realm: String, Sendable, CaseIterable, Hashable {
    case live
    case demo
}

/// Which keychain group an item lives in (decision A9).
public enum KeychainGroup: String, Sendable, CaseIterable, Hashable {
    /// App only: device keys, cert, WK epochs, pairing secrets, sessions. `WhenPasscodeSetThisDeviceOnly`.
    case keys
    /// App and notification extension: `K_push`, pinned `wsk_pub`, workspace name. `AfterFirstUnlockThisDeviceOnly`.
    case push

    /// Group name without the team prefix (the entitlement is `$(AppIdentifierPrefix)io.severin.orch.<suffix>`).
    public var name: String { "io.severin.orch.\(rawValue)" }

    /// The data-protection class of every item in the group. Keys never leave the device and are unusable
    /// without a passcode; push keys must work for a notification arriving while the phone is locked.
    public var accessibility: Accessibility {
        switch self {
        case .keys: .whenPasscodeSetThisDeviceOnly
        case .push: .afterFirstUnlockThisDeviceOnly
        }
    }
}

public enum Accessibility: String, Sendable, Hashable {
    case whenPasscodeSetThisDeviceOnly
    case afterFirstUnlockThisDeviceOnly
}

/// The tag of one stored secret: `(realm, ws?, purpose)`. Encoded into `kSecAttrService` / `kSecAttrAccount`.
///
/// Both parts are strict ASCII so that Swift's canonical-equivalence `String ==` and the keychain's byte
/// comparison agree: `ws` is 32 lowercase hex characters (a 16-byte workspace id), `purpose` is 1 to 64 characters
/// of `[a-z0-9._-]`. A workspace id can therefore never equal the "no workspace" marker `-`.
public struct SecretID: Hashable, Sendable {
    public static let wsLength = 32
    public static let maxPurposeLength = 64

    public let realm: Realm
    public let ws: String?
    public let purpose: String

    public init(realm: Realm, ws: String? = nil, purpose: String) throws {
        guard Self.validPurpose(purpose), ws.map(Self.validWS) ?? true else { throw VaultError.badName }
        self.realm = realm; self.ws = ws; self.purpose = purpose
    }

    static func validWS(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return u.count == wsLength && u.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    static func validPurpose(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return (1...maxPurposeLength).contains(u.count) && u.allSatisfy {
            ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    /// `orch:<realm>:<32 hex>` for a workspace item, `orch:<realm>:-` for a realm-level item.
    var service: String { "orch:\(realm.rawValue):\(ws ?? "-")" }
    var account: String { purpose }

    /// Parses a stored tag. Returns nil unless re-encoding gives back exactly the same bytes.
    init?(service: String, account: String) {
        let parts = service.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "orch", let r = Realm(rawValue: String(parts[1])) else { return nil }
        let w: String? = parts[2] == "-" ? nil : String(parts[2])
        guard let id = try? SecretID(realm: r, ws: w, purpose: account),
              Array(id.service.utf8) == Array(service.utf8), Array(id.account.utf8) == Array(account.utf8) else { return nil }
        self = id
    }
}

/// Why a vault operation failed. "Locked" and "not found" are different on purpose (challenge C4): a key that is
/// merely unreachable while the phone is locked is not lost and must not trigger a wipe.
public enum VaultError: Error, Equatable, Sendable {
    case notFound
    /// Interaction not allowed: device locked / data not yet available. Temporary.
    case locked
    case badName
    case unexpected(Int32)
}
