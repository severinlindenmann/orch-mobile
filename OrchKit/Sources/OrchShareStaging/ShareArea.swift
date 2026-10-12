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

    /// Longest the share extension waits for the tombstone lock before showing "busy". The extension must never wait
    /// forever behind an app-side wipe.
    public static let defaultLockTimeout: TimeInterval = 2
    public var lockTimeout: TimeInterval

    public init(shareGroupRoot: URL, lockTimeout: TimeInterval = ShareArea.defaultLockTimeout) {
        self.lockTimeout = lockTimeout
        self.shareGroupRoot = shareGroupRoot
        shareDir = shareGroupRoot.appendingPathComponent("share", isDirectory: true)
    }

    /// The share extension's view of the tombstones (it sees only this group).
    public var coordination: TombstoneCoordination { TombstoneCoordination(directories: [shareDir]) }
    /// `ifNotRemoved` with the bounded wait; a lock that stays taken surfaces as `ShareError.busy`.
    func ifNotRemovedBounded<T>(realm: String, ws: String, generation: Int64, _ body: () throws -> T) throws -> T? {
        do { return try coordination.ifNotRemoved(realm: realm, ws: ws, generation: generation, timeout: lockTimeout, body) }
        catch TombstoneError.lockFailed(let e) where e == EWOULDBLOCK { throw ShareError.busy }
    }
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
    ///
    /// Purely lexical: never `standardizedFileURL`, which drops a leading `/private` only when the path EXISTS. On a device
    /// the App Group container is `/private/var/mobile/…`, so an existing `share/` and a not-yet-written `targets.json`
    /// (or a new staging job directory) normalised differently and every create was refused as "outside share dir".
    func components(of url: URL) -> [String]? {
        let base = Self.lexical(shareDir)
        let target = Self.lexical(url)
        guard target.count >= base.count, Array(target.prefix(base.count)) == base else { return nil }
        let rel = Array(target.dropFirst(base.count))
        guard rel.allSatisfy({ (try? ShareFS.checkName($0)) != nil }) else { return nil }
        return rel
    }

    /// Absolute path components without the root, empty and `.` entries (no filesystem access). `..` is kept so the walk
    /// refuses it. Darwin's `/private/{var,tmp,etc}` and `/{var,tmp,etc}` name the same directories (root-owned links),
    /// so the `private` prefix is dropped from both sides deterministically.
    static func lexical(_ url: URL) -> [String] {
        var parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        if parts.count >= 2, parts[0] == "private", ["var", "tmp", "etc"].contains(parts[1]) { parts.removeFirst() }
        return parts
    }

    /// Opens `url` (a directory below `shareDir`, or `shareDir` itself) through the walk; `create` makes missing
    /// components with Complete protection, excluded from backup.
    func openDir(_ url: URL, create: Bool = false) throws -> DirFD {
        guard let rel = components(of: url) else { throw ShareError.io("outside share dir") }
        return try ShareFS.walk(root: shareDir, rel, create: create)
    }

    /// The verified parent directory of `url` and its last component.
    func openParent(_ url: URL, create: Bool = false) throws -> (dir: DirFD, name: String) {
        guard let rel = components(of: url), let last = rel.last else { throw ShareError.io("outside share dir") }
        return (try ShareFS.walk(root: shareDir, Array(rel.dropLast()), create: create), last)
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
            let parent = try ShareFS.walk(root: shareDir, Array(rel.dropLast()))
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
    /// The destinations index exists (or should) but cannot be used; the reason is specific and path-free.
    case index(ShareIndexFailure)
    case tooManyItems
    case tooLarge
    case empty
    case unsupported(String)
    case destinationRemoved
    case cancelled
    /// A coordination lock stayed taken past the extension's deadline: nothing was saved, try again.
    case busy
    case io(String)
}

extension ShareFS.ReadFailure {
    var code: String {
        switch self {
        case .notFound: "not found"
        case .notRegular: "not a regular file"
        case .tooBig: "too big"
        case .io(let e): "io \(e) \(ShareIndexFailure.errnoName(e))"
        }
    }
}

extension ShareError {
    /// Fixed, path-free code (every associated string in this module is a fixed text or a sanitised code).
    public var code: String {
        switch self {
        case .noWorkspaces: "none"
        case .unreadable: "unreadable"
        case .index(let f): f.code
        case .tooManyItems: "too many items"
        case .tooLarge: "too large"
        case .empty: "empty"
        case .unsupported(let s): "unsupported: \(ShareTargetIndex.sanitizeCode(s))"
        case .destinationRemoved: "destination removed"
        case .cancelled: "cancelled"
        case .busy: "busy"
        case .io(let s): "io: \(ShareTargetIndex.sanitizeCode(s))"
        }
    }
}

/// Why the destinations index could not be used. Every case is path-free and name-free (support evidence).
public enum ShareIndexFailure: Error, Equatable, Sendable {
    /// The index path was refused by the share-area containment check (path normalisation; device-only before 2026-10).
    case outsideShareDir
    /// open/read failed with this errno (EACCES/EPERM: sandbox or data protection; ELOOP: a link).
    case io(Int32)
    case notRegular
    case tooBig
    /// JSON decoding failed: decoding-error kind and coding path (schema keys only, never values).
    case decode(String)
    case version(Int)
    /// An entry has an invalid realm or workspace id.
    case invalidEntry
    /// Every destination was dropped because the tombstones could not be locked or read.
    case tombstones(String)
    /// The app could not refresh the index (it marked it stale): nothing is offered until a publish succeeds.
    case stale(String)

    /// Short fixed text, e.g. "io 1 EPERM", "decode keyNotFound targets.0.hue".
    public var code: String {
        switch self {
        case .outsideShareDir: "path refused"
        case .io(let e): "io \(e) \(ShareIndexFailure.errnoName(e))"
        case .notRegular: "not a regular file"
        case .tooBig: "too big"
        case .decode(let d): "decode \(d)"
        case .version(let v): "version \(v)"
        case .invalidEntry: "invalid entry"
        case .tombstones(let t): "tombstones \(t)"
        case .stale(let c): "stale: \(c)"
        }
    }

    public static func errnoName(_ e: Int32) -> String {
        switch e {
        case EPERM: "EPERM"
        case ENOENT: "ENOENT"
        case EACCES: "EACCES"
        case ELOOP: "ELOOP"
        case ENOTDIR: "ENOTDIR"
        case EISDIR: "EISDIR"
        case EWOULDBLOCK: "EWOULDBLOCK"
        case EIO: "EIO"
        case EBADF: "EBADF"
        default: "errno"
        }
    }

    static func describe(_ error: DecodingError) -> String {
        func at(_ kind: String, _ c: [CodingKey]) -> String {
            let p = c.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? kind : "\(kind) \(p)"
        }
        switch error {
        case .keyNotFound(let key, let ctx): return at("keyNotFound", ctx.codingPath + [key])
        case .typeMismatch(_, let ctx): return at("typeMismatch", ctx.codingPath)
        case .valueNotFound(_, let ctx): return at("valueNotFound", ctx.codingPath)
        case .dataCorrupted(let ctx): return at("dataCorrupted", ctx.codingPath)
        @unknown default: return "unknown"
        }
    }
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
    struct File: Codable {
        var version: Int
        var targets: [ShareTarget]
        /// Set by the app when a refresh was skipped (fixed code); a stale index offers nothing. Absent when fresh.
        var stale: String?
    }

    /// Only short fixed codes survive (the extension can write the share folder too, so these files are untrusted):
    /// ASCII letters, digits and ` :._-`, at most 120 characters; anything else reads as "invalid".
    public static func sanitizeCode(_ s: String) -> String {
        guard !s.isEmpty, s.utf8.count <= 120, s.utf8.allSatisfy({ c in
            (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) || (c >= 0x30 && c <= 0x39) || c == 0x20 || c == 0x3a || c == 0x2e || c == 0x5f || c == 0x2d
        }) else { return "invalid" }
        return s
    }

    /// App side. Replaces the whole index atomically; entries with invalid ids are refused. The outcome (success or a
    /// path-free failure code) is also recorded best-effort in `index-status.json` for the on-device diagnostics.
    public static func publish(_ targets: [ShareTarget], to area: ShareArea, now: Date = Date()) throws {
        do {
            for t in targets { try ShareArea.validate(realm: t.realm, ws: t.ws) }
            try area.ensureDirectory(area.shareDir)
            let clipped = targets.map { ShareTarget(realm: $0.realm, ws: $0.ws, name: String($0.name.prefix(80)), hue: $0.hue, generation: $0.generation) }
            let data = try JSONEncoder().encode(File(version: 1, targets: clipped))
            try area.writeFile(data, to: area.targetsURL)
            PublishStatus.record(.init(at: now.timeIntervalSince1970, result: "ok", targets: targets.count), in: area)
        } catch {
            PublishStatus.record(.init(at: now.timeIntervalSince1970, result: PublishStatus.code(error), targets: targets.count), in: area)
            throw error
        }
    }

    /// App side: a publish that was not attempted (an earlier step failed) is recorded too, so the diagnostics never show
    /// a stale "ok". `reason` must be a fixed, path-free code.
    ///
    /// The existing index is kept (the app still needs it to retire removed destinations after a restart) but marked
    /// stale, so the extension offers nothing from it: a destination removed meanwhile is never offered.
    public static func recordPublishSkipped(_ reason: String, in area: ShareArea, now: Date = Date()) {
        if var file = try? readFile(from: area, allowStale: true) {
            file.stale = sanitizeCode(reason)
            if let data = try? JSONEncoder().encode(file) { try? area.writeFile(data, to: area.targetsURL) }
        }
        PublishStatus.record(.init(at: now.timeIntervalSince1970, result: "skipped: \(reason)", targets: 0), in: area)
    }

    /// App side: every destination in the index (stale or not, tombstoned or not), for retiring removals after a restart.
    /// Missing index: empty. Unreadable: throws (the caller must not treat that as "nothing was published").
    public static func persisted(from area: ShareArea) throws -> [ShareTarget] {
        do { return try readFile(from: area, allowStale: true).targets }
        catch ShareError.noWorkspaces { return [] }
    }

    /// The app's last publish attempt, as seen by both sides (no names: a count and a fixed result code).
    public struct PublishStatus: Codable, Equatable, Sendable {
        public let at: Double
        public let result: String
        public let targets: Int

        static func url(_ area: ShareArea) -> URL { area.shareDir.appendingPathComponent("index-status.json") }

        static func record(_ status: PublishStatus, in area: ShareArea) {
            guard let data = try? JSONEncoder().encode(status) else { return }
            try? area.writeFile(data, to: url(area))
        }

        /// Untrusted input (the extension shares the folder): the result is sanitised, the count and time clamped.
        public static func read(from area: ShareArea, now: Date = Date()) -> PublishStatus? {
            guard let data = try? area.readFile(url(area), cap: 4096),
                  let raw = try? JSONDecoder().decode(PublishStatus.self, from: data) else { return nil }
            let earliest = 1_577_836_800.0   // 2020-01-01
            let latest = now.timeIntervalSince1970 + 86_400
            let at = raw.at.isFinite ? min(max(raw.at, earliest), latest) : earliest
            return PublishStatus(at: at, result: ShareTargetIndex.sanitizeCode(raw.result), targets: min(max(raw.targets, 0), 10_000))
        }

        /// Fixed code for a publish failure; ShareError.io texts are fixed strings in this module (never paths).
        public static func code(_ error: Error) -> String {
            switch error {
            case let e as ShareError: e.code
            case let f as ShareFS.ReadFailure: f.code
            case let t as TombstoneError: ShareTargetIndex.tombstoneCode(t)
            case let f as CoordinationFiles.FileError: f == .unsafeLock ? "unsafe lock" : "coordination io"   // io text may hold a path
            case is EncodingError: "encode"
            default: "other"
            }
        }
    }

    /// Extension side. Missing file means the app never published a workspace (`.noWorkspaces`). Anything unreadable
    /// or invalid fails closed with a specific `.index(_)` reason; removed (tombstoned) destinations are filtered out.
    public static func load(from area: ShareArea) throws -> [ShareTarget] {
        let file = try readFile(from: area)
        let coordination = area.coordination
        var live: [ShareTarget] = []
        var lockFailure: String?
        for t in file.targets {
            do {
                if try coordination.ifNotRemoved(realm: t.realm, ws: t.ws, generation: t.generation, timeout: area.lockTimeout, { true }) == true { live.append(t) }
            } catch { lockFailure = Self.tombstoneCode(error) }
        }
        if live.isEmpty {
            if let lockFailure { throw ShareError.index(.tombstones(lockFailure)) }
            // nil from ifNotRemoved is "removed" OR "tombstones unreadable": tell them apart for the user.
            if !file.targets.isEmpty {
                do { _ = try coordination.records() } catch { throw ShareError.index(.tombstones(Self.tombstoneCode(error))) }
            }
            throw ShareError.noWorkspaces
        }
        return live
    }

    /// The validated index file without the tombstone filter (also used by diagnostics).
    static func readFile(from area: ShareArea, allowStale: Bool = false) throws -> File {
        let data: Data
        do { data = try area.readFile(area.targetsURL, cap: 256 * 1024) }
        catch let f as ShareFS.ReadFailure {
            switch f {
            case .notFound: throw ShareError.noWorkspaces
            case .notRegular: throw ShareError.index(.notRegular)
            case .tooBig: throw ShareError.index(.tooBig)
            case .io(let e): throw ShareError.index(.io(e))
            }
        }
        catch { throw ShareError.index(.outsideShareDir) }   // ShareError.io from the containment check / invalid component
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) }
        catch let e as DecodingError { throw ShareError.index(.decode(ShareIndexFailure.describe(e))) }
        catch { throw ShareError.index(.decode("other")) }
        guard file.version == 1 else { throw ShareError.index(.version(file.version)) }
        for t in file.targets where (try? ShareArea.validate(realm: t.realm, ws: t.ws)) == nil { throw ShareError.index(.invalidEntry) }
        if !allowStale, let stale = file.stale { throw ShareError.index(.stale(sanitizeCode(stale))) }
        return file
    }

    static func tombstoneCode(_ error: Error) -> String {
        switch error as? TombstoneError {
        case .lockFailed(let e): "lock \(e) \(ShareIndexFailure.errnoName(e))"
        case .corrupt: "corrupt"
        case .io: "io"
        case nil: error is DecodingError ? "corrupt" : "other"
        }
    }
}
