#if DEBUG
import Foundation
import OrchClient
import OrchCustody
import OrchStore

/// DEBUG UI tests only (`--ui-testing --live-test-relay`): Live on a temporary disk with an in-memory keychain behind a relay that never
/// answers. Release has no such code, and `scripts/check-no-test-hooks.sh` fails a shipped target that names the transport hook.
enum LiveUITestSupport {
    static func makeStorage() -> () throws -> LiveStorage {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("orch-live-ui-" + UUID().uuidString)
        let backend = InMemoryVaultBackend()
        return {
            let layout = try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                                         shareGroupRoot: base.appendingPathComponent("share"), realm: Realm.live.rawValue)
            return LiveStorage(layout: layout, backend: backend, lock: SimulatedLock(), clock: ContinuousClock(), wall: SystemWallClock(),
                               entropy: SystemEntropy(), makeTransport: { try LiveTransport.unreachableForUITests(context: $0) },
                               purgeNotifications: { _ in })
        }
    }
}
#endif
