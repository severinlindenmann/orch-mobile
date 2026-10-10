import Foundation

public enum LayoutError: Error, Equatable, Sendable { case invalidRealm(String), invalidWorkspace(String) }

/// A8 layout. Roots are injected: tests pass temp dirs, the app passes the real containers.
///   <appRoot>/orch/<realm>/index.sqlite
///   <appRoot>/orch/<realm>/ws/<ws_hex>/{ws.sqlite,files/,tmp/}
///   <pushGroupRoot>/push/            (group.io.severin.orch; CompleteUntilFirstUserAuthentication)
///   <shareGroupRoot>/share/          (group.io.severin.orch.share; Complete, excluded from backup)
public struct StoreLayout: Sendable {
    public let appRoot: URL
    public let pushGroupRoot: URL
    public let shareGroupRoot: URL
    public let realm: String

    public init(appRoot: URL, pushGroupRoot: URL, shareGroupRoot: URL, realm: String) throws {
        guard !realm.isEmpty, realm.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d || $0 == 0x5f }) else {
            throw LayoutError.invalidRealm(realm)
        }
        self.appRoot = appRoot; self.pushGroupRoot = pushGroupRoot; self.shareGroupRoot = shareGroupRoot; self.realm = realm
    }

    public var realmDir: URL { appRoot.appendingPathComponent("orch").appendingPathComponent(realm, isDirectory: true) }
    public var indexURL: URL { realmDir.appendingPathComponent("index.sqlite") }
    public var wsRoot: URL { realmDir.appendingPathComponent("ws", isDirectory: true) }
    public var pushDir: URL { pushGroupRoot.appendingPathComponent("push", isDirectory: true) }
    public var shareDir: URL { shareGroupRoot.appendingPathComponent("share", isDirectory: true) }
    /// Coordination (tombstone) directories in both App Group roots.
    public var tombstoneDirectories: [URL] { [pushDir, shareDir] }
    public var tombstones: TombstoneCoordination { TombstoneCoordination(directories: tombstoneDirectories) }

    public static func validate(ws: String) throws {
        guard !ws.isEmpty, ws.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
            throw LayoutError.invalidWorkspace(ws)
        }
    }

    public func wsDir(_ ws: String) throws -> URL { try Self.validate(ws: ws); return wsRoot.appendingPathComponent(ws, isDirectory: true) }
    public func wsDatabaseURL(_ ws: String) throws -> URL { try wsDir(ws).appendingPathComponent("ws.sqlite") }
    public func filesDir(_ ws: String) throws -> URL { try wsDir(ws).appendingPathComponent("files", isDirectory: true) }
    public func tmpDir(_ ws: String) throws -> URL { try wsDir(ws).appendingPathComponent("tmp", isDirectory: true) }
    /// Staged share jobs for this realm/workspace, inside the share group (removed by wipe).
    public func stagedJobsDir(_ ws: String) throws -> URL {
        try Self.validate(ws: ws)
        return shareDir.appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(realm, isDirectory: true).appendingPathComponent(ws, isDirectory: true)
    }
    /// Quarantined jobs (do not survive a workspace wipe).
    public func quarantineDir(_ ws: String) throws -> URL {
        try Self.validate(ws: ws)
        return shareDir.appendingPathComponent("quarantine", isDirectory: true)
            .appendingPathComponent(realm, isDirectory: true).appendingPathComponent(ws, isDirectory: true)
    }
    /// All SQLite files belonging to a database path (main + sidecars).
    public static func sqliteFiles(_ db: URL) -> [URL] {
        ["", "-wal", "-shm", "-journal"].map { URL(fileURLWithPath: db.path + $0) }
    }

    public func prepareRealm() throws {
        try Self.makeDir(realmDir, protection: .complete, exclude: true)
        try Self.makeDir(wsRoot, protection: .complete, exclude: true)
        try Self.makeDir(pushDir, protection: .untilFirstAuth, exclude: false)
        try Self.makeDir(shareDir, protection: .complete, exclude: true)
    }

    public func prepareWorkspace(_ ws: String) throws {
        try prepareRealm()
        for d in [try wsDir(ws), try filesDir(ws), try tmpDir(ws)] { try Self.makeDir(d, protection: .complete, exclude: true) }
    }

    enum Protection { case complete, untilFirstAuth }

    static func makeDir(_ url: URL, protection: Protection, exclude: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: protection == .complete ? FileProtectionType.complete : .completeUntilFirstUserAuthentication],
                             ofItemAtPath: url.path)
        #endif
        if exclude {
            var u = url
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try u.setResourceValues(rv)
        }
    }
}
