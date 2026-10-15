import Foundation
import OrchCustody
import OrchProtocol
import OrchStore

/// The realm-wide local wipe of a Live realm ("Leave Live", "Reset this iPhone", or an interrupted one completed at the next launch).
///
/// It is the realm's own teardown path: it holds UNFENCED vault views and an index whose wipe-type writes never use the fence, so it
/// works after the realm context was invalidated. It is deliberately not driven only by the index: the staged items of an invalidated
/// join (its pairing record, grants, new device keys) are in the vault but in no index row, so the vault groups are wiped by realm.
///
/// Every step is idempotent and a failing step does not stop the others; the first error is rethrown at the end, so a retry (or the next
/// launch, which starts from nothing but the persisted gate) runs the same steps again:
///   1. every workspace in the index through `LocalWipe` (tombstoned, phase-persisted, resumable), then any wipe left half-done;
///   2. device keys of the realm (custody) and every vault group, by realm;
///   3. only when 1 succeeded: the index is closed and the realm directory removed;
///   4. the realm's data in both App Groups (push state, staged and quarantined share jobs).
/// Tombstone coordination files are kept on purpose (a burnt generation stays burnt; `WorkspaceIndex.nextGeneration` rejoins above them).
public final class RealmWipe: @unchecked Sendable {
    public struct Config: Sendable {
        public var realm: Realm
        public var layout: StoreLayout
        public var custody: any DeviceKeyCustody
        /// UNFENCED vaults (`.keys`, `.push`).
        public var vaults: [SecretVault]
        public var hooks: any WipeHooks
        public init(realm: Realm, layout: StoreLayout, custody: any DeviceKeyCustody, vaults: [SecretVault], hooks: any WipeHooks = NoWipeHooks()) {
            self.realm = realm; self.layout = layout; self.custody = custody; self.vaults = vaults; self.hooks = hooks
        }
    }

    public let config: Config
    private let lock = NSLock()
    /// Set once the provided index was closed: a retry must not use that object again (its handle is gone), so it opens the persisted
    /// index itself if the realm directory is still there.
    private var indexClosed = false
    public init(_ config: Config) { self.config = config }

    /// - Parameter index: the realm's open index (so open containers are suspended by its registry). It is closed on success. Pass nil
    ///   when no runtime is left (a wipe at the next launch): an index is then opened for the wipe if the realm has one.
    public func run(index provided: WorkspaceIndex?) async throws {
        let c = config
        let index = lock.withLock { indexClosed } ? nil : provided
        guard c.layout.realm == c.realm.rawValue else { throw RealmViolation.wrongStore }
        let fm = FileManager.default
        var firstError: (any Error)?
        func attempt(_ body: () async throws -> Void) async {
            do { try await body() } catch { if firstError == nil { firstError = error } }
        }
        var wiped = false
        var opened: WorkspaceIndex?
        await attempt {
            var idx = index
            if idx == nil, fm.fileExists(atPath: c.layout.indexURL.path) {
                idx = try await WorkspaceIndex(layout: c.layout)      // no fence: wipe-type writes never use it
                opened = idx
            }
            if let idx {
                let wipe = LocalWipe(index: idx, hooks: c.hooks)
                for w in try await idx.workspaces() { try await wipe.wipe(ws: w.ws, generation: w.generation) }
                try await wipe.resumePendingWipes()
            }
            wiped = true
        }
        await attempt { do { try c.custody.delete(realm: c.realm) } catch CustodyError.missing {} catch CustodyError.orphaned {} }
        for v in c.vaults { await attempt { try v.wipe(realm: c.realm) } }
        if wiped {
            await attempt {
                await index?.close()
                lock.withLock { if index != nil { indexClosed = true } }
                await opened?.close()
                if fm.fileExists(atPath: c.layout.realmDir.path) { try fm.removeItem(at: c.layout.realmDir) }
            }
        }
        for dir in [c.layout.pushDir.appendingPathComponent("state").appendingPathComponent(c.realm.rawValue, isDirectory: true),
                    c.layout.shareDir.appendingPathComponent("staging").appendingPathComponent(c.realm.rawValue, isDirectory: true),
                    c.layout.shareDir.appendingPathComponent("quarantine").appendingPathComponent(c.realm.rawValue, isDirectory: true)] {
            await attempt { if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) } }
        }
        if let e = firstError { throw e }
    }
}
