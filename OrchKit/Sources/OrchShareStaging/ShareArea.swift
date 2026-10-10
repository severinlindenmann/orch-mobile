import Foundation
import OrchCoordination

/// Everything the share extension and the app agree on inside `group.io.severin.orch.share` (A8, A10).
///
///   <share>/share/targets.json                       destinations index (app writes, extension reads)
///   <share>/share/tombstones.json                    removal generations (OrchCoordination)
///   <share>/share/staging/<realm>/<ws>/<job>/        staged plaintext (extension writes, app claims)
///   <share>/share/quarantine/<realm>/<ws>/<job>/     jobs whose destination went away (wiped with the workspace)
///
/// Foundation only: it links into the share extension, so no keychain, custody, signing or network.
/// The path formulas equal `StoreLayout.stagedJobsDir` / `quarantineDir` (a test pins that).
public struct ShareArea: Sendable {
    public let shareDir: URL
    /// The App Group container itself (the parent of `share/`): never a legal copy source.
    public let shareGroupRoot: URL

    public init(shareGroupRoot: URL) {
        self.shareGroupRoot = shareGroupRoot
        shareDir = shareGroupRoot.appendingPathComponent("share", isDirectory: true)
    }

    /// The share extension's view of the tombstones (it sees only this group).
    public var coordination: TombstoneCoordination { TombstoneCoordination(directories: [shareDir]) }
    public var targetsURL: URL { shareDir.appendingPathComponent("targets.json") }
    public var stagingRoot: URL { shareDir.appendingPathComponent("staging", isDirectory: true) }
    public var quarantineRoot: URL { shareDir.appendingPathComponent("quarantine", isDirectory: true) }

    public func stagingDir(realm: String, ws: String) throws -> URL {
        try Self.validate(realm: realm, ws: ws)
        return stagingRoot.appendingPathComponent(realm, isDirectory: true).appendingPathComponent(ws, isDirectory: true)
    }

    public func quarantineDir(realm: String, ws: String) throws -> URL {
        try Self.validate(realm: realm, ws: ws)
        return quarantineRoot.appendingPathComponent(realm, isDirectory: true).appendingPathComponent(ws, isDirectory: true)
    }

    static func validate(realm: String, ws: String) throws {
        // Same rules as StoreLayout (a test pins them): realm [a-z0-9_-]+, ws 32 lowercase hex. Kept local so this
        // module needs only the coordination types (TombstoneCoordination) from OrchCoordination.
        guard !realm.isEmpty, realm.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d || $0 == 0x5f }) else {
            throw ShareError.io("invalid realm")
        }
        guard ws.utf8.count == 32, ws.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
            throw ShareError.io("invalid workspace")
        }
    }

    /// Creates `dir` and every missing component below `shareDir` with Complete protection, excluded from backup.
    /// An existing component that is not a real directory (a symbolic link, a file) is refused, never followed.
    func ensureDirectory(_ dir: URL) throws {
        let base = shareDir.standardizedFileURL.pathComponents
        let target = dir.standardizedFileURL.pathComponents
        guard target.count >= base.count, Array(target.prefix(base.count)) == base else { throw ShareError.io("outside share dir") }
        var current = shareDir.standardizedFileURL
        try Self.prepare(current, intermediates: true)
        for part in target.dropFirst(base.count) {
            current = current.appendingPathComponent(part, isDirectory: true)
            try Self.prepare(current)
        }
    }

    /// True when `url` and every component between `shareDir` and it are real directories (lstat: no symbolic links).
    func isRealDirectoryChain(_ url: URL) -> Bool {
        let base = shareDir.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        guard target.count >= base.count, Array(target.prefix(base.count)) == base else { return false }
        var current = shareDir.standardizedFileURL
        guard Self.isRealDirectory(current) else { return false }
        for part in target.dropFirst(base.count) {
            current = current.appendingPathComponent(part, isDirectory: true)
            guard Self.isRealDirectory(current) else { return false }
        }
        return true
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// Removes what is at `url` without following links: a symbolic link is unlinked itself; a directory is removed
    /// only when every parent below `shareDir` is a real directory.
    @discardableResult
    func safeRemove(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return true }
        if (st.st_mode & S_IFMT) == S_IFLNK { return unlink(url.path) == 0 }
        guard isRealDirectoryChain(url.deletingLastPathComponent()) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    static func prepare(_ url: URL, intermediates: Bool = false) throws {
        var st = stat()
        if lstat(url.path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ShareError.io("not a real directory") }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: intermediates)
        }
        Self.protect(url)
        var u = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }

    /// NSFileProtectionComplete (a no-op off iOS).
    static func protect(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
}

public enum ShareError: Error, Equatable, Sendable {
    case noWorkspaces
    case unreadable
    case tooManyItems
    case tooLarge
    case empty
    case unsupported(String)
    case destinationRemoved
    case cancelled
    case io(String)
}

/// Limits from U11 (prototype policy, not wire law).
public enum ShareLimits {
    public static let maxItems = 5
    public static let maxTotalBytes = 25 * 1024 * 1024
    public static let maxNoteCharacters = 500
    public static let maxNameCharacters = 120
    public static let maxURLCharacters = 4096
    public static let sevenDays: TimeInterval = 7 * 86_400
    /// A partial (never READY) job older than this belongs to a killed extension.
    public static let partialTTL: TimeInterval = 3600
}

public struct ShareTarget: Codable, Hashable, Sendable, Identifiable {
    public let realm: String
    public let ws: String
    public let name: String
    public let hue: Int
    public let generation: Int64
    public var id: String { "\(realm)/\(ws)" }
    public init(realm: String, ws: String, name: String, hue: Int, generation: Int64) {
        self.realm = realm; self.ws = ws; self.name = name; self.hue = hue; self.generation = generation
    }
}

/// The minimal destinations index: realm, ws id, display name, hue, generation. No labels, keys or content.
public enum ShareTargetIndex {
    struct File: Codable { var version: Int; var targets: [ShareTarget] }

    /// App side. Replaces the whole index atomically; entries with invalid ids are refused.
    public static func publish(_ targets: [ShareTarget], to area: ShareArea) throws {
        for t in targets { try ShareArea.validate(realm: t.realm, ws: t.ws) }
        try area.ensureDirectory(area.shareDir)
        let clipped = targets.map { ShareTarget(realm: $0.realm, ws: $0.ws, name: String($0.name.prefix(80)), hue: $0.hue, generation: $0.generation) }
        let data = try JSONEncoder().encode(File(version: 1, targets: clipped))
        try data.write(to: area.targetsURL, options: .atomic)
        ShareArea.protect(area.targetsURL)
        var u = area.targetsURL
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }

    /// Extension side. Missing file means the app never published a workspace (`.noWorkspaces`). Anything unreadable
    /// or invalid fails closed (`.unreadable`); removed (tombstoned) destinations are filtered out.
    public static func load(from area: ShareArea) throws -> [ShareTarget] {
        if ShareArea.exists(area.shareDir), !ShareArea.isRealDirectory(area.shareDir) { throw ShareError.unreadable }
        let data: Data
        do { data = try ShareFS.readFile(area.targetsURL, cap: 256 * 1024) }
        catch ShareFS.ReadFailure.notFound { throw ShareError.noWorkspaces }
        catch { throw ShareError.unreadable }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { throw ShareError.unreadable }
        for t in file.targets where (try? ShareArea.validate(realm: t.realm, ws: t.ws)) == nil { throw ShareError.unreadable }
        let coordination = area.coordination
        var live: [ShareTarget] = []
        for t in file.targets {
            let ok = try? coordination.ifNotRemoved(realm: t.realm, ws: t.ws, generation: t.generation) { true }
            if ok == true { live.append(t) }
        }
        if live.isEmpty { throw ShareError.noWorkspaces }
        return live
    }
}
