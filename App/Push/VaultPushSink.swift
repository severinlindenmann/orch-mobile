import Foundation
import OrchCustody
import OrchPush

/// Adapts the custody vault of the `.push` group to what `PushMaterialPublisher` writes. The group is fixed here: this
/// type cannot be pointed at `.keys`, so push material can never land next to device keys or WK.
///
/// A sink is bound to ONE realm view (`RealmVault`). A Live sink comes from `LiveRuntime.makePushSink()`, whose view runs every write
/// inside the realm's generation fence, so push material of a finished realm can never land next to its successor's. The unfenced
/// `init(backend:)` exists for the DEBUG push harness only.
struct VaultPushSink: PushMaterialSink {
    let vault: RealmVault

    init(vault: RealmVault) { self.vault = vault }

    #if DEBUG
    init(backend: any VaultBackend, realm: Realm = .live) { vault = SecretVault(group: .push, backend: backend).scoped(to: realm) }
    #endif

    private func check(_ realm: String) throws {
        guard realm == vault.realm.rawValue else { throw VaultError.badName }
    }

    func put(_ data: Data, realm: String, ws: String, purpose: String) throws {
        try check(realm)
        try vault.put(data, ws: ws, purpose: purpose)
    }

    func delete(realm: String, ws: String, purpose: String) throws {
        try check(realm)
        try vault.delete(ws: ws, purpose: purpose)
    }
}

enum PushGroup {
    static let identifier = "group.io.severin.orch"
    /// `<group.io.severin.orch>/push`: the directory `StoreLayout.pushDir` names; nil without the entitlement.
    static func pushDir() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?.appendingPathComponent("push", isDirectory: true)
    }
}
