import Foundation

/// All entries are resolved relative to the directory held open for the whole lock transaction.
enum TombstoneFS {
    static let cap = 4 * 1024 * 1024

    static func regular(_ fd: Int32) throws {
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size >= 0, st.st_size <= cap else { throw TombstoneError.io("not a bounded regular file") }
    }

    static func read(_ dir: Int32, _ name: String) throws -> Data? {
        let fd = retryOnInterrupt({ openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) })
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw TombstoneError.io("open: \(errno)")
        }
        defer { close(fd) }
        try regular(fd)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; throw TombstoneError.io("read: \(errno)") }
            if n == 0 { return data }
            guard data.count + n <= cap else { throw TombstoneError.io("file exceeds size cap") }
            data.append(contentsOf: buffer.prefix(n))
        }
    }

    static func write(_ data: Data, dir: Int32, name: String) throws {
        guard data.count <= cap else { throw TombstoneError.io("file exceeds size cap") }
        let tmp = ".\(name).tmp-\(UUID().uuidString)"
        let fd = retryOnInterrupt({ openat(dir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) })
        guard fd >= 0 else { throw TombstoneError.io("create: \(errno)") }
        defer { close(fd); unlinkat(dir, tmp, 0) }
        try regular(fd)
        #if os(iOS)
        // Preserve completeUntilFirstUserAuthentication without resolving the temporary path again.
        guard fcntl(fd, F_SETPROTECTIONCLASS, 3) == 0 else { throw TombstoneError.io("protection: \(errno)") }
        #endif
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw TombstoneError.io("write: \(errno)") }
                offset += n
            }
        }
        guard retryOnInterrupt({ fsync(fd) }) == 0 else { throw TombstoneError.io("fsync: \(errno)") }
        guard renameat(dir, tmp, dir, name) == 0 else { throw TombstoneError.io("rename: \(errno)") }
        guard retryOnInterrupt({ fsync(dir) }) == 0 else { throw TombstoneError.io("directory fsync: \(errno)") }
    }
}
