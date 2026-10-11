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
                if area.rename(job.dir, to: claimed) { result.claimed.append(StagedJob(manifest: m, dir: claimed)) }
            } else if let q = try? area.quarantineDir(realm: m.realm, ws: m.ws) {
                do {
                    try area.ensureDirectory(q)
                    let dest = q.appendingPathComponent(m.jobID, isDirectory: true)
                    area.safeRemove(dest)
                    guard area.rename(job.dir, to: dest) else { throw ShareError.io("rename") }
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
        guard let data = try? area.readFile(job.dir.appendingPathComponent(item.file), cap: ShareLimits.maxTotalBytes) else { return nil }
        return String(decoding: data.prefix(maxBytes), as: UTF8.self)
    }

    /// Bounded, no-follow read of a validated, claimed job item for sealing in the main app.
    public func contents(of item: StagedItem, in job: StagedJob) throws -> Data {
        guard job.manifest.isValid(), job.manifest.items.contains(item),
              peekReady().contains(job), job.dir.lastPathComponent == job.manifest.jobID + JobFiles.claimedSuffix else { throw ShareError.unreadable }
        let data = try area.readFile(job.dir.appendingPathComponent(item.file), cap: ShareLimits.maxTotalBytes)
        guard data.count == item.bytes else { throw ShareError.unreadable }
        return data
    }

    /// Deletes the staged plaintext after the app has imported it.
    @discardableResult
    public func complete(_ job: StagedJob) -> Bool { area.safeRemove(job.dir) }

    /// Called only after the workspace database has committed job completion. Keep discovery metadata until
    /// all plaintext is gone, so a failed deletion or interrupted cleanup is retried by the next recovery claim.
    /// The final metadata-only directory is also safe for the partial-job janitor after an interruption.
    package func cleanupCompleted(_ job: StagedJob,
                                  afterRemovingItem: (@Sendable (String) async throws -> Void)? = nil) async throws {
        let dir: DirFD
        do { dir = try area.openDir(job.dir) }
        catch ShareFS.ReadFailure.notFound { return }
        for name in try ShareFS.list(dir).sorted() where name != JobFiles.manifest && name != JobFiles.ready {
            guard ShareFS.removeTree(dir, name) else { throw ShareError.io("remove staged plaintext") }
            try await afterRemovingItem?("import.cleanup.removed:\(name)")
        }
        guard area.safeRemove(job.dir) else { throw ShareError.io("remove completed job") }
    }

    // MARK: durable import ledger (idempotency by full job id)

    private var ledgerURL: URL { area.shareDir.appendingPathComponent("imported.json") }

    public func wasImported(_ jobID: String) -> Bool { ledger().contains(jobID) }

    public func markImported(_ jobID: String) {
        var ids = ledger().filter { $0 != jobID }
        ids.append(jobID)
        if ids.count > 500 { ids.removeFirst(ids.count - 500) }
        guard let data = try? JSONEncoder().encode(ids), (try? area.ensureDirectory(area.shareDir)) != nil else { return }
        try? area.writeFile(data, to: ledgerURL)
    }

    private func ledger() -> [String] {
        guard let data = try? area.readFile(ledgerURL, cap: 64 * 1024) else { return [] }
        return ((try? JSONDecoder().decode([String].self, from: data)) ?? []).filter(JobID.isValid)
    }

    // MARK: redirect

    /// Moves a quarantined job to a destination the user chose, as copy-then-delete under the destination's
    /// tombstone lock: the new job is built in `<id>.redirect` (invisible to claim), becomes `<id>.claimed` with one
    /// rename, and only then is the quarantined original removed. An interruption at any point leaves the original
    /// in quarantine (and at worst a duplicate that the next claim collapses).
    /// - Parameter beforeRemovingOriginal: test seam for the interruption between publish and delete.
    public func redirect(_ job: StagedJob, to target: LiveDestination, beforeRemovingOriginal: (() throws -> Void)? = nil) throws -> StagedJob {
        // The job must sit at exactly <quarantine>/<realm>/<ws>/<jobID>; the walk below re-verifies every component.
        guard let rel = area.components(of: job.dir), let q = area.components(of: area.quarantineRoot),
              rel.count == q.count + 3, Array(rel.prefix(q.count)) == q,
              job.dir.lastPathComponent == job.manifest.jobID, job.manifest.isValid(),
              let srcDir = try? area.openDir(job.dir) else { throw ShareError.io("not a quarantined job") }
        var m = job.manifest
        m.realm = target.realm; m.ws = target.ws; m.generation = target.generation
        guard m.isValid() else { throw ShareError.io("invalid destination") }
        let base = try area.stagingDir(realm: m.realm, ws: m.ws)
        let published: StagedJob? = try area.coordination.ifNotRemoved(realm: target.realm, ws: target.ws, generation: target.generation) {
            let baseDir = try area.openDir(base, create: true)
            let buildingName = m.jobID + ".redirect"
            ShareFS.removeTree(baseDir, buildingName)
            let building = try ShareFS.openDir(baseDir, buildingName, create: true)
            do {
                for item in m.items {
                    let inFD = try ShareFS.openFile(srcDir, item.file)
                    defer { close(inFD) }
                    let bytes = try StagingSession.streamCopy(fromFD: inFD, toDir: building, name: item.file, limit: item.bytes, forbidden: [])
                    guard bytes == item.bytes else { throw ShareError.unreadable }
                }
                try ShareFS.writeAtomic(building, JobFiles.manifest, JSONEncoder().encode(m))
                try ShareFS.writeAtomic(building, JobFiles.ready, Data("1".utf8))
                let finalName = m.jobID + JobFiles.claimedSuffix
                ShareFS.removeTree(baseDir, finalName)
                guard ShareFS.rename(baseDir, buildingName, baseDir, finalName) else { throw ShareError.io("rename") }
                return StagedJob(manifest: m, dir: base.appendingPathComponent(finalName, isDirectory: true))
            } catch {
                ShareFS.removeTree(baseDir, buildingName)
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
        for root in [area.stagingRoot, area.quarantineRoot] {
            for dir in jobDirectories(in: root) {
                let ready = hasReady(dir)
                let manifest = manifest(at: dir)
                let age: TimeInterval
                if ready, let manifest { age = now.timeIntervalSince1970 - manifest.createdAt }
                else {
                    let stamp = area.modificationDate(dir) ?? .distantPast
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
        guard let data = try? area.readFile(dir.appendingPathComponent(JobFiles.manifest), cap: 64 * 1024),
              let m = try? JSONDecoder().decode(JobManifest.self, from: data), m.isValid() else { return nil }
        return m
    }

    /// <root>/<realm>/<ws>/<job> directories, enumerated by descriptor walk: every level is opened `O_NOFOLLOW`
    /// (symbolic links are never followed), the realm and ws names are the exact ASCII shapes the stager creates
    /// (case-sensitive, no look-alikes), and each level must be a real directory entry of the one above.
    private func jobDirectories(in root: URL) -> [URL] {
        guard let rootDir = try? area.openDir(root) else { return [] }
        func children(_ dir: DirFD, valid: (String) -> Bool) -> [String] {
            ((try? ShareFS.list(dir)) ?? []).filter { valid($0) && ShareFS.isDirectory(dir, $0) }
        }
        let realmOK: (String) -> Bool = { (try? ShareArea.validate(realm: $0, ws: String(repeating: "a", count: 32))) != nil }
        let wsOK: (String) -> Bool = { (try? ShareArea.validate(realm: "x", ws: $0)) != nil }
        var out: [URL] = []
        for realm in children(rootDir, valid: realmOK) {
            guard let realmDir = try? ShareFS.openDir(rootDir, realm) else { continue }
            for ws in children(realmDir, valid: wsOK) {
                guard let wsDir = try? ShareFS.openDir(realmDir, ws) else { continue }
                for job in children(wsDir, valid: { $0.utf8.allSatisfy { $0 < 0x80 } && !$0.isEmpty && !$0.contains("/") }) {
                    out.append(root.appendingPathComponent(realm, isDirectory: true).appendingPathComponent(ws, isDirectory: true)
                        .appendingPathComponent(job, isDirectory: true))
                }
            }
        }
        return out
    }

    private func hasReady(_ dir: URL) -> Bool { area.isRegularFile(dir.appendingPathComponent(JobFiles.ready)) }

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
