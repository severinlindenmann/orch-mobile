import Foundation
import OrchProtocol
import Security

/// The notification extension's tiny keychain reader: read-only, no signing, no network. It addresses the `.push`
/// access group explicitly and reads the items `PushMaterialPublisher` wrote, tagged exactly like OrchCustody's
/// `SecretID` (`service = orch:<realm>:<ws>`, `account = <purpose>`); a test in the app target pins the two together.
public struct KeychainPushMaterialSource: PushMaterialSource {
    public static let groupSuffix = "io.severin.orch.push"
    let accessGroup: String?

    /// `prefix` is the team id with its trailing dot (`"77D4THRYUN."`); same Info.plist key as custody.
    public init?(accessGroupPrefix prefix: String) {
        guard Self.validPrefix(prefix) else { return nil }
        accessGroup = prefix + Self.groupSuffix
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> KeychainPushMaterialSource? {
        (bundle.object(forInfoDictionaryKey: "OrchAppIdentifierPrefix") as? String).flatMap { KeychainPushMaterialSource(accessGroupPrefix: $0) }
    }

    #if DEBUG
    /// TEST-ONLY: no access group in the query (the app's default group, as custody's `unscopedForTests`).
    public init(unscopedForTests: Void) { accessGroup = nil }
    #endif

    static func validPrefix(_ p: String) -> Bool {
        let u = Array(p.utf8)
        return u.count > 1 && u.last == 0x2E && u.dropLast().allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
        }
    }

    public func loadAll(realm: String) throws -> [ID16: PushMaterial] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: PushMaterial.purpose,
                                  kSecAttrSynchronizable: false, kSecReturnAttributes: true, kSecReturnData: true,
                                  kSecMatchLimit: kSecMatchLimitAll]
        if let g = accessGroup { q[kSecAttrAccessGroup] = g }
        #if os(macOS)
        q[kSecUseDataProtectionKeychain] = true
        #endif
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [:] }
        if status == errSecInteractionNotAllowed { throw PushMaterialError.locked }
        guard status == errSecSuccess else { throw PushMaterialError.unavailable(status) }
        let prefix = "orch:\(realm):"
        var result: [ID16: PushMaterial] = [:]
        for row in out as? [[String: Any]] ?? [] {
            guard let service = row[kSecAttrService as String] as? String, service.hasPrefix(prefix),
                  let ws = ID16(hex: String(service.dropFirst(prefix.count))), ws.hex == String(service.dropFirst(prefix.count)),
                  let data = row[kSecValueData as String] as? Data,
                  let material = try? PushMaterial.decode(data) else { continue }
            result[ws] = material
        }
        return result
    }
}
