import Foundation
import OrchCoordination
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

    /// Content-free per-(realm, ws) high-water mark OUTSIDE the state directory (so a wipe, which removes the state
    /// directory, does not remove it): `<pushDir>/floor/<realm>/<ws>.json` = `{"v":1,"notBeforeTs":n}`. It is the highest
    /// `ts_ms` ever shown for the workspace. A new generation (rejoin) or a recovered state starts above it, so a relay
    /// cannot replay a push that was already shown before the wipe or the corruption.
    func floorURL(workspace: ID16) -> URL {
        pushDir.appendingPathComponent("floor", isDirectory: true).appendingPathComponent(realm, isDirectory: true)
            .appendingPathComponent("\(workspace.hex).json")
    }

    private struct Floor: Codable { let v: Int; let notBeforeTs: Int64 }

    public func floor(workspace: ID16) -> Int64 {
        if case .value(let v) = readFloor(workspace: workspace) { return v }
        return Int64.min
    }

    private enum FloorState { case missing, value(Int64), corrupt }

    private func readFloor(workspace: ID16) -> FloorState {
        let d: Data
        do { d = try Data(contentsOf: floorURL(workspace: workspace)) }
        catch let e as NSError where (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError) || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT)) { return .missing }
        catch { return .corrupt }
        guard let f = try? JSONDecoder().decode(Floor.self, from: d), f.v == 1 else { return .corrupt }
        return .value(f.notBeforeTs)
    }

    /// A floor file that exists but does not parse fails CLOSED: it is treated as `nowMs` and rewritten as such (a
    /// missing file is the only "no history").
    private func effectiveFloor(workspace: ID16, nowMs: Int64) throws -> Int64 {
        switch readFloor(workspace: workspace) {
        case .missing: return Int64.min
        case .value(let v): return v
        case .corrupt:
            let url = floorURL(workspace: workspace)
            try Self.makeDir(url.deletingLastPathComponent())
            try Self.atomicWrite(try JSONEncoder().encode(Floor(v: 1, notBeforeTs: nowMs)), to: url, dir: url.deletingLastPathComponent())
            return nowMs
        }
    }

    /// Raises the floor to at least `ts` (monotonic). Also the hook for a workspace wipe: call with the wipe time.
    public func raiseFloor(workspace: ID16, to ts: Int64) throws {
        guard ts > floor(workspace: workspace) else { return }
        let url = floorURL(workspace: workspace)
        try Self.makeDir(url.deletingLastPathComponent())
        try Self.atomicWrite(try JSONEncoder().encode(Floor(v: 1, notBeforeTs: ts)), to: url, dir: url.deletingLastPathComponent())
    }

    private struct File: Codable {
        struct Entry: Codable { let id: String; let ts: Int64 }
        let v: Int, realm: String, ws: String, generation: Int64, maxShownTs: Int64, notBeforeTs: Int64, lastShown: [Entry]
    }

    /// Read-only snapshot: never mutates anything, throws `.corrupt` for an unparseable file (recovery happens only
    /// inside `transact`, under the lock). Nil when there is no state.
    public func load(workspace: ID16, generation: Int64) throws -> PushProcessor.WorkspaceReplay? {
        try read(workspace: workspace, generation: generation)
    }

    /// Runs `body` with the persisted state under the workspace's exclusive lock. If `body` returns a next state it
    /// is persisted durably BEFORE `transact` returns (so before anything is shown), and the floor follows `maxShownTs`.
    ///
    /// No state yet for this generation: it starts with `notBeforeTs` = the floor (history of earlier generations).
    /// Corrupt state: the file is moved aside (`replay.<g>.json.corrupt`, one copy), a fresh state with
    /// `notBeforeTs = max(floor, nowMs)` is written at once, and `body` sees it: the push that hit the corruption and
    /// everything shown earlier cannot show again, only pushes strictly newer than the recovery.
    ///
    /// `lockTimeout`: give up (throw `.io("lock")`) if the workspace's replay lock is not free in time.
    public func transact<T>(workspace: ID16, generation: Int64, nowMs: Int64, lockTimeout: TimeInterval? = nil,
                            _ body: (PushProcessor.WorkspaceReplay) throws -> (T, PushProcessor.WorkspaceReplay?)) throws -> T {
        let dir = stateDir(workspace: workspace)
        try Self.makeDir(dir)
        guard let r = try CoordinationFiles.withFlock(dir.appendingPathComponent("replay.lock").path, timeout: lockTimeout, { () throws -> T in
            try dropOlderGenerations(workspace: workspace, generation: generation)
            var current: PushProcessor.WorkspaceReplay
            do {
                if let s = try read(workspace: workspace, generation: generation) { current = s }
                else { current = PushProcessor.WorkspaceReplay().with(notBeforeTs: try effectiveFloor(workspace: workspace, nowMs: nowMs)) }
            } catch ReplayStoreError.corrupt {
                let url = fileURL(workspace: workspace, generation: generation)
                _ = try? FileManager.default.removeItem(at: url.appendingPathExtension("corrupt"))
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
                current = PushProcessor.WorkspaceReplay().with(notBeforeTs: max(try effectiveFloor(workspace: workspace, nowMs: nowMs), nowMs))
                try write(current, workspace: workspace, generation: generation)
            }
            let (result, next) = try body(current)
            if let next, !next.isEmpty {
                try write(next, workspace: workspace, generation: generation)
                if next.maxShownTs != Int64.min { try raiseFloor(workspace: workspace, to: next.maxShownTs) }
            }
            return result
        }) else { throw ReplayStoreError.io("lock") }
        return r
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
            throw ReplayStoreError.corrupt
        }
        var last: [Data: Int64] = [:]
        for e in f.lastShown {
            guard let id = B64U.decode(e.id), id.count == 32 else { throw ReplayStoreError.corrupt }
            last[id] = e.ts
        }
        return PushProcessor.WorkspaceReplay(lastShown: last, maxShownTs: f.maxShownTs, notBeforeTs: f.notBeforeTs)
    }

    private func write(_ s: PushProcessor.WorkspaceReplay, workspace: ID16, generation: Int64) throws {
        let f = File(v: 1, realm: realm, ws: workspace.hex, generation: generation, maxShownTs: s.maxShownTs, notBeforeTs: s.notBeforeTs,
                     lastShown: s.lastShown.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map { .init(id: B64U.encode($0.key), ts: $0.value) })
        try Self.atomicWrite(try JSONEncoder().encode(f), to: fileURL(workspace: workspace, generation: generation), dir: stateDir(workspace: workspace))
    }

    // MARK: files

    static func atomicWrite(_ data: Data, to url: URL, dir: URL, durable: Bool = true) throws {
        do { try CoordinationFiles.atomicWrite(data, to: url, dir: dir, durable: durable) }
        catch CoordinationFiles.FileError.io(let m) { throw ReplayStoreError.io(m) }
    }

    static func makeDir(_ url: URL) throws {
        do { try CoordinationFiles.makeDir(url) } catch CoordinationFiles.FileError.io(let m) { throw ReplayStoreError.io(m) }
    }
}
