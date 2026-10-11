import Foundation

/// An open directory descriptor. Every operation on the share area is relative to one of these, so a path component
/// that is swapped for a symbolic link after it was verified can never redirect the operation: the kernel resolves
/// names against the descriptor, and each name is opened `O_NOFOLLOW`.
final class DirFD: @unchecked Sendable {
    let fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    deinit { close(fd) }
}

/// Hardened filesystem access for the share area, fd-relative throughout (no path is resolved after the root is opened).
enum ShareFS {
    enum ReadFailure: Error { case notFound, notRegular, tooBig, io(Int32) }

    static let dirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    // MARK: test seam

    /// Test seam: called after the walk opened component `index` (0 = the root itself) of a walk below `root`.
    typealias WalkHook = @Sendable (_ root: String, _ index: Int, _ name: String) -> Void
    private static let hookLock = NSLock()
    nonisolated(unsafe) private static var hook: WalkHook?
    static func setWalkHook(_ h: WalkHook?) { hookLock.lock(); hook = h; hookLock.unlock() }
    private static func fireHook(_ root: String, _ index: Int, _ name: String) {
        hookLock.lock(); let h = hook; hookLock.unlock()
        h?(root, index, name)
    }

    // MARK: walking

    /// A single path component: never empty, `.`, `..`, or anything with a separator or NUL.
    static func checkName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0x2f), !name.utf8.contains(0) else {
            throw ShareError.io("invalid path component")
        }
    }

    /// Opens the root of the share area (the final component must not be a link).
    static func openRoot(_ url: URL, create: Bool) throws -> DirFD {
        var fd = open(url.path, dirFlags)
        if fd < 0, errno == ENOENT, create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            fd = open(url.path, dirFlags)
        }
        guard fd >= 0 else { throw errno == ENOENT ? ReadFailure.notFound : ReadFailure.io(errno) }
        if create { protect(fd: fd, directory: true) }
        return DirFD(fd)
    }

    /// Opens (or, with `create`, makes) the child directory `name` of `parent`; a link or a file is refused.
    static func openDir(_ parent: DirFD, _ name: String, create: Bool = false) throws -> DirFD {
        try checkName(name)
        var fd = openat(parent.fd, name, dirFlags)
        if fd < 0, errno == ENOENT, create {
            if mkdirat(parent.fd, name, 0o700) != 0, errno != EEXIST { throw ReadFailure.io(errno) }
            fd = openat(parent.fd, name, dirFlags)
        }
        guard fd >= 0 else { throw errno == ENOENT ? ReadFailure.notFound : ReadFailure.io(errno) }
        if create { protect(fd: fd, directory: true) }
        return DirFD(fd)
    }

    /// Walks `components` below the root, one `openat(O_NOFOLLOW|O_DIRECTORY)` per component.
    static func walk(root rootURL: URL, _ components: [String], create: Bool = false) throws -> DirFD {
        var dir = try openRoot(rootURL, create: create)
        fireHook(rootURL.path, 0, "")
        for (i, part) in components.enumerated() {
            dir = try openDir(dir, part, create: create)
            fireHook(rootURL.path, i + 1, part)
        }
        return dir
    }

    // MARK: entries

    /// Entry names of a directory (excluding `.` and `..`), read from a dup of the descriptor.
    static func list(_ dir: DirFD) throws -> [String] {
        let d = dup(dir.fd)
        guard d >= 0 else { throw ReadFailure.io(errno) }
        guard let dp = fdopendir(d) else { let e = errno; close(d); throw ReadFailure.io(e) }
        defer { closedir(dp) }
        rewinddir(dp)
        var out: [String] = []
        while let ent = readdir(dp) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }

    static func statEntry(_ dir: DirFD, _ name: String) -> stat? {
        guard (try? checkName(name)) != nil else { return nil }
        var st = stat()
        return fstatat(dir.fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 ? st : nil
    }

    static func isDirectory(_ dir: DirFD, _ name: String) -> Bool {
        guard let st = statEntry(dir, name) else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func isRegular(_ dir: DirFD, _ name: String) -> Bool {
        guard let st = statEntry(dir, name) else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    /// Opens a regular file for reading (`O_NOFOLLOW`).
    static func openFile(_ dir: DirFD, _ name: String) throws -> Int32 {
        try checkName(name)
        let fd = openat(dir.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { throw errno == ENOENT ? ReadFailure.notFound : ReadFailure.io(errno) }
        return fd
    }

    static func readFile(_ dir: DirFD, _ name: String, cap: Int) throws -> Data {
        let fd = try openFile(dir, name)
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

    /// Atomic replace: a fresh `O_EXCL` temporary beside the target, fsync, then `renameat`.
    static func writeAtomic(_ dir: DirFD, _ name: String, _ data: Data) throws {
        try checkName(name)
        let tmp = ".\(name).tmp-\(UUID().uuidString.lowercased())"
        let fd = openat(dir.fd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ShareError.io("create: \(errno)") }
        var ok = false
        defer { close(fd); if !ok { unlinkat(dir.fd, tmp, 0) } }
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let w = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if w < 0 { throw ShareError.io("write: \(errno)") }
                off += w
            }
        }
        fsync(fd)
        protect(fd: fd, directory: false)
        guard renameat(dir.fd, tmp, dir.fd, name) == 0 else { throw ShareError.io("rename: \(errno)") }
        ok = true
    }

    static func rename(_ fromDir: DirFD, _ from: String, _ toDir: DirFD, _ to: String) -> Bool {
        guard (try? checkName(from)) != nil, (try? checkName(to)) != nil else { return false }
        return renameat(fromDir.fd, from, toDir.fd, to) == 0
    }

    /// Removes `name` below `parent` without following links: a link or file is unlinked itself, a directory is
    /// emptied through descriptors (never by path) and then removed. A missing entry counts as removed.
    @discardableResult
    static func removeTree(_ parent: DirFD, _ name: String, depth: Int = 0) -> Bool {
        guard (try? checkName(name)) != nil, depth < 64 else { return false }
        var st = stat()
        if fstatat(parent.fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0 { return errno == ENOENT }
        if (st.st_mode & S_IFMT) != S_IFDIR { return unlinkat(parent.fd, name, 0) == 0 }
        let fd = openat(parent.fd, name, dirFlags)
        guard fd >= 0 else { return errno == ENOENT }
        let child = DirFD(fd)
        guard let names = try? list(child) else { return false }
        var ok = true
        for n in names where !removeTree(child, n, depth: depth + 1) { ok = false }
        guard ok else { return false }
        return unlinkat(parent.fd, name, AT_REMOVEDIR) == 0
    }

    /// Complete protection and backup exclusion, on the descriptor (iOS data protection is a no-op elsewhere).
    static func protect(fd: Int32, directory: Bool) {
        #if os(iOS)
        _ = fcntl(fd, F_SETPROTECTIONCLASS, 1)   // class A = NSFileProtectionComplete
        #endif
        if directory {
            var one: UInt8 = 1
            _ = fsetxattr(fd, "com.apple.MobileBackup", &one, 1, 0, 0)
        }
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
