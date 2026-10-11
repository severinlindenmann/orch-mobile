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

    // MARK: fd-relative access
    //
    // Every operation resolves its URL to components below `shareDir` once (lexically), then walks them from the
    // root descriptor with `openat(O_NOFOLLOW|O_DIRECTORY)`. There is no separate "check" step: a component swapped
    // for a symbolic link fails the walk, and a swapped-in real directory is still inside the share area.

    /// Components of `url` below `shareDir`; nil when `url` is outside it or has an unusable component.
    func components(of url: URL) -> [String]? {
        let base = shareDir.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        guard target.count >= base.count, Array(target.prefix(base.count)) == base else { return nil }
        let rel = Array(target.dropFirst(base.count))
        guard rel.allSatisfy({ (try? ShareFS.checkName($0)) != nil }) else { return nil }
        return rel
    }

    /// Opens `url` (a directory below `shareDir`, or `shareDir` itself) through the walk; `create` makes missing
    /// components with Complete protection, excluded from backup.
    func openDir(_ url: URL, create: Bool = false) throws -> DirFD {
        guard let rel = components(of: url) else { throw ShareError.io("outside share dir") }
        return try ShareFS.walk(root: shareDir.standardizedFileURL, rel, create: create)
    }

    /// The verified parent directory of `url` and its last component.
    func openParent(_ url: URL, create: Bool = false) throws -> (dir: DirFD, name: String) {
        guard let rel = components(of: url), let last = rel.last else { throw ShareError.io("outside share dir") }
        return (try ShareFS.walk(root: shareDir.standardizedFileURL, Array(rel.dropLast()), create: create), last)
    }

    func ensureDirectory(_ dir: URL) throws { _ = try openDir(dir, create: true) }

    func readFile(_ url: URL, cap: Int) throws -> Data {
        let (dir, name) = try openParent(url)
        return try ShareFS.readFile(dir, name, cap: cap)
    }

    func writeFile(_ data: Data, to url: URL) throws {
        let (dir, name) = try openParent(url, create: true)
        try ShareFS.writeAtomic(dir, name, data)
    }

    func listNames(_ url: URL) -> [String] {
        guard let dir = try? openDir(url) else { return [] }
        return (try? ShareFS.list(dir)) ?? []
    }

    func isRegularFile(_ url: URL) -> Bool {
        guard let (dir, name) = try? openParent(url) else { return false }
        return ShareFS.isRegular(dir, name)
    }

    func modificationDate(_ url: URL) -> Date? {
        guard let (dir, name) = try? openParent(url), let st = ShareFS.statEntry(dir, name) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    }

    /// Renames `from` to `to` between two verified parent directories (`renameat`).
    func rename(_ from: URL, to: URL) -> Bool {
        guard let (fd, fname) = try? openParent(from), let (td, tname) = try? openParent(to) else { return false }
        return ShareFS.rename(fd, fname, td, tname)
    }

    /// Removes what is at `url` without following links, through descriptors only. Returns true when nothing is left
    /// at `url` (including when it or a parent never existed); false when a parent is a link or a file, or on I/O failure.
    @discardableResult
    func safeRemove(_ url: URL) -> Bool {
        guard let rel = components(of: url), let last = rel.last else { return false }
        do {
            let parent = try ShareFS.walk(root: shareDir.standardizedFileURL, Array(rel.dropLast()))
            return ShareFS.removeTree(parent, last)
        } catch ShareFS.ReadFailure.notFound { return true }
        catch { return false }
    }

    /// Presence test for tests and diagnostics (lstat: a link counts as present).
    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
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
        try area.writeFile(data, to: area.targetsURL)
    }

    /// Extension side. Missing file means the app never published a workspace (`.noWorkspaces`). Anything unreadable
    /// or invalid fails closed (`.unreadable`); removed (tombstoned) destinations are filtered out.
    public static func load(from area: ShareArea) throws -> [ShareTarget] {
        let data: Data
        do { data = try area.readFile(area.targetsURL, cap: 256 * 1024) }
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
