import Foundation
import OrchCustody
import OrchPush

/// Adapts the custody vault of the `.push` group to what `PushMaterialPublisher` writes. The group is fixed here: this
/// type cannot be pointed at `.keys`, so push material can never land next to device keys or WK.
struct VaultPushSink: PushMaterialSink {
    let vault: SecretVault

    init(backend: any VaultBackend) { vault = SecretVault(group: .push, backend: backend) }

    private func id(_ realm: String, _ ws: String, _ purpose: String) throws -> SecretID {
        guard let r = Realm(rawValue: realm) else { throw VaultError.badName }
        return try SecretID(realm: r, ws: ws, purpose: purpose)
    }

    func put(_ data: Data, realm: String, ws: String, purpose: String) throws {
        try vault.put(data, for: try id(realm, ws, purpose))
    }

    func delete(realm: String, ws: String, purpose: String) throws {
        try vault.delete(try id(realm, ws, purpose))
    }
}

enum PushGroup {
    static let identifier = "group.io.severin.orch"
    /// `<group.io.severin.orch>/push`: the directory `StoreLayout.pushDir` names; nil without the entitlement.
    static func pushDir() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?.appendingPathComponent("push", isDirectory: true)
    }
}
