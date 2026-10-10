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

public enum TombstoneError: Error, Sendable { case lockFailed(Int32), io(String) }

public struct TombstoneCoordination: Sendable {
    /// Directories holding the coordination file (one per App Group root). Writes go to all, reads to any.
    public let directories: [URL]
    public init(directories: [URL]) { self.directories = directories }

    static let fileName = "tombstones.json"
    static let lockName = "tombstones.lock"

    /// Extension fast path: check only the directory the extension can see.
    public func isRemoved(realm: String, ws: String, generation: Int64) -> Bool {
        for dir in directories {
            guard let records = try? Self.read(dir: dir) else { continue }
            if records.contains(where: { $0.realm == realm && $0.ws == ws && generation <= $0.generation }) { return true }
        }
        return false
    }

    /// Fail-closed variant: an unreadable file counts as removed (callers that must not publish on doubt).
    public func isRemovedFailClosed(realm: String, ws: String, generation: Int64) -> Bool {
        for dir in directories {
            guard let records = try? Self.read(dir: dir) else { return true }
            if records.contains(where: { $0.realm == realm && $0.ws == ws && generation <= $0.generation }) { return true }
        }
        return false
    }

    public func records() -> [TombstoneRecord] {
        Set(directories.flatMap { (try? Self.read(dir: $0)) ?? [] }).sorted { ($0.realm, $0.ws, $0.generation) < ($1.realm, $1.ws, $1.generation) }
    }

    /// Idempotent; atomically replaces the file in every directory.
    public func write(_ record: TombstoneRecord) throws {
        for dir in directories {
            try Self.withLock(dir: dir, exclusive: true) {
                var records = (try? Self.readUnlocked(dir: dir)) ?? []
                if records.contains(record) { return }
                records.append(record)
                let data = try JSONEncoder().encode(records)
                try data.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
            }
        }
    }

    /// Runs `body` while holding the shared lock, so a publisher can check-then-act without a wipe
    /// slipping in between. Extensions use this around "check generation, then publish job".
    public func withSharedLock<T>(_ body: () throws -> T) throws -> T {
        guard let dir = directories.first else { return try body() }
        return try Self.withLock(dir: dir, exclusive: false, body)
    }

    private static func read(dir: URL) throws -> [TombstoneRecord] {
        try withLock(dir: dir, exclusive: false) { try readUnlocked(dir: dir) }
    }

    /// Caller must hold the lock (flock on a second descriptor would self-deadlock).
    private static func readUnlocked(dir: URL) throws -> [TombstoneRecord] {
        let url = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([TombstoneRecord].self, from: Data(contentsOf: url))
    }

    private static func withLock<T>(dir: URL, exclusive: Bool, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(lockName).path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw TombstoneError.lockFailed(errno) }
        defer { close(fd) }
        guard flock(fd, exclusive ? LOCK_EX : LOCK_SH) == 0 else { throw TombstoneError.lockFailed(errno) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
