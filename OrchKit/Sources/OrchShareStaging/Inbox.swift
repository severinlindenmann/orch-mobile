import Foundation
import OrchCoordination

public struct StagedJob: Equatable, Sendable {
    public let manifest: JobManifest
    public let dir: URL
}

public struct ClaimResult: Equatable, Sendable {
    public var claimed: [StagedJob] = []
    public var quarantined: [StagedJob] = []
}

/// A destination the app currently considers live.
public struct LiveDestination: Hashable, Sendable {
    public let realm: String
    public let ws: String
    public let generation: Int64
    public init(realm: String, ws: String, generation: Int64) { self.realm = realm; self.ws = ws; self.generation = generation }
}

/// App side of the outbox: claim ready jobs, quarantine orphans, read contents, delete after import, janitor.
public struct ShareInbox: Sendable {
    public let area: ShareArea
    public init(area: ShareArea) { self.area = area }

    /// Ready jobs without claiming them (diagnostics, tests). Includes jobs already renamed `.claimed`.
    public func peekReady() -> [StagedJob] { jobs(in: area.stagingRoot, requireReady: true) }

    public func quarantined() -> [StagedJob] { jobs(in: area.quarantineRoot, requireReady: false) }

    /// Claims ready jobs of `realm` (nil = every realm) whose destination is live: renamed to `<job>.claimed`, so a
    /// later claim never sees them as new. Jobs of other realms stay untouched. A job whose destination is gone, or
    /// whose generation differs, moves to quarantine: never redirected to another workspace.
    /// - Parameter includeClaimed: startup recovery. An import that crashed after the rename left `<job>.claimed`;
    ///   only the recovery pass may hand those out again, so a claim that is still being imported is never re-issued.
    public func claim(live: Set<LiveDestination>, realm: String? = nil, includeClaimed: Bool = true) -> ClaimResult {
        var result = ClaimResult()
        let fm = FileManager.default
        for job in jobs(in: area.stagingRoot, requireReady: true) {
            let m = job.manifest
            if let realm, m.realm != realm { continue }
            let isLive = live.contains(LiveDestination(realm: m.realm, ws: m.ws, generation: m.generation))
            guard let base = try? area.stagingDir(realm: m.realm, ws: m.ws) else { continue }
            let alreadyClaimed = job.dir.lastPathComponent.hasSuffix(JobFiles.claimedSuffix)
            if isLive {
                if alreadyClaimed {
                    if includeClaimed { result.claimed.append(job) }
                    continue
                }
                let claimed = base.appendingPathComponent(m.jobID + JobFiles.claimedSuffix, isDirectory: true)
                if rename(job.dir.path, claimed.path) == 0 { result.claimed.append(StagedJob(manifest: m, dir: claimed)) }
            } else if let q = try? area.quarantineDir(realm: m.realm, ws: m.ws) {
                do {
                    try area.ensureDirectory(q)
                    let dest = q.appendingPathComponent(m.jobID, isDirectory: true)
                    area.safeRemove(dest)
                    guard rename(job.dir.path, dest.path) == 0 else { throw ShareError.io("rename") }
                    result.quarantined.append(StagedJob(manifest: m, dir: dest))
                } catch { /* stays staged; the next pass retries, the janitor bounds it */ }
            }
        }
        // A job that is now claimed may also still sit in quarantine (a redirect interrupted before it removed the
        // original): the claimed copy wins, the original is dropped.
        if !result.claimed.isEmpty {
            let ids = Set(result.claimed.map(\.manifest.jobID))
            for q in quarantined() where ids.contains(q.manifest.jobID) { area.safeRemove(q.dir) }
        }
        return result
    }

    /// Text for text/URL items: `O_NOFOLLOW`, regular file, capped at `maxBytes` (display needs far less than a job).
    public func text(of item: StagedItem, in job: StagedJob, maxBytes: Int = 16 * 1024) -> String? {
        guard item.kind != .file, item.bytes >= 0, item.file.hasPrefix("item-"), !item.file.contains("/") else { return nil }
        guard area.isRealDirectoryChain(job.dir),
              let data = try? ShareFS.readFile(job.dir.appendingPathComponent(item.file), cap: ShareLimits.maxTotalBytes) else { return nil }
        return String(decoding: data.prefix(maxBytes), as: UTF8.self)
    }

    /// Deletes the staged plaintext after the app has imported it.
    public func complete(_ job: StagedJob) { area.safeRemove(job.dir) }

    // MARK: durable import ledger (idempotency by full job id)

    private var ledgerURL: URL { area.shareDir.appendingPathComponent("imported.json") }

    public func wasImported(_ jobID: String) -> Bool { ledger().contains(jobID) }

    public func markImported(_ jobID: String) {
        var ids = ledger().filter { $0 != jobID }
        ids.append(jobID)
        if ids.count > 500 { ids.removeFirst(ids.count - 500) }
        guard let data = try? JSONEncoder().encode(ids), (try? area.ensureDirectory(area.shareDir)) != nil else { return }
        try? data.write(to: ledgerURL, options: .atomic)
        ShareArea.protect(ledgerURL)
    }

    private func ledger() -> [String] {
        guard let data = try? ShareFS.readFile(ledgerURL, cap: 64 * 1024) else { return [] }
        return ((try? JSONDecoder().decode([String].self, from: data)) ?? []).filter(JobID.isValid)
    }

    // MARK: redirect

    /// Moves a quarantined job to a destination the user chose, as copy-then-delete under the destination's
    /// tombstone lock: the new job is built in `<id>.redirect` (invisible to claim), becomes `<id>.claimed` with one
    /// rename, and only then is the quarantined original removed. An interruption at any point leaves the original
    /// in quarantine (and at worst a duplicate that the next claim collapses).
    /// - Parameter beforeRemovingOriginal: test seam for the interruption between publish and delete.
    public func redirect(_ job: StagedJob, to target: LiveDestination, beforeRemovingOriginal: (() throws -> Void)? = nil) throws -> StagedJob {
        let fm = FileManager.default
        let quarantinePath = ShareFS.canonical(area.quarantineRoot)
        guard ShareFS.isInside(ShareFS.canonical(job.dir), root: quarantinePath), job.dir.lastPathComponent == job.manifest.jobID,
              area.isRealDirectoryChain(job.dir), job.manifest.isValid() else { throw ShareError.io("not a quarantined job") }
        var m = job.manifest
        m.realm = target.realm; m.ws = target.ws; m.generation = target.generation
        guard m.isValid() else { throw ShareError.io("invalid destination") }
        let base = try area.stagingDir(realm: m.realm, ws: m.ws)
        let published: StagedJob? = try area.coordination.ifNotRemoved(realm: target.realm, ws: target.ws, generation: target.generation) {
            try area.ensureDirectory(base)
            let building = base.appendingPathComponent(m.jobID + ".redirect", isDirectory: true)
            area.safeRemove(building)
            try fm.createDirectory(at: building, withIntermediateDirectories: false)
            do {
                for item in m.items {
                    let src = job.dir.appendingPathComponent(item.file)
                    var st = stat()
                    guard lstat(src.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw ShareError.unsupported("item") }
                    try fm.copyItem(at: src, to: building.appendingPathComponent(item.file))
                }
                try JSONEncoder().encode(m).write(to: building.appendingPathComponent(JobFiles.manifest), options: .atomic)
                try Data("1".utf8).write(to: building.appendingPathComponent(JobFiles.ready), options: .atomic)
                let final = base.appendingPathComponent(m.jobID + JobFiles.claimedSuffix, isDirectory: true)
                area.safeRemove(final)
                guard rename(building.path, final.path) == 0 else { throw ShareError.io("rename") }
                return StagedJob(manifest: m, dir: final)
            } catch {
                area.safeRemove(building)
                throw error
            }
        }
        guard let published else { throw ShareError.destinationRemoved }
        try beforeRemovingOriginal?()
        area.safeRemove(job.dir)
        return published
    }

    // MARK: wipe support

    /// Removes everything staged or quarantined for the workspace, whatever the generation (tests, hard reset).
    public func purge(realm: String, ws: String) {
        for dir in [try? area.stagingDir(realm: realm, ws: ws), try? area.quarantineDir(realm: realm, ws: ws)] {
            if let dir { area.safeRemove(dir) }
        }
    }

    /// Resumable half of the wipe (A11 phase 3 for the share group): deletes every staged, claimed and quarantined
    /// job whose destination a persisted tombstone covers. The tombstone is the durable "pending cleanup" record, so a
    /// failed deletion is simply retried by the next call; jobs of a newer generation are never touched.
    @discardableResult
    public func purgeTombstoned() -> (removed: Int, failed: Int) {
        guard let records = try? area.coordination.records(), !records.isEmpty else { return (0, 0) }
        var removed = 0, failed = 0
        let fm = FileManager.default
        for root in [area.stagingRoot, area.quarantineRoot] {
            for dir in jobDirectories(in: root) {
                let ws = dir.deletingLastPathComponent().lastPathComponent
                let realm = dir.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                let generation = manifest(at: dir)?.generation ?? Int64.min  // unreadable: covered by any tombstone of the ws
                guard records.contains(where: { $0.realm == realm && $0.ws == ws && generation <= $0.generation }) else { continue }
                if area.safeRemove(dir) { removed += 1 } else { failed += 1 }
            }
        }
        return (removed, failed)
    }

    /// Expiry janitor: removes READY/claimed/quarantined jobs older than seven days and partial jobs older than an hour.
    @discardableResult
    public func sweep(now: Date = Date(), expiry: TimeInterval = ShareLimits.sevenDays, partialTTL: TimeInterval = ShareLimits.partialTTL) -> Int {
        var removed = 0
        let fm = FileManager.default
        for root in [area.stagingRoot, area.quarantineRoot] {
            for dir in jobDirectories(in: root) {
                let ready = hasReady(dir)
                let manifest = manifest(at: dir)
                let age: TimeInterval
                if ready, let manifest { age = now.timeIntervalSince1970 - manifest.createdAt }
                else {
                    let attrs = try? fm.attributesOfItem(atPath: dir.path)
                    let stamp = (attrs?[.modificationDate] as? Date) ?? (attrs?[.creationDate] as? Date) ?? .distantPast
                    age = now.timeIntervalSince(stamp)
                }
                let limit = (ready && manifest != nil) ? expiry : (root == area.quarantineRoot ? expiry : partialTTL)
                if age > limit { area.safeRemove(dir); removed += 1 }
            }
        }
        return removed
    }

    // MARK: scanning

    private func manifest(at dir: URL) -> JobManifest? {
        guard let data = try? ShareFS.readFile(dir.appendingPathComponent(JobFiles.manifest), cap: 64 * 1024),
              let m = try? JSONDecoder().decode(JobManifest.self, from: data), m.isValid() else { return nil }
        return m
    }

    /// <root>/<realm>/<ws>/<job> directories. Every level is a real directory (lstat: symbolic links are never
    /// followed), the realm and ws names are the exact ASCII shapes the stager creates (case-sensitive, no
    /// look-alikes), and the job directory's real path equals the path built from those names.
    private func jobDirectories(in root: URL) -> [URL] {
        guard area.isRealDirectoryChain(root) else { return [] }
        let canonicalRoot = ShareFS.canonical(root)
        func children(_ url: URL, valid: (String) -> Bool) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).compactMap { name in
                guard valid(name) else { return nil }
                let child = url.appendingPathComponent(name, isDirectory: true)
                return ShareArea.isRealDirectory(child) ? child : nil
            }
        }
        let realmOK: (String) -> Bool = { (try? ShareArea.validate(realm: $0, ws: String(repeating: "a", count: 32))) != nil }
        let wsOK: (String) -> Bool = { (try? ShareArea.validate(realm: "x", ws: $0)) != nil }
        var out: [URL] = []
        for realm in children(root, valid: realmOK) {
            for ws in children(realm, valid: wsOK) {
                for job in children(ws, valid: { $0.utf8.allSatisfy { $0 < 0x80 } && !$0.isEmpty && !$0.contains("/") }) {
                    let expected = canonicalRoot + "/" + realm.lastPathComponent + "/" + ws.lastPathComponent + "/" + job.lastPathComponent
                    if ShareFS.canonical(job) == expected { out.append(job) }
                }
            }
        }
        return out
    }

    private func hasReady(_ dir: URL) -> Bool {
        var st = stat()
        return lstat(dir.appendingPathComponent(JobFiles.ready).path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    private func jobs(in root: URL, requireReady: Bool) -> [StagedJob] {
        var out: [StagedJob] = []
        for dir in jobDirectories(in: root) {
            if requireReady, !hasReady(dir) { continue }
            guard let m = manifest(at: dir) else {
                // READY without a valid manifest cannot be imported: drop it. (A half-built job has no READY.)
                if requireReady { area.safeRemove(dir) }
                continue
            }
            // The path is authoritative for the destination and the job id; a manifest that disagrees is corrupt.
            // Compared as exact bytes (String == would accept canonically equivalent Unicode).
            let name = dir.lastPathComponent
            let ws = dir.deletingLastPathComponent().lastPathComponent
            let realm = dir.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            func same(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }
            let nameOK = root == area.quarantineRoot ? same(name, m.jobID) : (same(name, m.jobID) || same(name, m.jobID + JobFiles.claimedSuffix))
            guard same(m.ws, ws), same(m.realm, realm), nameOK else { area.safeRemove(dir); continue }
            out.append(StagedJob(manifest: m, dir: dir))
        }
        return out.sorted { $0.manifest.createdAt < $1.manifest.createdAt }
    }
}
