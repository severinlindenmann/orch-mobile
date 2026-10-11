import Foundation
import OrchCoordination

/// Hooks for the parts of A11 that do not live in this module (keychain, notifications, routes, writers).
/// All default to no-ops; OrchClient supplies the real ones.
public protocol WipeHooks: Sendable {
    /// Phase 2: disable share target and routes, cancel and drain in-app writers, close open containers.
    func quiesce(realm: String, ws: String) async throws
    /// Phase 3: delete keychain items (both groups).
    func purgeSecrets(realm: String, ws: String) async throws
    /// Phase 3: remove pending and delivered notifications.
    func purgeNotifications(realm: String, ws: String) async throws
}

public extension WipeHooks {
    func quiesce(realm: String, ws: String) async throws {}
    func purgeSecrets(realm: String, ws: String) async throws {}
    func purgeNotifications(realm: String, ws: String) async throws {}
}

public struct NoWipeHooks: WipeHooks { public init() {} }

public enum WipeError: Error, Sendable { case partial([String]) }

/// Store and file part of A11 (1)-(4). Each phase is idempotent and its completion is persisted in the
/// index, so `resumePendingWipes()` finishes an interrupted wipe. Network deregistration (5) is not here.
public final class LocalWipe: Sendable {
    public static let donePhase = 4
    let index: WorkspaceIndex
    let hooks: any WipeHooks
    let afterPhase: (@Sendable (Int) throws -> Void)?

    /// - Parameter afterPhase: test seam called after a phase is persisted; throwing simulates a crash.
    public init(index: WorkspaceIndex, hooks: any WipeHooks = NoWipeHooks(), afterPhase: (@Sendable (Int) throws -> Void)? = nil) {
        self.index = index; self.hooks = hooks; self.afterPhase = afterPhase
    }

    /// Starts (or continues) a wipe of `ws` at `generation` and runs it to completion.
    public func wipe(ws: String, generation: Int64) async throws {
        try StoreLayout.validate(ws: ws)
        // Phase 1: index record first (it drives resume), then both coordination files.
        let g = try await index.recordTombstone(ws: ws, generation: generation)
        try await run(ws: ws, generation: g, from: 0)
    }

    /// Finishes every tombstone whose phase is below done. Returns the workspaces resumed.
    @discardableResult
    public func resumePendingWipes() async throws -> [String] {
        var resumed: [String] = []
        var errors: [String] = []
        // A failing republish must not stop wipes that are past phase 1; run() retries phase 1 itself.
        do { try await index.republishTombstones() } catch { errors.append("republish: \(error)") }
        for t in try await index.tombstones() where t.phase < Self.donePhase {
            do {
                try await run(ws: t.record.ws, generation: t.record.generation, from: t.phase)
                resumed.append(t.record.ws)
            } catch { errors.append("\(t.record.ws)@\(t.record.generation): \(error)") }
        }
        if !errors.isEmpty { throw WipeError.partial(errors) }
        return resumed
    }

    /// Second cleanup pass after wipe (late writers, notifications handed to the OS in the meantime).
    public func cleanupPass(ws: String) async throws {
        let layout = index.layout
        await index.containers.suspendAll(ws: ws)
        try await purgeFiles(ws: ws)
        try await hooks.purgeNotifications(realm: layout.realm, ws: ws)
        try? FileManager.default.removeItem(at: layout.wsDir(ws))
    }

    private func run(ws: String, generation: Int64, from: Int) async throws {
        let layout = index.layout
        let realm = layout.realm
        if from < 1 {
            // Publish every index tombstone, not just this one: repairs a coordination file that was moved
            // replaced as corrupt (copied aside, never left missing), or missed in an earlier crash between the two App Group writes (the index is
            // authoritative; until phase 1 completes an extension on the stale side may still publish).
            var records = try await index.tombstones().map(\.record)
            records.append(TombstoneRecord(realm: realm, ws: ws, generation: generation))
            try layout.tombstones.republish(complete: records)
            try await finish(1, ws, generation)
        }
        if from < 2 {
            try await hooks.quiesce(realm: realm, ws: ws)
            await index.containers.suspendAll(ws: ws)
            try await index.removeWorkspaceRow(ws: ws)
            try await finish(2, ws, generation)
        }
        if from < 3 {
            await index.containers.suspendAll(ws: ws)  // also covers a wipe resumed in a fresh process
            var errors: [String] = []
            do { try await hooks.purgeSecrets(realm: realm, ws: ws) } catch { errors.append("secrets: \(error)") }
            do { try await purgeFiles(ws: ws) } catch { errors.append("files: \(error)") }
            do { try await hooks.purgeNotifications(realm: realm, ws: ws) } catch { errors.append("notifications: \(error)") }
            if !errors.isEmpty { throw WipeError.partial(errors) }
            try await finish(3, ws, generation)
        }
        if from < 4 {
            let dir = try layout.wsDir(ws)
            if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
            try await finish(4, ws, generation)
        }
    }

    private func finish(_ phase: Int, _ ws: String, _ generation: Int64) async throws {
        try await index.setWipePhase(ws: ws, generation: generation, phase: phase)
        try afterPhase?(phase)
    }

    /// Plaintext, previews, SQLite main + sidecars, staged and quarantined jobs.
    private func purgeFiles(ws: String) async throws {
        let layout = index.layout
        let fm = FileManager.default
        for f in StoreLayout.sqliteFiles(try layout.wsDatabaseURL(ws)) where fm.fileExists(atPath: f.path) { try fm.removeItem(at: f) }
        let lock = CoordinationFiles.replayLockURL(pushDir: layout.pushDir, realm: layout.realm, workspace: ws)
        try CoordinationFiles.makeDir(lock.deletingLastPathComponent())
        // Never block the cooperative pool: a busy replay transaction leaves phase 3 pending for retry.
        guard try CoordinationFiles.withFlock(lock.path, blocking: false, {
            let state = try layout.pushStateDir(ws)
            if fm.fileExists(atPath: state.path) { try fm.removeItem(at: state) }
            return true
        }) == true else { throw CoordinationFiles.FileError.io("replay lock busy") }
        // Replay locks live in push/locks, outside the purgeable push state directory. Never remove them.
        for d in [try layout.filesDir(ws), try layout.tmpDir(ws), try layout.stagedJobsDir(ws), try layout.quarantineDir(ws)]
        where fm.fileExists(atPath: d.path) { try fm.removeItem(at: d) }
    }
}
