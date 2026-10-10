import Foundation

/// Durable `(realm, ws, generation)` removal records kept as coordination files (A11/C2).
/// Pure Foundation (no SQLite): usable from the NSE and share extension.
///
/// Semantics: a tombstone with generation `g` means every generation `<= g` of that workspace is removed;
/// a later rejoin must use a higher generation. Files are read and written under `flock`.
public struct TombstoneRecord: Codable, Hashable, Sendable {
    public let realm: String
    public let ws: String
    public let generation: Int64
    public init(realm: String, ws: String, generation: Int64) {
        self.realm = realm; self.ws = ws; self.generation = generation
    }
}

public enum TombstoneError: Error, Equatable, Sendable {
    case lockFailed(Int32)
    /// The coordination file could not be parsed. It was moved aside (`.corrupt-<ts>`); the caller must
    /// re-publish all tombstones from the index (LocalWipe does this on retry).
    case corrupt(movedTo: String)
    case io(String)
}

/// Extensions construct this with the single directory they can see (`StoreLayout.pushCoordination` /
/// `shareCoordination`); the app uses both.
public struct TombstoneCoordination: Sendable {
    public let directories: [URL]
    public init(directories: [URL]) { self.directories = directories }

    static let fileName = "tombstones.json"
    static let lockName = "tombstones.lock"

    /// Fail-closed removal check for extension code paths: anything unreadable counts as removed.
    public func isRemovedFailClosed(realm: String, ws: String, generation: Int64) -> Bool {
        for dir in directories {
            guard let records = try? Self.read(dir: dir) else { return true }
            if Self.covers(records, realm, ws, generation) { return true }
        }
        return false
    }

    /// Fail-open variant, for diagnostics and tests only: unreadable files count as "not removed".
    func isRemoved(realm: String, ws: String, generation: Int64) -> Bool {
        for dir in directories {
            guard let records = try? Self.read(dir: dir) else { continue }
            if Self.covers(records, realm, ws, generation) { return true }
        }
        return false
    }

    /// Check-then-act under the shared lock of every directory: a wipe (exclusive writer) cannot slip in
    /// between the check and `body`. Returns nil, without running `body`, when the workspace is removed or
    /// the state is unreadable (fail-closed). `body` must be synchronous and short.
    public func ifNotRemoved<T>(realm: String, ws: String, generation: Int64, _ body: () throws -> T) throws -> T? {
        try Self.withLocks(directories.sorted { $0.path < $1.path }[...], exclusive: false, create: false) { () throws -> T? in
            for dir in directories {
                guard let records = try? Self.readUnlocked(dir: dir) else { return nil }
                if Self.covers(records, realm, ws, generation) { return nil }
            }
            return try body()
        }
    }

    public func records() -> [TombstoneRecord] {
        Set(directories.flatMap { (try? Self.read(dir: $0)) ?? [] }).sorted { ($0.realm, $0.ws, $0.generation) < ($1.realm, $1.ws, $1.generation) }
    }

    /// Idempotent; atomically replaces the file in every directory (sequentially: a crash between
    /// directories leaves one file behind, which the wipe's phase 1 repairs on resume from the index).
    /// Only a missing file counts as empty; an unreadable one is moved aside and reported, never overwritten.
    public func write(_ record: TombstoneRecord) throws { try write([record]) }

    public func write(_ new: [TombstoneRecord]) throws {
        for dir in directories {
            try Self.withLocks([dir][...], exclusive: true, create: true) {
                var records: [TombstoneRecord]
                do { records = try Self.readUnlocked(dir: dir) }
                catch is DecodingError {
                    let aside = dir.appendingPathComponent("\(Self.fileName).corrupt-\(Int(Date().timeIntervalSince1970))")
                    try? FileManager.default.removeItem(at: aside)
                    try FileManager.default.moveItem(at: dir.appendingPathComponent(Self.fileName), to: aside)
                    throw TombstoneError.corrupt(movedTo: aside.path)
                }
                let before = records.count
                for r in new where !records.contains(r) { records.append(r) }
                if records.count == before { return }
                let data = try JSONEncoder().encode(records)
                try data.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
            }
        }
    }

    static func covers(_ records: [TombstoneRecord], _ realm: String, _ ws: String, _ generation: Int64) -> Bool {
        records.contains { $0.realm == realm && $0.ws == ws && generation <= $0.generation }
    }

    private static func read(dir: URL) throws -> [TombstoneRecord] {
        try withLocks([dir][...], exclusive: false, create: false) { try readUnlocked(dir: dir) }
    }

    /// Caller must hold the lock (flock on a second descriptor would self-deadlock).
    /// Missing file (ENOENT) is empty; every other failure throws.
    private static func readUnlocked(dir: URL) throws -> [TombstoneRecord] {
        let url = dir.appendingPathComponent(fileName)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError { return [] }
        catch let e as NSError where e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT) { return [] }
        return try JSONDecoder().decode([TombstoneRecord].self, from: data)
    }

    /// Takes the lock files in the given order (callers sort) and runs `body` while holding all of them.
    /// Readers never create directories: a missing directory simply means no tombstones.
    private static func withLocks<T>(_ dirs: ArraySlice<URL>, exclusive: Bool, create: Bool, _ body: () throws -> T) throws -> T {
        guard let dir = dirs.first else { return try body() }
        if create { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let path = dir.appendingPathComponent(lockName).path
        // O_NOFOLLOW: a planted symlink must not redirect O_CREAT to another file.
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            if errno == ENOENT && !create { return try withLocks(dirs.dropFirst(), exclusive: exclusive, create: create, body) }
            throw TombstoneError.lockFailed(errno)
        }
        defer { close(fd) }
        guard flock(fd, exclusive ? LOCK_EX : LOCK_SH) == 0 else { throw TombstoneError.lockFailed(errno) }
        defer { flock(fd, LOCK_UN) }
        return try withLocks(dirs.dropFirst(), exclusive: exclusive, create: create, body)
    }
}
