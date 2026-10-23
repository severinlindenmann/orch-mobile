import Foundation
import OrchClient
import OrchCustody
import OrchPush
import UserNotifications

/// The one hub storage of this process (design B6): the keychain custody, the cache and the resumable wipe over them. Not DEBUG-only: Reset
/// this iPhone must be able to remove a hub pairing in every build. The pairing UI (`HubRuntime`) builds on the same objects, so Reset and the
/// hub screens never see two different stores.
enum HubStorage {
    /// The keychain of the app (an in-memory vault when the Simulator build is unsigned).
    static let backend: any VaultBackend = KeychainBackend.fromBundle() ?? InMemoryVaultBackend()
    static let custody = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
    static let cache = FileHubCache(directory: cacheDirectory)
    /// The App Group's push directory (shared with the extension); an unsigned Simulator build has none and uses a private one.
    static var pushDirectory: URL {
        PushGroup.pushDir() ?? FileManager.default.temporaryDirectory.appendingPathComponent("orch-hub-push", isDirectory: true)
    }

    /// The wipe intent lives in `UserDefaults` (a hub id and a phase number, no secret). The vault sweep already removes every `hub.*` item:
    /// the keys, token, record, push key, `hub.push.material` and `hub.<id>.push-state` (the `issued_ms` counter). `steps` clear what lives
    /// outside the vault: the extension's replay state (the whole `state/hub/` folder) and the hub's delivered notifications. B3's Face ID
    /// baseline joins this list.
    static let wipe = HubWipe(custody: custody, cache: cache, journal: DefaultsHubWipeJournal(),
                         steps: [{ _ in HubPushIntake(pushDir: pushDirectory).purgeAll() }, { _ in await removeDeliveredHubNotifications() }])

    /// The hub's own area for its cache: never inside a direct-mode workspace container.
    static var cacheDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("OrchHub", isDirectory: true)
    }

    /// The two fixed lines the extension shows for a hub hint (`PushPresentation.hubHint`): nothing else says "hub", so a delivered notification
    /// with one of these bodies is a hub notification.
    static func isHubHint(body: String) -> Bool {
        body == "A signature request is waiting" || body == "Something needs you"
    }

    /// Removes the hub's delivered notifications (best effort, bounded: a wedged notification daemon never holds a wipe).
    static func removeDeliveredHubNotifications() async {
        let center = UNUserNotificationCenter.current()
        let ids = await withTaskGroup(of: [String]?.self) { group -> [String] in
            group.addTask { await center.deliveredNotifications().filter { isHubHint(body: $0.request.content.body) }.map(\.request.identifier) }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }
}
