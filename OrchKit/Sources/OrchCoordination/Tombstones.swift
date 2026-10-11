import Foundation

/// Durable `(realm, ws, generation)` removal records kept as coordination files (A11/C2).
/// Pure Foundation (no SQLite): usable from the NSE and share extension. Lives in OrchCoordination, not OrchStore.
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

/// Unknown must refuse writes, but must never authorize destructive recovery.
public enum RemovalStatus: Sendable, Equatable { case removed, notRemoved, unknown }

public enum TombstoneError: Error, Equatable, Sendable {
    case lockFailed(Int32)
    /// The coordination file could not be parsed. A partial `write` leaves it untouched (readers keep
    /// failing closed); call `republish(complete:)` with the full set from the index to repair it.
    case corrupt(file: String)
    case io(String)
}

/// Extensions construct this with the single directory they can see (`StoreLayout.pushCoordination` /
/// `shareCoordination`); the app uses both.
///
/// The NSE and the share extension must write replay state / staged jobs ONLY inside `ifNotRemoved`
/// (check and action under one shared lock); a bare check followed by a write is a race with the wipe.
public struct TombstoneCoordination: Sendable {
    public let directories: [URL]
    public init(directories: [URL]) { self.directories = directories }

    static let fileName = "tombstones.json"
    static let lockName = "tombstones.lock"

    // Locking contract: every read or write takes flock on the stable `tombstones.lock` (never on the data
    // file, which is replaced by rename and so changes inode). Writers hold the exclusive lock across their
    // read-modify-write; checks that precede an action must use `ifNotRemoved` (check + action under the
    // shared lock). The bare checks below are internal: a check whose result is used after the lock is
    // released is a TOCTOU race.

    /// Bare fail-closed check (unreadable counts as removed). Internal: only for callers whose action is
    /// itself ordered by the index tombstone (see WorkspaceIndex) and for tests.
    package func isRemovedFailClosed(realm: String, ws: String, generation: Int64) -> Bool {
        removalStatus(realm: realm, ws: ws, generation: generation) != .notRemoved
    }

    /// A confirmed removal wins over unreadable copies. A busy lock is unknown, never evidence of removal.
    package func removalStatus(realm: String, ws: String, generation: Int64) -> RemovalStatus {
        var unknown = false
        for dir in directories {
            do {
                let records = try Self.withLocks([dir][...], exclusive: false, create: false, deadline: Date()) { fds in
                    try Self.readUnlocked(fd: fds[dir])
                }
                if Self.covers(records, realm, ws, generation) { return .removed }
            } catch { unknown = true }
        }
        return unknown ? .unknown : .notRemoved
    }

    /// Fail-open variant, for diagnostics and tests only: unreadable files count as "not removed".
    package func isRemoved(realm: String, ws: String, generation: Int64) -> Bool {
        for dir in directories {
            guard let records = try? Self.read(dir: dir) else { continue }
            if Self.covers(records, realm, ws, generation) { return true }
        }
        return false
    }

    /// The extension API: check-then-act under the shared lock of every directory: a wipe (exclusive writer) cannot slip in
    /// between the check and `body`. Returns nil, without running `body`, when the workspace is removed or
    /// the state is unreadable (fail-closed). `body` must be synchronous and short.
    ///
    /// `timeout`: wait at most this long for the locks (polling `LOCK_NB`), else throw `TombstoneError.lockFailed(EWOULDBLOCK)`
    /// without running `body`. Extensions on a deadline use it; nil waits as long as it takes.
    public func ifNotRemoved<T>(realm: String, ws: String, generation: Int64, timeout: TimeInterval? = nil, _ body: () throws -> T) throws -> T? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        return try Self.withLocks(directories.sorted { $0.path < $1.path }[...], exclusive: false, create: true, deadline: deadline) { fds -> T? in
            for dir in directories {
                guard let records = try? Self.readUnlocked(fd: fds[dir]) else { return nil }
                if Self.covers(records, realm, ws, generation) { return nil }
            }
            return try body()
        }
    }

    /// Throws if any directory is unreadable, so `[]` always means "no tombstones".
    public func records() throws -> [TombstoneRecord] {
        Set(try directories.flatMap { try Self.read(dir: $0) }).sorted { ($0.realm, $0.ws, $0.generation) < ($1.realm, $1.ws, $1.generation) }
    }

    /// Partial add (idempotent), sequentially per directory (a crash between directories leaves one file
    /// behind; the wipe's phase 1 repairs that via `republish`). Only a missing file counts as empty. An
    /// unparseable file is NOT touched: this throws `.corrupt` and readers keep failing closed.
    public func write(_ record: TombstoneRecord) throws { try write([record]) }

    public func write(_ new: [TombstoneRecord]) throws {
        for dir in directories {
            try Self.withLocks([dir][...], exclusive: true, create: true) { fds in
                var records: [TombstoneRecord]
                do { records = try Self.readUnlocked(fd: fds[dir]) }
                catch is DecodingError { throw TombstoneError.corrupt(file: dir.appendingPathComponent(Self.fileName).path) }
                let before = records.count
                for r in new where !records.contains(r) { records.append(r) }
                if records.count == before { return }
                try TombstoneFS.write(JSONEncoder().encode(records), dir: fds[dir]!, name: Self.fileName)
            }
        }
    }

    /// Repair/launch path: under the same exclusive lock, atomically replace each file with the complete
    /// authoritative set (union with any readable existing records). A corrupt file is first COPIED aside
    /// (`tombstones.json.corrupt-<uuid>`, diagnosis only); the replacement is an atomic rename, so readers see
    /// either the old (failing-closed) file or the complete new one, never a missing file.
    public func republish(complete: [TombstoneRecord]) throws {
        for dir in directories {
            try Self.withLocks([dir][...], exclusive: true, create: true) { fds in
                let fd = fds[dir]!
                let data = try TombstoneFS.read(fd, Self.fileName)
                var corrupt = false
                var records: [TombstoneRecord]
                do { records = try data.map { try JSONDecoder().decode([TombstoneRecord].self, from: $0) } ?? [] }
                catch is DecodingError {
                    corrupt = true
                    // Copy the bytes already read from the verified descriptor, never reopen by path.
                    try TombstoneFS.write(data!, dir: fd, name: "\(Self.fileName).corrupt-\(UUID().uuidString)")
                    records = []
                }
                let before = records
                for r in complete where !records.contains(r) { records.append(r) }
                if !corrupt && records == before && data != nil { return }
                try TombstoneFS.write(JSONEncoder().encode(records), dir: fd, name: Self.fileName)
            }
        }
    }

    static func covers(_ records: [TombstoneRecord], _ realm: String, _ ws: String, _ generation: Int64) -> Bool {
        records.contains { $0.realm == realm && $0.ws == ws && generation <= $0.generation }
    }

    private static func read(dir: URL) throws -> [TombstoneRecord] {
        try withLocks([dir][...], exclusive: false, create: false) { fds in try readUnlocked(fd: fds[dir]) }
    }

    /// Caller must hold the lock (flock on a second descriptor would self-deadlock).
    /// Missing file (ENOENT) is empty; every other failure throws.
    private static func readUnlocked(fd: Int32?) throws -> [TombstoneRecord] {
        guard let fd, let data = try TombstoneFS.read(fd, fileName) else { return [] }
        return try JSONDecoder().decode([TombstoneRecord].self, from: data)
    }

    /// Keep each verified directory open until its lock and all fd-relative operations finish.
    /// Readers never create directories: a missing directory simply means no tombstones.
    private static func withLocks<T>(_ dirs: ArraySlice<URL>, exclusive: Bool, create: Bool, deadline: Date? = nil,
                                     fds: [URL: Int32] = [:], _ body: ([URL: Int32]) throws -> T) throws -> T {
        guard let dir = dirs.first else { return try body(fds) }
        var directory = retryOnInterrupt({ open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) })
        if directory < 0, errno == ENOENT, create {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            directory = retryOnInterrupt({ open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) })
        }
        guard directory >= 0 else {
            if errno == ENOENT && !create {
                return try withLocks(dirs.dropFirst(), exclusive: exclusive, create: create, deadline: deadline, fds: fds, body)
            }
            throw TombstoneError.io("directory open: \(errno)")
        }
        defer { close(directory) }
        var st = stat()
        guard fstat(directory, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw TombstoneError.io("not a directory")
        }
        let fd = openCoordinationLock(lockName, relativeTo: directory)
        guard fd >= 0 else { throw TombstoneError.lockFailed(errno) }
        defer { close(fd) }
        try TombstoneFS.regular(fd)
        let op = exclusive ? LOCK_EX : LOCK_SH
        if let deadline {
            while retryOnInterrupt({ flock(fd, op | LOCK_NB) }) != 0 {
                guard errno == EWOULDBLOCK, Date() < deadline else { throw TombstoneError.lockFailed(errno) }
                usleep(5_000)
            }
        } else {
            guard retryOnInterrupt({ flock(fd, op) }) == 0 else { throw TombstoneError.lockFailed(errno) }
        }
        defer { _ = retryOnInterrupt({ flock(fd, LOCK_UN) }) }
        var held = fds; held[dir] = directory
        return try withLocks(dirs.dropFirst(), exclusive: exclusive, create: create, deadline: deadline, fds: held, body)
    }
}
