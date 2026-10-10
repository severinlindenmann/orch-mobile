import Foundation
import OrchCoordination

/// One in-progress share (extension side). Every filesystem write happens inside
/// `TombstoneCoordination.ifNotRemoved(realm:ws:generation:)`, so a workspace wipe (exclusive writer of the same lock)
/// can never interleave with a staged write (A11). The job becomes visible to the app only when the atomic `READY`
/// marker is written last; until then it is a partial job that cancel or the janitor removes.
public final class StagingSession: @unchecked Sendable {
    private let area: ShareArea
    private let target: ShareTarget
    private let jobID: String
    private let jobDir: URL
    private let now: @Sendable () -> Date
    private let strictForbidden: [String]
    private let providerForbidden: [String]
    private let lock = NSLock()
    private var items: [StagedItem] = []
    private var total = 0
    private var finished = false

    /// - Parameter extraForbiddenRoots: App Group containers (and anything else) that must never be a copy source.
    public init(area: ShareArea, target: ShareTarget, jobID: String = UUID().uuidString.lowercased(),
                extraForbiddenRoots: [URL] = [], now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard JobID.isValid(jobID) else { throw ShareError.io("invalid job id") }
        self.area = area; self.target = target; self.jobID = jobID; self.now = now
        jobDir = try area.stagingDir(realm: target.realm, ws: target.ws).appendingPathComponent(jobID, isDirectory: true)
        let always = ([area.shareGroupRoot] + extraForbiddenRoots).map(ShareFS.canonical)
        providerForbidden = always
        strictForbidden = always + [ShareFS.canonical(URL(fileURLWithPath: NSHomeDirectory()))]
    }

    public var id: String { jobID }
    public var itemCount: Int { lock.lock(); defer { lock.unlock() }; return items.count }

    /// Copies (streaming) or writes one item. Throws `.tooManyItems` / `.tooLarge` / `.unsupported` without keeping bytes.
    public func add(_ input: ShareInput) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { throw ShareError.cancelled }
        guard items.count < ShareLimits.maxItems else { throw ShareError.tooManyItems }
        let remaining = ShareLimits.maxTotalBytes - total
        let n = items.count + 1
        let fileName = "item-\(n)"
        let item = try guarded {
            try area.ensureDirectory(jobDir)
            let dest = jobDir.appendingPathComponent(fileName)
            switch input {
            case .providerCopy(let url, let name, let type):
                let bytes = try Self.streamCopy(from: url, to: dest, limit: remaining, forbidden: providerForbidden)
                return StagedItem(name: Self.clean(name, fallback: "File"), kind: .file, type: type.map { String($0.prefix(255)) }, bytes: bytes, file: fileName)
            case .file(let url, let name, let type):
                let bytes = try Self.streamCopy(from: url, to: dest, limit: remaining, forbidden: strictForbidden)
                return StagedItem(name: Self.clean(name, fallback: "File"), kind: .file, type: type.map { String($0.prefix(255)) }, bytes: bytes, file: fileName)
            case .text(let text):
                let data = Data(text.utf8)
                guard !data.isEmpty else { throw ShareError.empty }
                guard data.count <= remaining else { throw ShareError.tooLarge }
                try Self.writeFile(data, to: dest)
                return StagedItem(name: "Note", kind: .text, type: "public.plain-text", bytes: data.count, file: fileName)
            case .url(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= ShareLimits.maxURLCharacters,
                      !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      let u = URL(string: trimmed), u.scheme != nil else { throw ShareError.unsupported("url") }
                let data = Data(trimmed.utf8)
                guard data.count <= remaining else { throw ShareError.tooLarge }
                try Self.writeFile(data, to: dest)
                return StagedItem(name: "Link", kind: .url, type: "public.url", bytes: data.count, file: fileName)
            }
        }
        items.append(item)
        total += item.bytes
    }

    /// Writes the manifest, then the atomic READY marker. Returns the job id.
    @discardableResult
    public func commit(note: String?) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { throw ShareError.cancelled }
        guard !items.isEmpty else { throw ShareError.empty }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = JobManifest(jobID: jobID, realm: target.realm, ws: target.ws, generation: target.generation,
                                   createdAt: now().timeIntervalSince1970,
                                   note: (trimmed?.isEmpty ?? true) ? nil : String(trimmed!.prefix(ShareLimits.maxNoteCharacters)),
                                   items: items)
        try guarded {
            let data = try JSONEncoder().encode(manifest)
            try Self.writeFile(data, to: jobDir.appendingPathComponent(JobFiles.manifest))
            try Self.writeFile(Data("1".utf8), to: jobDir.appendingPathComponent(JobFiles.ready))
        }
        finished = true
        return jobID
    }

    /// Removes every partial copy. Safe to call at any time and more than once.
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        try? FileManager.default.removeItem(at: jobDir)
    }

    /// Runs `body` inside ifNotRemoved. A removed or unreadable workspace aborts and deletes the partial job.
    private func guarded<T>(_ body: () throws -> T) throws -> T {
        do {
            guard let result = try area.coordination.ifNotRemoved(realm: target.realm, ws: target.ws, generation: target.generation, body) else {
                finished = true
                try? FileManager.default.removeItem(at: jobDir)
                throw ShareError.destinationRemoved
            }
            return result
        } catch let e as ShareError {
            switch e {
            case .tooLarge, .unsupported, .empty: dropPartial()
            default: break
            }
            throw e
        } catch {
            try? FileManager.default.removeItem(at: jobDir)
            finished = true
            throw ShareError.io("\(error)")
        }
    }

    /// A refused item leaves earlier items in place but never its own partial file.
    private func dropPartial() {
        try? FileManager.default.removeItem(at: jobDir.appendingPathComponent("item-\(items.count + 1)"))
    }

    /// Display name only: last path component, no control, format (bidi) or separator characters, capped by scalars.
    static func clean(_ name: String, fallback: String) -> String {
        let last = (name as NSString).lastPathComponent
        let kept = last.unicodeScalars.filter { s in
            switch s.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: false
            default: true
            }
        }
        let stripped = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty { return fallback }
        return String(String.UnicodeScalarView(stripped.unicodeScalars.prefix(ShareLimits.maxNameCharacters)))
    }

    static func writeFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        ShareArea.protect(url)
    }

    /// Streaming copy with the limit enforced on the bytes actually read (the reported size is never trusted). The
    /// source is opened `O_NOFOLLOW`, judged on the open descriptor (regular file, real path outside `forbidden`).
    static func streamCopy(from src: URL, to dest: URL, limit: Int, forbidden: [String]) throws -> Int {
        let inFD = open(src.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard inFD >= 0 else {
            if errno == ELOOP { throw ShareError.unsupported("not a regular file") }
            throw ShareError.io("open source: \(errno)")
        }
        defer { close(inFD) }
        var st = stat()
        guard fstat(inFD, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw ShareError.unsupported("not a regular file") }
        guard let real = ShareFS.realPath(of: inFD) else { throw ShareError.unsupported("unresolvable source") }
        for root in forbidden where ShareFS.isInside(real, root: root) { throw ShareError.unsupported("source not allowed") }
        let outFD = open(dest.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outFD >= 0 else { throw ShareError.io("create: \(errno)") }
        var ok = false
        defer { close(outFD); if !ok { try? FileManager.default.removeItem(at: dest) } }
        let size = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var copied = 0
        while true {
            let n = read(inFD, buffer, size)
            if n < 0 { throw ShareError.io("read: \(errno)") }
            if n == 0 { break }
            copied += n
            guard copied <= limit else { throw ShareError.tooLarge }
            var off = 0
            while off < n {
                let w = Darwin.write(outFD, buffer + off, n - off)
                if w < 0 { throw ShareError.io("write: \(errno)") }
                off += w
            }
        }
        fsync(outFD)
        ok = true
        ShareArea.protect(dest)
        return copied
    }
}
