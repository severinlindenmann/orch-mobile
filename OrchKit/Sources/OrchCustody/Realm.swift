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
public struct SecretID: Hashable, Sendable {
    public let realm: Realm
    public let ws: String?
    public let purpose: String

    public init(realm: Realm, ws: String? = nil, purpose: String) throws {
        guard Self.valid(purpose), ws.map(Self.valid) ?? true else { throw VaultError.badName }
        self.realm = realm; self.ws = ws; self.purpose = purpose
    }

    static func valid(_ s: String) -> Bool { !s.isEmpty && !s.contains(":") && !s.contains("\0") }

    /// `orch:<realm>:<ws or ->`
    var service: String { "orch:\(realm.rawValue):\(ws ?? "-")" }
    var account: String { purpose }

    init?(service: String, account: String) {
        let parts = service.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "orch", let r = Realm(rawValue: String(parts[1])), Self.valid(account),
              !parts[2].isEmpty else { return nil }
        self.realm = r
        self.ws = parts[2] == "-" ? nil : String(parts[2])
        self.purpose = account
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
