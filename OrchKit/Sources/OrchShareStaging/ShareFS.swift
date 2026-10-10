import Foundation

/// Hardened reads of files another process (the share extension, or a hostile writer of the group) may have shaped:
/// `O_NOFOLLOW`, regular files only (checked on the descriptor), hard byte cap.
enum ShareFS {
    enum ReadFailure: Error { case notFound, notRegular, tooBig, io(Int32) }

    static func readFile(_ url: URL, cap: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { throw errno == ENOENT ? ReadFailure.notFound : ReadFailure.io(errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw ReadFailure.io(errno) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw ReadFailure.notRegular }
        guard st.st_size <= off_t(cap) else { throw ReadFailure.tooBig }
        var out = Data()
        let size = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let n = read(fd, buffer, size)
            if n < 0 { throw ReadFailure.io(errno) }
            if n == 0 { break }
            out.append(buffer.assumingMemoryBound(to: UInt8.self), count: n)
            if out.count > cap { throw ReadFailure.tooBig }
        }
        return out
    }

    /// Resolved absolute path of an open descriptor (what the kernel really opened).
    static func realPath(of fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) == 0 else { return nil }
        return String(cString: buf)
    }

    static func canonical(_ url: URL) throws -> String {
        guard let p = realpath(url.path, nil) else { throw ShareError.io("realpath: \(errno)") }
        defer { free(p) }
        return String(cString: p)
    }

    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

enum JobID {
    /// Lowercase canonical UUID: the only job id shape the stager creates and the app accepts.
    static func isValid(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count == 36 else { return false }
        for (i, c) in u.enumerated() {
            if [8, 13, 18, 23].contains(i) { if c != 0x2d { return false } }
            else if !((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)) { return false }
        }
        return true
    }
}
