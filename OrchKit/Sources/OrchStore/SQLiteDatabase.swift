import Foundation
import SQLite3

/// A3/A7 safety contract: tiny wrapper over the sqlite3 C API.
/// - one serialized connection per database (this actor owns the only handle),
/// - `SQLITE_TRANSIENT` bindings, column data copied before step/finalize,
/// - transactions take a synchronous closure, so no `await` can happen inside one,
/// - every result code is checked and mapped to `SQLiteError`; failures roll back,
/// - migrations are atomic (one transaction per migration) and recorded in `schema_migrations`.

public enum SQLValue: Sendable, Hashable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public struct SQLRow: Sendable {
    public let columns: [String]
    public let values: [SQLValue]
    public subscript(_ i: Int) -> SQLValue { values[i] }
    public subscript(_ name: String) -> SQLValue {
        guard let i = columns.firstIndex(of: name) else { return .null }
        return values[i]
    }
    public func int(_ name: String) -> Int64? { if case .int(let v) = self[name] { return v }; return nil }
    public func text(_ name: String) -> String? { if case .text(let v) = self[name] { return v }; return nil }
    public func blob(_ name: String) -> Data? { if case .blob(let v) = self[name] { return v }; return nil }
}

public enum SQLiteError: Error, Equatable, Sendable {
    case constraint(code: Int32, message: String)
    case diskFull(message: String)
    case busy(message: String)
    case readOnly(message: String)
    case corrupt(message: String)
    case cantOpen(message: String)
    case io(code: Int32, message: String)
    case misuse(String)
    case closed
    case migrationFailed(version: Int, message: String)
    case schemaTooNew(found: Int, known: Int)
    case failure(code: Int32, message: String)

    static func map(code: Int32, message: String) -> SQLiteError {
        switch code & 0xFF {
        case SQLITE_CONSTRAINT: return .constraint(code: code, message: message)
        case SQLITE_FULL: return .diskFull(message: message)
        case SQLITE_BUSY, SQLITE_LOCKED: return .busy(message: message)
        case SQLITE_READONLY: return .readOnly(message: message)
        case SQLITE_CORRUPT, SQLITE_NOTADB: return .corrupt(message: message)
        case SQLITE_CANTOPEN: return .cantOpen(message: message)
        case SQLITE_IOERR: return .io(code: code, message: message)
        default: return .failure(code: code, message: message)
        }
    }
}

public struct Migration: Sendable {
    public let version: Int
    public let statements: [String]
    public init(version: Int, statements: [String]) {
        self.version = version
        self.statements = statements
    }
}

// SQLITE_TRANSIENT is a macro the importer cannot see.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
// SQLITE_OPEN_FILEPROTECTION_COMPLETE (0x00100000) exists only in Apple's iOS SQLite.
private let openFileProtectionComplete: Int32 = 0x0010_0000

/// Non-Sendable handle; only ever touched from inside the owning actor.
final class SQLiteHandle: @unchecked Sendable {
    var db: OpaquePointer?
    init(db: OpaquePointer) { self.db = db }

    func message() -> String {
        guard let db else { return "closed" }
        return String(cString: sqlite3_errmsg(db))
    }

    func fail(_ rc: Int32) -> SQLiteError {
        guard let db else { return .closed }
        return SQLiteError.map(code: sqlite3_extended_errcode(db), message: message())
    }

    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) throws -> (rows: [SQLRow], changes: Int) {
        guard let db else { throw SQLiteError.closed }
        var stmt: OpaquePointer?
        var rest = ""
        let rc: Int32 = sql.withCString { c in
            var tail: UnsafePointer<CChar>?
            let r = sqlite3_prepare_v2(db, c, -1, &stmt, &tail)
            if let tail { rest = String(cString: tail) }  // tail points into `c`: copy inside the closure
            return r
        }
        guard rc == SQLITE_OK else {
            let e = fail(rc)
            sqlite3_finalize(stmt)
            throw e
        }
        guard let stmt else { throw SQLiteError.misuse("empty statement") }
        defer { sqlite3_finalize(stmt) }
        // sqlite prepares only the first statement; silently dropping the rest would hide bugs
        // (e.g. a multi-statement migration recorded as applied with half its effect).
        if !rest.allSatisfy({ $0.isWhitespace || $0 == ";" }) {
            throw SQLiteError.misuse("multiple statements in one call are not allowed")
        }
        guard Int(sqlite3_bind_parameter_count(stmt)) == params.count else {
            throw SQLiteError.misuse("expected \(sqlite3_bind_parameter_count(stmt)) parameters, got \(params.count)")
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let brc: Int32
            switch p {
            case .null: brc = sqlite3_bind_null(stmt, idx)
            case .int(let v): brc = sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): brc = sqlite3_bind_double(stmt, idx, v)
            case .text(let s):
                // Explicit UTF-8 byte count: -1 would stop at an embedded NUL and make distinct strings collide.
                var copy = s
                brc = copy.withUTF8 { buf in
                    if let base = buf.baseAddress {
                        return sqlite3_bind_text(stmt, idx, UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self), Int32(buf.count), sqliteTransient)
                    }
                    return sqlite3_bind_text(stmt, idx, "", 0, sqliteTransient)
                }
            case .blob(let d):
                if d.isEmpty {
                    brc = sqlite3_bind_zeroblob(stmt, idx, 0)
                } else {
                    brc = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), sqliteTransient) }
                }
            }
            guard brc == SQLITE_OK else { throw fail(brc) }
        }
        let count = sqlite3_column_count(stmt)
        let names = (0..<count).map { String(cString: sqlite3_column_name(stmt, $0)) }
        var rows: [SQLRow] = []
        while true {
            let src = sqlite3_step(stmt)
            if src == SQLITE_DONE { break }
            guard src == SQLITE_ROW else { throw fail(src) }
            var values: [SQLValue] = []
            values.reserveCapacity(Int(count))
            for c in 0..<count {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: values.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: values.append(.real(sqlite3_column_double(stmt, c)))
                case SQLITE_TEXT:
                    // Copy now: the pointer is invalid after the next step/finalize.
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_text(stmt, c) {
                        values.append(.text(String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)))
                    } else { values.append(.text("")) }
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if n > 0, let p = sqlite3_column_blob(stmt, c) { values.append(.blob(Data(bytes: p, count: n))) }
                    else { values.append(.blob(Data())) }
                default: values.append(.null)
                }
            }
            rows.append(SQLRow(columns: names, values: values))
        }
        return (rows, Int(sqlite3_changes(db)))
    }

    func transaction<T>(_ body: (SQLiteTransaction) throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let result = try body(SQLiteTransaction(handle: self))
            try run("COMMIT")
            return result
        } catch {
            // After a failed COMMIT the transaction may still be open; ROLLBACK is a no-op error otherwise.
            if let db, sqlite3_get_autocommit(db) == 0 { _ = try? run("ROLLBACK") }
            throw error
        }
    }
}

/// Handed to a transaction body. Deliberately not Sendable and synchronous.
public struct SQLiteTransaction {
    let handle: SQLiteHandle
    @discardableResult
    public func execute(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        try handle.run(sql, params).changes
    }
    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        try handle.run(sql, params).rows
    }
}

public actor SQLiteDatabase {
    public let url: URL
    private var handle: SQLiteHandle?

    /// - Parameter fileProtection: request `SQLITE_OPEN_FILEPROTECTION_COMPLETE` (honoured on iOS only).
    public init(url: URL, fileProtection: Bool = true) throws {
        // SECURITY: realpath resolves symlinks in the PARENT path and NOFOLLOW guards only the last
        // component, so this must be used for app-private container paths only, never under an App Group
        // root another process can write (StoreLayout enforces disjoint roots).
        // SQLite's NOFOLLOW rejects a symlink anywhere in the path (/var -> /private/var on Apple platforms),
        // so resolve the parent directory ourselves; the database file itself must not be a symlink.
        // (URL.resolvingSymlinksInPath would strip /private again, so use realpath.)
        let parent = url.deletingLastPathComponent().path
        let resolvedParent = realpath(parent, nil).map { p -> String in defer { free(p) }; return String(cString: p) } ?? parent
        let url = URL(fileURLWithPath: resolvedParent, isDirectory: true).appendingPathComponent(url.lastPathComponent)
        self.url = url
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        #if os(iOS)
        if fileProtection { flags |= openFileProtectionComplete }
        #endif
        var raw: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &raw, flags, nil)
        guard rc == SQLITE_OK, let raw else {
            let msg = raw.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let raw { sqlite3_close(raw) }
            throw SQLiteError.map(code: rc, message: msg)
        }
        let h = SQLiteHandle(db: raw)
        do {
            // Bounded wait (5 s) when another connection (an extension) holds the write lock; then .busy.
            sqlite3_busy_timeout(raw, 5000)
            let mode = try h.run("PRAGMA journal_mode=WAL").rows.first?[0]
            guard case .text(let m)? = mode, m.lowercased() == "wal" else {
                throw SQLiteError.failure(code: -1, message: "WAL mode unavailable")
            }
            try h.run("PRAGMA synchronous=FULL")
            try h.run("PRAGMA foreign_keys=ON")
            try h.run("PRAGMA secure_delete=ON")
        } catch {
            sqlite3_close(raw)
            throw error
        }
        self.handle = h
    }

    deinit {
        if let db = handle?.db { sqlite3_close_v2(db) }
    }

    public var isOpen: Bool { handle != nil }

    public func close() {
        if let db = handle?.db {
            // Checkpoint so the -wal file is empty before it is deleted or reopened.
            _ = try? handle?.run("PRAGMA wal_checkpoint(TRUNCATE)")
            sqlite3_close_v2(db)
        }
        handle?.db = nil
        handle = nil
    }

    private func h() throws -> SQLiteHandle {
        guard let handle else { throw SQLiteError.closed }
        return handle
    }

    @discardableResult
    public func execute(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        try h().run(sql, params).changes
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        try h().run(sql, params).rows
    }

    /// The body is synchronous: no suspension point can occur while the transaction is open.
    public func transaction<T: Sendable>(_ body: @Sendable (SQLiteTransaction) throws -> T) throws -> T {
        try h().transaction(body)
    }

    public func userVersion() throws -> Int {
        guard case .int(let v)? = try h().run("PRAGMA user_version").rows.first?[0] else { return 0 }
        return Int(v)
    }

    public func appliedMigrations() throws -> [Int] {
        try h().run("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)")
        return try h().run("SELECT version FROM schema_migrations ORDER BY version").rows.compactMap {
            if case .int(let v) = $0[0] { return Int(v) } else { return nil }
        }
    }

    /// Applies pending migrations in version order, each in its own transaction together with its
    /// `schema_migrations` row. A failing migration leaves the schema as it was before that migration.
    public func migrate(_ migrations: [Migration]) throws {
        let versions = migrations.map(\.version)
        guard versions == versions.sorted(), Set(versions).count == versions.count else {
            throw SQLiteError.misuse("migrations must have strictly increasing versions")
        }
        let h = try h()
        let applied = Set(try appliedMigrations())
        if let newest = applied.max(), newest > (versions.max() ?? 0) {
            throw SQLiteError.schemaTooNew(found: newest, known: versions.max() ?? 0)
        }
        for m in migrations where !applied.contains(m.version) {
            do {
                try h.transaction { tx in
                    for s in m.statements { try tx.execute(s) }
                    try tx.execute("INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
                                   [.int(Int64(m.version)), .int(Int64(Date().timeIntervalSince1970))])
                }
            } catch {
                throw SQLiteError.migrationFailed(version: m.version, message: "\(error)")
            }
        }
    }
}
