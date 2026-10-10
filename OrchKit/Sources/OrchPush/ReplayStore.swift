import Foundation
import OrchProtocol

public enum ReplayStoreError: Error, Equatable, Sendable {
    case io(String)
    /// The state file did not parse. It is removed (fail closed for this one push; the next push starts fresh).
    case corrupt
    /// A newer generation of this workspace already has state: the caller's material is stale.
    case newerGeneration
}

/// Per `(realm, ws, generation)` replay state in the push App Group (decision A8):
/// `<pushDir>/state/<realm>/<ws>/replay.<generation>.json`, the same directory `StoreLayout.pushStateDir` names and the
/// workspace wipe removes (phase 3), so the state lives and dies with its workspace.
///
/// Writes are crash-safe (temp file, fsync, rename, directory fsync) and carry file protection
/// `completeUntilFirstUserAuthentication` (the NSE runs while the phone is locked after first unlock). The store does
/// NOT check removal itself: the notification extension must call `transact` only from inside
/// `TombstoneCoordination.ifNotRemoved` (check and write under one shared lock). A per-workspace exclusive flock
/// here serialises concurrent extension processes.
public struct ReplayStore: Sendable {
    public let pushDir: URL
    public let realm: String
    public init(pushDir: URL, realm: String) { self.pushDir = pushDir; self.realm = realm }

    public func stateDir(workspace: ID16) -> URL {
        pushDir.appendingPathComponent("state", isDirectory: true).appendingPathComponent(realm, isDirectory: true)
            .appendingPathComponent(workspace.hex, isDirectory: true)
    }

    func fileURL(workspace: ID16, generation: Int64) -> URL {
        stateDir(workspace: workspace).appendingPathComponent("replay.\(generation).json")
    }

    private struct File: Codable {
        struct Entry: Codable { let id: String; let ts: Int64 }
        let v: Int, realm: String, ws: String, generation: Int64, maxShownTs: Int64, lastShown: [Entry]
    }

    /// Read-only snapshot (no lock held after return); nil when there is no state.
    public func load(workspace: ID16, generation: Int64) throws -> PushProcessor.WorkspaceReplay? {
        try read(workspace: workspace, generation: generation)
    }

    /// Runs `body` with the persisted state under the workspace's exclusive lock. If `body` returns a next state it
    /// is persisted durably BEFORE `transact` returns (so before anything is shown).
    public func transact<T>(workspace: ID16, generation: Int64,
                            _ body: (PushProcessor.WorkspaceReplay) throws -> (T, PushProcessor.WorkspaceReplay?)) throws -> T {
        let dir = stateDir(workspace: workspace)
        try Self.makeDir(dir)
        let fd = open(dir.appendingPathComponent("replay.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ReplayStoreError.io("lock open \(errno)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ReplayStoreError.io("flock \(errno)") }
        defer { flock(fd, LOCK_UN) }

        try dropOlderGenerations(workspace: workspace, generation: generation)
        let current = try read(workspace: workspace, generation: generation) ?? PushProcessor.WorkspaceReplay()
        let (result, next) = try body(current)
        if let next, !next.isEmpty { try write(next, workspace: workspace, generation: generation) }
        return result
    }

    private func generations(workspace: ID16) throws -> [Int64] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stateDir(workspace: workspace).path)) ?? []
        return names.compactMap { n in
            guard n.hasPrefix("replay."), n.hasSuffix(".json") else { return nil }
            return Int64(n.dropFirst("replay.".count).dropLast(".json".count))
        }
    }

    private func dropOlderGenerations(workspace: ID16, generation: Int64) throws {
        for g in try generations(workspace: workspace) {
            if g > generation { throw ReplayStoreError.newerGeneration }
            if g < generation { try? FileManager.default.removeItem(at: fileURL(workspace: workspace, generation: g)) }
        }
    }

    private func read(workspace: ID16, generation: Int64) throws -> PushProcessor.WorkspaceReplay? {
        let url = fileURL(workspace: workspace, generation: generation)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let e as NSError where (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError) || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT)) { return nil }
        catch { throw ReplayStoreError.io("read \(error)") }
        guard let f = try? JSONDecoder().decode(File.self, from: data), f.v == 1, f.realm == realm, f.ws == workspace.hex, f.generation == generation else {
            try? FileManager.default.removeItem(at: url)
            throw ReplayStoreError.corrupt
        }
        var last: [Data: Int64] = [:]
        for e in f.lastShown {
            guard let id = B64U.decode(e.id) else { try? FileManager.default.removeItem(at: url); throw ReplayStoreError.corrupt }
            last[id] = e.ts
        }
        return PushProcessor.WorkspaceReplay(lastShown: last, maxShownTs: f.maxShownTs)
    }

    private func write(_ s: PushProcessor.WorkspaceReplay, workspace: ID16, generation: Int64) throws {
        let f = File(v: 1, realm: realm, ws: workspace.hex, generation: generation, maxShownTs: s.maxShownTs,
                     lastShown: s.lastShown.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map { .init(id: B64U.encode($0.key), ts: $0.value) })
        let dir = stateDir(workspace: workspace)
        try Self.atomicWrite(try JSONEncoder().encode(f), to: fileURL(workspace: workspace, generation: generation), dir: dir)
    }

    // MARK: files

    /// Temp file in the same directory, fsync, rename over the target, fsync the directory.
    static func atomicWrite(_ data: Data, to url: URL, dir: URL) throws {
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ReplayStoreError.io("tmp open \(errno)") }
        var ok = false
        defer { close(fd); if !ok { unlink(tmp.path) } }
        try data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Foundation.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; throw ReplayStoreError.io("write \(errno)") }
                off += n
            }
        }
        guard fsync(fd) == 0 else { throw ReplayStoreError.io("fsync \(errno)") }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: tmp.path)
        #endif
        guard rename(tmp.path, url.path) == 0 else { throw ReplayStoreError.io("rename \(errno)") }
        ok = true
        let dfd = open(dir.path, O_RDONLY | O_CLOEXEC)
        if dfd >= 0 { _ = fsync(dfd); close(dfd) }
    }

    static func makeDir(_ url: URL) throws {
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { throw ReplayStoreError.io("mkdir \(error)") }
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
