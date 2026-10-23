import Foundation
import OrchClient
import OrchCustody

/// The one hub storage of this process (design B6): the keychain custody, the cache and the resumable wipe over them. Not DEBUG-only: Reset
/// this iPhone must be able to remove a hub pairing in every build. The pairing UI (`HubRuntime`) builds on the same objects, so Reset and the
/// hub screens never see two different stores.
enum HubStorage {
    /// The keychain of the app (an in-memory vault when the Simulator build is unsigned).
    static let backend: any VaultBackend = KeychainBackend.fromBundle() ?? InMemoryVaultBackend()
    static let custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
    static let cache = FileHubCache(directory: cacheDirectory)
    /// HOOK for B4 (orch-mobile#103, not merged when B6 was written): its `.push` item `hub.push.material` is already removed by the
    /// vault sweep (`HubKeyCustody.unkeyedHubItems`). Still to add to `steps` once B4 is in: `HubPushIntake.purge` (the replay state) and
    /// the saved `issued_ms` counter. B3's Face ID baseline joins the same list.
    /// The wipe intent lives in `UserDefaults` (a hub id and a phase number, no secret). The cleanup steps of the other tasks (the replay rows
    /// and notifications of B4, the Face ID baseline of B3) are added to this list by those tasks.
    static let wipe = HubWipe(custody: custody, cache: cache, journal: DefaultsHubWipeJournal(), steps: [])

    /// The hub's own area for its cache: never inside a direct-mode workspace container.
    static var cacheDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("OrchHub", isDirectory: true)
    }
}
