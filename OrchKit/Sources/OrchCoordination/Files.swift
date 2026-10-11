import Foundation

/// Retry only interrupted POSIX calls. Never use for close(): the descriptor may already be released.
func retryOnInterrupt(_ operation: () -> Int32) -> Int32 {
    var result: Int32
    repeat { result = operation() } while result == -1 && errno == EINTR
    return result
}

/// Lock files are stable: never unlink or replace them while coordination users may be active.
/// Darwin can return ENOENT when O_CREAT | O_NOFOLLOW races another creator. Open existing
/// first, then use exclusive creation so a losing creator gets EEXIST and reopens the winner.
func openCoordinationLock(_ path: String, relativeTo directory: Int32 = AT_FDCWD) -> Int32 {
    let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    var fd = retryOnInterrupt({ openat(directory, path, flags) })
    if fd < 0, errno == ENOENT {
        fd = retryOnInterrupt({ openat(directory, path, flags | O_CREAT | O_EXCL, 0o600) })
        if fd < 0, errno == EEXIST {
            fd = retryOnInterrupt({ openat(directory, path, flags) })
        }
    }
    return fd
}

/// Small Foundation-only file primitives shared by the app and both extensions (no SQLite, no crypto, no network):
/// crash-safe atomic writes and flock helpers. Decision A11: this module (with the tombstone coordination files) is what
/// an extension links to honour removal; `OrchNotify` and the share extension must not need OrchStore for that.
public enum CoordinationFiles {
    public enum FileError: Error, Equatable, Sendable { case io(String) }

    /// Temp file in the same directory, optional fsync, rename over the target, directory fsync.
    /// `durable: false` skips both fsyncs (best-effort writes on a deadline, such as the expiry marker).
    public static func atomicWrite(_ data: Data, to url: URL, dir: URL, durable: Bool = true) throws {
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = retryOnInterrupt({ open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) })
        guard fd >= 0 else { throw FileError.io("tmp open \(errno)") }
        var ok = false
        defer { close(fd); if !ok { unlink(tmp.path) } }
        try data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Foundation.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; throw FileError.io("write \(errno)") }
                off += n
            }
        }
        if durable, retryOnInterrupt({ fsync(fd) }) != 0 { throw FileError.io("fsync \(errno)") }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: tmp.path)
        #endif
        guard rename(tmp.path, url.path) == 0 else { throw FileError.io("rename \(errno)") }
        ok = true
        if durable {
            let dfd = retryOnInterrupt({ open(dir.path, O_RDONLY | O_CLOEXEC) })
            if dfd >= 0 { _ = retryOnInterrupt({ fsync(dfd) }); close(dfd) }
        }
    }

    /// Creates the directory (with intermediates); on iOS sets `completeUntilFirstUserAuthentication`.
    public static func makeDir(_ url: URL) throws {
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { throw FileError.io("mkdir \(error)") }
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    /// Runs `body` holding flock on `path` (created O_NOFOLLOW). `blocking: false` returns nil at once if the lock is
    /// taken (the body does not run).
    /// `timeout` (with `blocking: true`): poll `LOCK_NB` for at most that long, then return nil.
    public static func withFlock<T>(_ path: String, exclusive: Bool = true, blocking: Bool = true, timeout: TimeInterval? = nil, _ body: () throws -> T) throws -> T? {
        let fd = openCoordinationLock(path)
        guard fd >= 0 else { throw FileError.io("lock open \(errno)") }
        defer { close(fd) }
        let base = exclusive ? LOCK_EX : LOCK_SH
        if let timeout, blocking {
            let deadline = Date().addingTimeInterval(timeout)
            while retryOnInterrupt({ flock(fd, base | LOCK_NB) }) != 0 {
                guard errno == EWOULDBLOCK else { throw FileError.io("flock \(errno)") }
                if Date() >= deadline { return nil }
                usleep(5_000)
            }
        } else if retryOnInterrupt({ flock(fd, base | (blocking ? 0 : LOCK_NB)) }) != 0 {
            if !blocking && errno == EWOULDBLOCK { return nil }
            throw FileError.io("flock \(errno)")
        }
        defer { _ = retryOnInterrupt({ flock(fd, LOCK_UN) }) }
        return try body()
    }
}
